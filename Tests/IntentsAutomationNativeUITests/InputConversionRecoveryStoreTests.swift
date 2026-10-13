#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class InputConversionRecoveryStoreTests: XCTestCase {
    private func fixture() async throws -> (AppAutomationStore, AutomationDeviceLeaseManager, TargetIdentity) {
        let root = URL(fileURLWithPath: "/private/tmp/input-conversion-recovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in })
        await model.ownershipRecoveryTask?.value
        return (model, try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json")),
                .init(id: "host-macos-local", kind: .nativeMac, loginSession: "diagnostic-test-session"))
    }

    func testUnreleasedDiagnosticRefreshesRecoveryWhileBusyAndResetsItsExactCampaign() async throws {
        let (model, leases, target) = try await fixture()
        let runID = "input-conversion-unreleased"
        let lease = try await leases.acquire(runID: runID, target: target, control: .system)
        model.progress = "Checking fixed input samples…"
        await model.executeInputConversion(runID: runID, target: target, epoch: model.selectionEpoch) {
            .init(resourcesReleased: false, message: "Input conversion check could not verify host cleanup.")
        }
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.hasUnresolvedOwnership) // This is the recovery controls' visibility condition.
        XCTAssertEqual(model.recoveryItems.map(\.record.runID), [runID])
        XCTAssertEqual(model.retainedUnresolvedRequestTargets[runID], target)
        model.progress = nil
        await model.clearUnresolvedAttempt()
        XCTAssertNil(model.recoveryError)
        XCTAssertFalse(model.hasUnresolvedOwnership)
        XCTAssertTrue(model.retainedUnresolvedRequestTargets.isEmpty)
        let current = await leases.isCurrent(lease)
        XCTAssertFalse(current)
    }

    func testThrownAndCancelledDiagnosticReservationsRemainResettable() async throws {
        for cancelled in [false, true] {
            let (model, leases, target) = try await fixture()
            let runID = "input-conversion-" + (cancelled ? "cancelled" : "thrown")
            let gate = InputConversionRecoveryGate()
            let epoch = model.selectionEpoch
            model.progress = "Checking fixed input samples…"
            model.task = Task {
                defer { model.progress = nil; model.task = nil; model.releaseScopeIfClosing() }
                await model.executeInputConversion(runID: runID, target: target, epoch: epoch) {
                    _ = try await leases.acquire(runID: runID, target: target, control: .system)
                    await gate.hold()
                    try Task.checkCancellation()
                    throw AutomationContractError.terminationUnverified
                }
            }
            let task = try XCTUnwrap(model.task)
            await gate.waitUntilEntered()
            if cancelled { model.cancel() }
            await gate.release(); await task.value
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.hasUnresolvedOwnership)
            XCTAssertEqual(model.recoveryItems.map(\.record.runID), [runID])
            XCTAssertEqual(model.retainedUnresolvedRequestTargets[runID], target)
            await model.clearUnresolvedAttempt()
            XCTAssertNil(model.recoveryError)
            XCTAssertFalse(model.hasUnresolvedOwnership)
            let absent = try await leases.campaignAbsent(target: target)
            XCTAssertTrue(absent)
        }
    }

    func testReleasedDiagnosticDoesNotBecomeAnUnresolvedRequest() async throws {
        let (model, leases, target) = try await fixture()
        let runID = "input-conversion-released"
        await model.executeInputConversion(runID: runID, target: target, epoch: model.selectionEpoch) {
            let lease = try await leases.acquire(runID: runID, target: target, control: .system)
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await leases.releaseCampaign(runID: runID, target: target)
            return .init(resourcesReleased: true, message: "Input conversion matched.")
        }
        XCTAssertFalse(model.hasUnresolvedOwnership)
        XCTAssertTrue(model.retainedUnresolvedRequestTargets.isEmpty)
        XCTAssertEqual(model.message, "Input conversion matched.")
    }

    func testThrownDiagnosticWithoutItsOwnReservationCannotResetAnotherLiveCampaign() async throws {
        let (model, leases, target) = try await fixture()
        let live = try await leases.acquire(runID: "another-live-campaign", target: target, control: .system)
        await model.executeInputConversion(runID: "input-conversion-refused", target: target, epoch: model.selectionEpoch) {
            throw AutomationContractError.targetBusy
        }
        XCTAssertTrue(model.hasUnresolvedOwnership)
        XCTAssertTrue(model.retainedUnresolvedRequestTargets.isEmpty)
        await model.clearUnresolvedAttempt()
        XCTAssertNotNil(model.recoveryError)
        let current = await leases.isCurrent(live)
        XCTAssertTrue(current)
    }

    func testResetFinishedDiagnosticPreservesAnotherLiveCampaignOnDifferentTarget() async throws {
        let (model, leases, target) = try await fixture()
        let liveTarget = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let live = try await leases.acquire(runID: "another-live-campaign", target: liveTarget, control: .ui)
        let finished = try await leases.acquire(runID: "input-conversion-finished", target: target, control: .system)
        await model.executeInputConversion(runID: finished.runID, target: target, epoch: model.selectionEpoch) {
            .init(resourcesReleased: false, message: "Host cleanup could not be verified.")
        }
        await model.clearUnresolvedAttempt()
        XCTAssertNil(model.recoveryError)
        XCTAssertEqual(model.recoveryItems.map(\.record.runID), ["another-live-campaign"])
        let current = await leases.isCurrent(live), diagnosticCurrent = await leases.isCurrent(finished)
        XCTAssertTrue(current); XCTAssertFalse(diagnosticCurrent)
    }

    func testClosingDiagnosticRetainsRecoveryWithoutPublishingStaleResult() async throws {
        let (model, leases, target) = try await fixture()
        let runID = "input-conversion-closing", epoch = model.selectionEpoch
        _ = try await leases.acquire(runID: runID, target: target, control: .system)
        model.progress = "Checking fixed input samples…"
        model.message = "Retained message"
        model.close()
        await model.executeInputConversion(runID: runID, target: target, epoch: epoch) {
            throw CancellationError()
        }
        XCTAssertEqual(model.message, "Retained message")
        XCTAssertEqual(model.retainedUnresolvedRequestTargets[runID], target)
        XCTAssertEqual(model.recoveryItems.map(\.record.runID), [runID])
        model.progress = nil; model.releaseScopeIfClosing()
    }
}

private actor InputConversionRecoveryGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { completion?.resume(); completion = nil }
}
#endif
