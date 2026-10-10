#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationApplicationPreflightTests: XCTestCase, @unchecked Sendable {
    func testMixedPlanWithoutRuntimeStopsBeforeCreatingAnAttemptOrTouchingSimulator() async throws {
        try await rejectedBeforeMutation(runtime: nil)
    }
    func testUnsignedMissingRuntimeStopsBeforeCreatingAnAttemptOrTouchingSimulator() async throws {
        try await rejectedBeforeMutation(runtime: .init(bundleURL: URL(fileURLWithPath: "/private/tmp/missing-intents-runtime"), expectedTeamID: "ABCDEFGHIJ"))
    }
    func testPreparationFailurePersistsWithoutInventingDispatchOrRelease() async throws {
        try await retainedPreparationFailure(error: .terminationUnverified, expectedSummary: .unresolved, released: false)
    }
    func testUnavailableTargetPersistsReleasedInfrastructureFailure() async throws {
        try await retainedPreparationFailure(error: .missingEvidence("fixture unavailable"), expectedSummary: .infrastructureFailed, released: true)
    }
    func testPersistenceFailureRetainsOriginalPreparationErrorAndTargetOwnership() async throws {
        try await retainedPreparationFailure(error: .terminationUnverified, expectedSummary: .unresolved, released: false, persistenceFails: true)
    }
    private func retainedPreparationFailure(error: AutomationContractError, expectedSummary: AttemptResult.Summary, released: Bool, persistenceFails: Bool = false) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "nonexistent-simulator", kind: .simulator)
        let plan = AutomationCase(id: "preparation", app: app, target: target, environmentID: "disposable", execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Actual subject"))
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "unused", bundleID: "unused", configuration: "Debug", templateDigest: "unused"),
            host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: "unused", subjectProductPath: "unused", hostBundlePath: "unused", hostProductDigest: "unused", hostBundleID: "unused", testTarget: "unused"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "unused", buildLogTruncated: false)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 10, disposable: true)
        let calls = PreparationInventoryCalls()
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), simulatorInventory: { _, workspace in
            await calls.increment()
            if persistenceFails { try FileManager.default.createDirectory(at: workspace.appendingPathComponent("report.json"), withIntermediateDirectories: false) }
            throw error
        })
        do { _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", allowBootAndInstall: true); XCTFail("Preparation failed") }
        catch let caught {
            if persistenceFails { XCTAssertEqual((caught as? AutomationPreparationPersistenceFailure)?.preparationError as? AutomationContractError, error) }
            else { XCTAssertEqual(caught as? AutomationContractError, error) }
        }
        let observer = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        do {
            let lease = try await observer.acquire(runID: "another-owner", target: target, control: .system)
            XCTAssertTrue(released, "Unproved preparation released target ownership")
            try await observer.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await observer.releaseCampaign(runID: "another-owner", target: target)
        } catch { XCTAssertFalse(released); XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        if persistenceFails {
            let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
            let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
            let attempts = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertTrue(attempts.isEmpty)
            return
        }
        let report = try JSONDecoder().decode(AutomationAttemptReport.self, from: Data(contentsOf: root.appendingPathComponent("attempt/report.json")))
        XCTAssertEqual(report.result.summary, expectedSummary); XCTAssertEqual(report.resourcesReleased, released)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.result.subjectCompleted)
        XCTAssertFalse(report.result.subjectDispatchUncertain); XCTAssertTrue(report.receipts.isEmpty)
        let recovered = try await runner.retainedAttempt(attemptID: "attempt", plan: plan, runID: approval.runID)
        XCTAssertEqual(recovered, report)
        var foreign = plan; foreign.execution.operation = "Different query"
        let otherPlan = try await runner.retainedAttempt(attemptID: "attempt", plan: foreign, runID: approval.runID)
        let otherRun = try await runner.retainedAttempt(attemptID: "attempt", plan: plan, runID: "foreign")
        XCTAssertNil(otherPlan); XCTAssertNil(otherRun)

        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
        let saved = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertEqual(saved, [report])
        if !released {
            do { _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt-retry", allowBootAndInstall: true); XCTFail("Same owner repeated uncertain preparation") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
            let count = await calls.value; XCTAssertEqual(count, 1)
            do { _ = try await observer.acquire(runID: "another-owner", target: target, control: .system); XCTFail("Failed reservation cleared earlier ownership") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        }
        do { _ = try await runner.qualifyRecipe(.init(id: "invented", producerSegmentID: "setup", verifierSegmentID: "verify", fillBinding: "name", outputID: "title")); XCTFail("Failed preparation cannot qualify a recipe") }
        catch { }
    }
    private func rejectedBeforeMutation(runtime: AutomationUIRuntime?) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "nonexistent-simulator", kind: .simulator)
        let plan = AutomationCase(id: "mixed", app: app, target: target, environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "Create")])
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "unused", bundleID: "unused", configuration: "Debug", templateDigest: "unused"),
            host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: "unused", subjectProductPath: "unused",
                hostBundlePath: "unused", hostProductDigest: "unused", hostBundleID: "unused", testTarget: "unused"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []),
            buildLogPath: "unused", buildLogTruncated: false)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: plan.environmentID,
            effects: [.observe], maximumActions: 10, disposable: true)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        do {
            _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(),
                attemptID: "attempt", allowBootAndInstall: true, uiRuntime: runtime)
            XCTFail("Unqualified UI runtime was allowed")
        } catch {
            if runtime == nil { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Mixed plans require the signed private UI runtime")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cases").path))
    }
}
private actor PreparationInventoryCalls {
    var value = 0
    func increment() { value += 1 }
}
#endif
