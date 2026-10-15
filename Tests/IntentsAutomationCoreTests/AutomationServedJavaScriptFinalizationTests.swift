#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationServedJavaScriptFinalizationTests: XCTestCase, @unchecked Sendable {
    private func fixture() -> (AutomationCase, AutomationAttemptReport) {
        let plan = AutomationCase(id: "server-finalization", app: .init(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64)),
            target: .init(id: "owned", kind: .simulator), environmentID: "test",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Action"),
            observations: [.init(id: "observe", kind: .ui, phase: .observe, operation: "Read")],
            requirements: [.init(observationID: "observe", expected: .bool(true), proof: .visibleState, justification: "Existing requirement")])
        let observation = AutomationObservation(id: "observe", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: "attempt", stepID: "observe", route: .ui, proof: .visibleState, value: .bool(true))
        let receipts: [AutomationSegmentReceipt] = [
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: plan.app, target: plan.target,
                segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 2), app: plan.app, target: plan.target,
                segmentID: "observe", route: .ui, dispatched: true, completed: true, observations: [observation])]
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation])
        return (plan, .init(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: true))
    }
    func testWrongBundleAndFailedServerStopAreDowngradedBeforeDurablePublication() async throws {
        for error in [AutomationContractError.conflictingOperation, .terminationUnverified] {
            let (plan, report) = fixture()
            XCTAssertTrue(report.executionSucceeded)
            let finalized = await AutomationServedJavaScriptReportFinalization.finish(report) { throw error }
            XCTAssertFalse(finalized.executionSucceeded)
            XCTAssertFalse(finalized.resourcesReleased)
            XCTAssertFalse(finalized.result.assessed)
            XCTAssertFalse(finalized.result.evidenceComplete)
            XCTAssertEqual(finalized.receipts, report.receipts, "Actual partial evidence must remain available")
            XCTAssertEqual(finalized.result.summary, error == .terminationUnverified ? .unresolved : .infrastructureFailed)
            let root = URL(fileURLWithPath: "/private/tmp/server-finalization-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try AutomationCaseStore(root: root)
            let frozen = try await store.freeze(plan)
            try await store.saveAttempt(finalized, for: frozen)
            let reloaded = try await store.loadAttempt(id: "attempt", frozen: frozen)
            XCTAssertEqual(reloaded, finalized)
            XCTAssertFalse(reloaded.executionSucceeded)
        }
    }
    func testSuccessfulReleaseDoesNotUpgradeAnIncompleteSubject() async {
        let (_, passed) = fixture()
        let unchanged = await AutomationServedJavaScriptReportFinalization.finish(passed) { }
        XCTAssertEqual(unchanged, passed)
        var incomplete = passed; incomplete.result.subjectCompleted = false; incomplete.result.evidenceComplete = false
        incomplete.result.summary = .unresolved; incomplete.result.assessed = false
        let released = await AutomationServedJavaScriptReportFinalization.finish(incomplete) { }
        XCTAssertEqual(released, incomplete)
        XCTAssertFalse(released.executionSucceeded)
    }
    func testDurablePublicationFailureCannotOverwriteExistingEvidenceWithPassedBytes() async throws {
        let (plan, report) = fixture()
        let finalized = await AutomationServedJavaScriptReportFinalization.finish(report) { throw AutomationContractError.terminationUnverified }
        let root = URL(fileURLWithPath: "/private/tmp/server-publication-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root), frozen = try await store.freeze(plan)
        try await store.saveAttempt(finalized, for: frozen)
        do { try await store.saveAttempt(report, for: frozen); XCTFail("An existing unresolved attempt was overwritten") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        let retained = try await store.loadAttempt(id: "attempt", frozen: frozen)
        XCTAssertEqual(retained, finalized)
        XCTAssertFalse(retained.executionSucceeded)
    }
}
#endif
