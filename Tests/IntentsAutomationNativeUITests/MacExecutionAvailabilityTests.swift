#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class MacExecutionAvailabilityTests: XCTestCase {
    private actor ExecutionTrap {
        var calls = 0
        func invoked() throws -> AutomationAttemptReport { calls += 1; throw AutomationContractError.invalidIdentity }
        func count() -> Int { calls }
    }
    private func fixture(reader: (@Sendable () throws -> TargetIdentity)? = nil, executor: AutomationNativeRunExecutor? = nil) async throws -> (AppAutomationStore, URL, ExecutionTrap) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        var app = root.appendingPathComponent("Selected.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        app = try AutomationPath.canonical(app)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.SelectedMac", "CFBundleExecutable": "Fixture",
            "CFBundleName": "Selected", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["MacOSX"]], format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        var binary = Data(repeating: 0, count: 56)
        for (offset, value) in [(0, UInt32(0xfeedfacf)), (4, 0x0100000c), (12, 2), (16, 1), (20, 24), (32, 0x32), (36, 24), (40, 1)] {
            for byte in 0..<4 { binary[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        try binary.write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        _ = try AutomationApplicationIntake.assess(app)
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session-A")
        let trap = ExecutionTrap()
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            runExecutor: executor ?? { _, _, _, _, _, _ in try await trap.invoked() }, nativeMacTargetReader: reader ?? { target })
        model.select(app); await model.task?.value
        model.uiInstruction = "Open Settings"; model.uiEndpoint = "Settings"
        model.effectChoice = "navigation"; model.effectsConfirmed = true
        return (model, root, trap)
    }
    private func prepareSource(_ model: AppAutomationStore, root: URL) throws {
        var app = try XCTUnwrap(model.candidate?.app)
        let id = root.appendingPathComponent("Source.xcodeproj").path + "#SOURCE"
        app.logicalID = id; app.configuration = "Debug"
        let source = AutomationSourceManifest(sourceRoot: root.path, files: [], directories: [], excludedPaths: [])
        app.sourceManifestDigest = try source.digest
        let catalog = ApplicationSurfaceCatalog(app: app,
            systemActions: [.init(id: "Echo", typeName: "Echo", title: "Echo",
                parameters: [.init(name: "text", family: "text", optional: false)], parametersComplete: true,
                compiled: true, registered: false, executed: false, resultFamily: "noValue")],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        model.intake = .init(candidates: [.init(id: id, name: "Selected", kind: .sourceTarget, containerPath: root.path,
            targetID: "SOURCE", bundleID: app.bundleID, platform: "macos", architectures: ["arm64"], configurations: ["Debug"], app: nil)],
            gaps: [], requiresBuildApproval: true)
        model.candidateID = id; model.configuration = "Debug"; model.preparationDestination = .macOS
        model.prepared = .init(source: source,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "test.Host",
                configuration: "Debug", templateDigest: String(repeating: "c", count: 64)),
            host: .init(app: app, target: try XCTUnwrap(model.sourcePreparationTarget), xctestrunPath: "unused",
                xctestrunDigest: String(repeating: "d", count: 64), subjectProductPath: try XCTUnwrap(app.canonicalBundlePath),
                hostBundlePath: "unused", hostProductDigest: String(repeating: "e", count: 64), hostBundleID: "test.Host", testTarget: "unused"),
            catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
        model.catalog = catalog; model.installApproved = true
    }

    func testPreparedMacUIReviewUsesExactHostSessionAndNeverRequestsSimulatorInstall() async throws {
        let (model, root, trap) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try prepareSource(model, root: root)
        XCTAssertTrue(model.canRun); XCTAssertFalse(model.isMacWorkflowUnavailable)
        let request = try model.makeNativeRunRequest(runID: "review")
        XCTAssertEqual(request.plan.target, model.sourcePreparationTarget)
        XCTAssertEqual(request.plan.environmentID, "selected-mac-session:synthetic-session-A")
        XCTAssertEqual(request.approval.approvedCaseDigest, request.caseDigest)
        XCTAssertEqual(request.plan.preparedMacBuildArtifacts, try .init(prepared: XCTUnwrap(model.prepared)))
        XCTAssertNil(request.plan.preparedSimulatorBuildArtifacts)
        XCTAssertFalse(request.installApproved)
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertTrue(review.message.contains("retained Mac app"))
        _ = try model.cancelCommand(id: review.id)
        do { try await model.confirmNativeRequest(review); XCTFail("Cancelled Mac request dispatched") } catch {}
        let count = await trap.count(); XCTAssertEqual(count, 0)
    }

    func testPreparedMacTypedActionAndFirstChecksRetainExactApprovedInputs() async throws {
        let (model, root, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try prepareSource(model, root: root)
        model.workflowRoute = "action"; model.actionID = "Echo"; model.inputs = ["text": "approved text"]
        XCTAssertTrue(model.canRun)
        let request = try model.makeNativeRunRequest(runID: "typed")
        XCTAssertEqual(request.plan.execution.inputs["text"], .text("approved text"))
        XCTAssertEqual(request.plan.environmentID, "selected-mac-session:synthetic-session-A")
        XCTAssertNotNil(request.plan.preparedMacBuildArtifacts)
        XCTAssertFalse(request.installApproved)
        model.firstRunIncludesActions = true; model.firstRunEffectsConfirmed = true
        model.firstRunInputs = ["Echo": ["text": "first approved text"]]
        let review = try model.reviewFirstChecks()
        let first = try XCTUnwrap(review.requests.first)
        XCTAssertEqual(first.plan.execution.inputs["text"], .text("first approved text"))
        XCTAssertEqual(first.plan.environmentID, request.plan.environmentID)
        XCTAssertFalse(first.installApproved)
        XCTAssertTrue(review.gaps.contains { $0.contains("initial Mac view") })
        model.firstRunInputs["Echo"]?["text"] = "changed text"
        model.runFirstChecks(review)
        XCTAssertFalse(model.busy); XCTAssertTrue(model.firstRunReports.isEmpty)
        model.workflowRoute = "fresh"
        XCTAssertFalse(model.canRun)
    }

    func testChangedMacLoginRejectsReviewedConfirmationAndFirstChecksBeforeDispatch() async throws {
        let login = MacTestLogin()
        let (model, root, trap) = try await fixture(reader: { login.read() }); defer { try? FileManager.default.removeItem(at: root) }
        try prepareSource(model, root: root)
        model.firstRunIncludesActions = true; model.firstRunEffectsConfirmed = true
        model.firstRunInputs = ["Echo": ["text": "first approved text"]]
        let first = try model.reviewFirstChecks()
        let review = try await model.prepareNativeConfirmation(.run)
        login.change()
        XCTAssertFalse(model.canRun)
        do { try await model.confirmNativeRequest(review); XCTFail("Stale Mac login dispatched") } catch {}
        model.runFirstChecks(first)
        XCTAssertFalse(model.busy); XCTAssertTrue(model.firstRunReports.isEmpty)
        let calls = await trap.count(); XCTAssertEqual(calls, 0)
    }

    func testPreparedMacUnreleasedAttemptBlocksFurtherRunsAndFirstChecks() async throws {
        let (model, root, _) = try await fixture(executor: { _, plan, approval, _, id, install in
            XCTAssertFalse(install)
            let receipt = AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: id, segmentID: plan.execution.id, leaseGeneration: 1),
                app: plan.app, target: plan.target, segmentID: plan.execution.id, route: plan.execution.kind,
                dispatched: true, completed: false, environmentID: plan.environmentID)
            let result = AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: true, subjectCompleted: false,
                observations: [], termination: .unresolved)
            return .init(attemptID: id, result: result, receipts: [receipt], resourcesReleased: false)
        }); defer { try? FileManager.default.removeItem(at: root) }
        try prepareSource(model, root: root)
        let review = try await model.prepareNativeConfirmation(.run)
        try await model.confirmNativeRequest(review); await model.task?.value
        XCTAssertFalse(model.canRun); XCTAssertFalse(model.canReviewFirstChecks)
        XCTAssertTrue(model.hasUnresolvedActiveAttempt)
        XCTAssertEqual(model.report?.resourcesReleased, false)
    }

    func testPreparedMacSavedFailureAndChangedBuildCanBeReviewedWithoutSimulatorInstallation() async throws {
        let (model, root, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try prepareSource(model, root: root)
        model.uiExpectedText = "Settings"
        let request = try model.makeNativeRunRequest(runID: "original")
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let frozen = try await cases.freeze(request.plan)
        let original = try await NativeSearchFactExecutor(fails: true).execute(frozen: frozen, approval: request.approval,
            attemptID: "original", budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(original, for: frozen)
        await model.showSavedCase(frozen, attemptID: original.attemptID)
        XCTAssertTrue(model.canReproduceSavedFailure)
        let reproduction = try await model.previewReproductionCommand()
        XCTAssertEqual(reproduction.environmentID, "selected-mac-session:synthetic-session-A")
        XCTAssertFalse(reproduction.installApproved)
        let before = try XCTUnwrap(model.prepared)
        var after = before
        after.source.files = [.init(inputPath: root.appendingPathComponent("Changed.swift").path, relativePath: "Changed.swift",
            bytes: 1, sha256: String(repeating: "1", count: 64), symbolicLink: nil, frozenSymbolicLink: nil, permissions: 420)]
        after.host.app.sourceManifestDigest = try after.source.digest
        after.host.app.productDigest = String(repeating: "2", count: 64)
        after.host.hostProductDigest = String(repeating: "3", count: 64)
        after.host.xctestrunDigest = String(repeating: "4", count: 64)
        after.catalog.app = after.host.app
        model.prepared = after; model.catalog = after.catalog; model.installApproved = false
        XCTAssertTrue(model.canCheckFix)
        let comparison = try await model.previewComparisonCommand()
        XCTAssertFalse(comparison.installApproved)
        XCTAssertEqual(comparison.beforeProductDigest, before.host.app.productDigest)
        XCTAssertEqual(comparison.afterProductDigest, after.host.app.productDigest)
        let proposal = try AutomationNativeUIFixComparisonProposal.compile(frozen: frozen, original: original,
            before: .prepared(before), after: .prepared(after), runID: "comparison", disposable: false)
        let report = try await proposal.runCampaign(cases: cases,
            beforeExecutor: NativeSearchFactExecutor(fails: true), afterExecutor: NativeSearchFactExecutor())
        XCTAssertEqual(report.outcome, .fixed)
        XCTAssertEqual(report.before.count, 3); XCTAssertEqual(report.after.count, 3)
        XCTAssertEqual(proposal.baseline.oracleDigest, proposal.candidate.oracleDigest)
        XCTAssertEqual(proposal.baseline.plan.requirements, proposal.candidate.plan.requirements)
        XCTAssertTrue((report.before + report.after).allSatisfy(\.resourcesReleased))
    }

    func testUnavailableMacExecutionCannotQueueOrInvokeInjectedExecutor() async throws {
        let (model, root, trap) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.simulatorID = UUID().uuidString
        XCTAssertTrue(model.isInstalledMacUI); XCTAssertTrue(model.isMacWorkflowUnavailable)
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: String(repeating: "a", count: 64)))
        model.run()
        XCTAssertFalse(model.canRun)
        XCTAssertNil(model.pendingCommandStatus)
        let calls = await trap.count(); XCTAssertEqual(calls, 0)
    }
}
private final class MacTestLogin: @unchecked Sendable {
    private let lock = NSLock()
    private var session = "synthetic-session-A"
    func read() -> TargetIdentity {
        lock.lock(); defer { lock.unlock() }
        return .init(id: "host-macos-local", kind: .nativeMac, loginSession: session)
    }
    func change() { lock.lock(); defer { lock.unlock() }; session = "synthetic-session-B" }
}
#endif
