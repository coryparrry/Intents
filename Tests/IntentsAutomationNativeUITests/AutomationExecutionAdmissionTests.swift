#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testCrossRouteAdmissionIsHeldUntilCancelledExecutionActuallyDrains() async throws {
        let gate = AdmissionExecutionGate()
        let (model, _, _) = try await fixture(executor: { _, plan, _, _, attemptID, _ in
            await gate.hold()
            // This seam models an owned operation completing its drain after
            // cancellation; it is not simulator execution evidence.
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID,
                subjectDispatched: false, subjectCompleted: false, observations: [], termination: .cancelled),
                receipts: [], resourcesReleased: true)
        })
        await model.ownershipRecoveryTask?.value
        var otherRouteActive = true
        var blocked = false
        model.executionCanStart = { !otherRouteActive }
        model.executionOwnershipChanged = { blocked = $0 }
        XCTAssertFalse(model.canRun)
        model.run()
        let rejectedCalls = await gate.calls
        XCTAssertEqual(rejectedCalls, 0)
        XCTAssertFalse(blocked)

        otherRouteActive = false
        XCTAssertTrue(model.canRun)
        model.run()
        XCTAssertTrue(blocked)
        let execution = model.task
        await gate.waitUntilEntered()
        model.cancel()
        XCTAssertTrue(model.busy)
        XCTAssertTrue(blocked)
        await gate.release()
        await execution?.value
        XCTAssertFalse(model.busy)
        XCTAssertFalse(blocked)
        XCTAssertEqual(model.report?.resourcesReleased, true)
        XCTAssertTrue(model.canRun)
    }
}

private actor AdmissionExecutionGate {
    private(set) var calls = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async {
        calls += 1
        waiting?.resume(); waiting = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilEntered() async {
        if calls == 0 { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}
#endif
