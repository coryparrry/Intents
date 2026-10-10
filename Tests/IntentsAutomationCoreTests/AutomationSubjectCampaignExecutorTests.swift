#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSubjectCampaignExecutorTests: XCTestCase, @unchecked Sendable {
    actor Spy {
        var invocations: [AutomationSubjectCampaignExecutor.Invocation] = []
        func run(_ invocation: AutomationSubjectCampaignExecutor.Invocation) -> AutomationAttemptReport {
            invocations.append(invocation)
            return .init(attemptID: invocation.attemptID, result: AutomationAssessment.assess(plan: invocation.frozen.plan,
                attemptID: invocation.attemptID, subjectDispatched: false, subjectCompleted: false, observations: [], termination: .infrastructureFailed), receipts: [], resourcesReleased: true)
        }
    }
    func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/subject-campaign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func selected(_ root: URL) throws -> AutomationInstalledMacUIApplication {
        let bundle = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Campaign", "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["MacOSX"]], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try AutomationPhysicalExecutableTests.binary(platform: 1).write(to: bundle.appendingPathComponent("Contents/MacOS/Fixture"))
        return try .init(bundleURL: bundle, target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login"))
    }
    func plan(_ selected: AutomationInstalledMacUIApplication) -> AutomationCase {
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
        var plan = AutomationCase(id: "mac-campaign", app: selected.app, target: selected.target, environmentID: "selected-mac:synthetic-login", execution: segment)
        plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
        return plan
    }
    func approval(_ plan: AutomationCase) throws -> RunApproval {
        .init(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe, .navigate, .fixtureWrite],
              maximumActions: 10, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
    }
    func prepared(_ plan: AutomationCase, root: URL) -> AutomationPreparedApplication {
        .init(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "HOST", bundleID: "example.Host", configuration: "Debug", templateDigest: String(repeating: "a", count: 64)),
            host: .init(app: plan.app, target: plan.target, xctestrunPath: "synthetic", xctestrunDigest: String(repeating: "a", count: 64), subjectProductPath: plan.app.canonicalBundlePath ?? "synthetic",
                hostBundlePath: "synthetic", hostProductDigest: String(repeating: "a", count: 64), hostBundleID: "example.Host", testTarget: "Host"),
            catalog: .init(app: plan.app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "synthetic", buildLogTruncated: false)
    }
    func testAdapterRetainsExactMacSelectionAttemptApprovalAndSharedBudgetOnce() async throws {
        let root = try root(), selected = try selected(root), plan = plan(selected), approval = try approval(plan)
        let frozen = try await AutomationCaseStore(root: root.appendingPathComponent("Cases")).freeze(plan), budget = try AutomationCampaignBudget(limits: .firstCampaign), spy = Spy()
        let executor = AutomationSubjectCampaignExecutor(subject: .installedMacUI(selected), capabilities: .init(), run: { await spy.run($0) })
        let report = try await executor.execute(frozen: frozen, approval: approval, attemptID: "attempt", budget: budget)
        let calls = await spy.invocations; XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first); XCTAssertEqual(call.subject.app, selected.app); XCTAssertEqual(call.subject.target, selected.target)
        XCTAssertEqual(call.subject.productPath, selected.bundleURL.path); XCTAssertEqual(call.frozen.digest, frozen.digest)
        XCTAssertEqual(call.approval, approval); XCTAssertEqual(call.attemptID, "attempt"); XCTAssertTrue(call.budget === budget)
        XCTAssertNil(call.fixtureTracker); XCTAssertNil(call.uiRuntime); XCTAssertFalse(call.allowBootAndInstall); XCTAssertEqual(report.attemptID, "attempt")
    }
    func testInstalledMacWritesAndChangedProductFailBeforeForwarding() async throws {
        for changedProduct in [false, true] {
            let root = try root(), selected = try selected(root); var plan = plan(selected)
            if !changedProduct { plan.execution.effects.insert(.fixtureWrite) }
            let frozen = try await AutomationCaseStore(root: root.appendingPathComponent("Cases")).freeze(plan), approval = try approval(plan), budget = try AutomationCampaignBudget(limits: .firstCampaign), spy = Spy()
            let executor = AutomationSubjectCampaignExecutor(subject: .installedMacUI(selected), capabilities: .init(), run: { await spy.run($0) })
            if changedProduct { try Data("changed".utf8).write(to: selected.bundleURL.appendingPathComponent("Contents/MacOS/Fixture")) }
            do { _ = try await executor.execute(frozen: frozen, approval: approval, attemptID: "attempt", budget: budget); XCTFail("Unsafe installed campaign forwarded") } catch {}
            let calls = await spy.invocations; XCTAssertTrue(calls.isEmpty)
        }
    }
    func testGenericMacAdapterPreservesDefaultRunnerQualificationFence() async throws {
        let root = try root(), selected = try selected(root), plan = plan(selected)
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("Support"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            simulatorInventory: { _, _ in XCTFail("Mac campaign reached simulator infrastructure"); throw AutomationContractError.invalidIdentity })
        let executor = AutomationSubjectCampaignExecutor(runner: runner, subject: .installedMacUI(selected), capabilities: .init())
        let frozen = try await AutomationCaseStore(root: root.appendingPathComponent("Cases")).freeze(plan)
        do { _ = try await executor.execute(frozen: frozen, approval: approval(plan), attemptID: "attempt", budget: AutomationCampaignBudget(limits: .firstCampaign)); XCTFail("Unqualified Mac route admitted") }
        catch let error as AutomationContractError { guard case .missingEvidence = error else { return XCTFail("Wrong fence: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Support/attempt").path))
    }
    func testPreparedMacFreshFixtureCannotBypassEquivalenceQualification() async throws {
        let root = try root(), selected = try selected(root), plan = plan(selected), spy = Spy()
        let frozen = try await AutomationCaseStore(root: root.appendingPathComponent("Cases")).freeze(plan)
        let tracker = try AutomationFreshFixtureTracker(fixture: FreshFixtureTestData().qualify())
        let executor = AutomationSubjectCampaignExecutor(subject: .prepared(prepared(plan, root: root)), capabilities: .init(), run: { await spy.run($0) })
        do { _ = try await executor.execute(frozen: frozen, approval: approval(plan), attemptID: "attempt", budget: AutomationCampaignBudget(limits: .firstCampaign), fixtureTracker: tracker); XCTFail("Unqualified Mac fresh fixture forwarded") }
        catch let error as AutomationContractError { XCTAssertEqual(error, .missingEvidence("Mac fresh-fixture campaigns require qualified setup and reset equivalence")) }
        let calls = await spy.invocations; XCTAssertTrue(calls.isEmpty)
    }
    func testPreparedSimulatorAdapterForwardsExactFreshFixtureTracker() async throws {
        let root = try root(), data = try FreshFixtureTestData(), plan = data.plan, spy = Spy()
        let frozen = try await AutomationCaseStore(root: root.appendingPathComponent("Cases")).freeze(plan), tracker = try AutomationFreshFixtureTracker(fixture: data.qualify())
        let budget = try AutomationCampaignBudget(limits: .firstCampaign)
        let executor = AutomationSubjectCampaignExecutor(subject: .prepared(prepared(plan, root: root)), capabilities: .init(), allowBootAndInstall: true, run: { await spy.run($0) })
        _ = try await executor.execute(frozen: frozen, approval: data.approval, attemptID: "attempt", budget: budget, fixtureTracker: tracker)
        let calls = await spy.invocations; XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first); XCTAssertTrue(call.fixtureTracker === tracker); XCTAssertTrue(call.budget === budget); XCTAssertTrue(call.allowBootAndInstall)
    }
}
#endif
