#if os(macOS)
import Foundation
import XCTest
import Synchronization
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class OwnershipRecoveryStoreTests: XCTestCase {
    func testRecoveryDisplaysPersistedOwnershipWithoutClearingOrRedispatching() async throws {
        let (_, root, _) = try await InstalledUIStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let owner = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        try await owner.reserveCampaign(runID: "interrupted-run", target: target)
        let reopened = AppAutomationStore(supportDirectory: support)
        await reopened.refreshRecovery()
        XCTAssertEqual(reopened.recoveryItems.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.recoveryItems.first).detail.contains("still running"))
        await reopened.refreshRecovery()
        XCTAssertEqual(reopened.recoveryItems.first?.record.runID, "interrupted-run")
        XCTAssertNil(reopened.report)
        let absent = try await owner.campaignAbsent(target: target)
        XCTAssertFalse(absent)
        try await owner.releaseCampaign(runID: "interrupted-run", target: target)
        await reopened.refreshRecovery()
        XCTAssertTrue(reopened.recoveryItems.isEmpty)
    }
    func testCancelledUnresolvedAttemptCanResetAndRunAgain() async throws {
        let gate = RecoveryStartupGate(), calls = Mutex(0)
        let (model, root, _) = try await InstalledUIStoreTests().fixture(executor: { _, plan, _, _, id, _ in
            let first = calls.withLock { value in value += 1; return value == 1 }
            if first { await gate.hold() }
            return .init(attemptID: id, result: AutomationAssessment.assess(plan: plan, attemptID: id,
                subjectDispatched: !first, subjectCompleted: !first, observations: [], termination: first ? .cancelled : nil),
                receipts: [], resourcesReleased: !first)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ownershipRecoveryTask?.value
        model.run(); await gate.waitUntilEntered()
        model.cancel(); await gate.release(); await model.task?.value
        XCTAssertNotNil(model.retainedUnresolvedNormalReport)
        XCTAssertFalse(model.canRun)
        await model.clearUnresolvedAttempt()
        XCTAssertNil(model.retainedUnresolvedNormalReport)
        XCTAssertNil(model.report); XCTAssertNil(model.recoveryError)
        XCTAssertTrue(model.canRun)
        model.run(); await model.task?.value
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(model.report?.resourcesReleased, true)
        XCTAssertEqual(model.report?.result.subjectDispatched, true)
    }

    func testShutdownFailureKeepsUnresolvedReport() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in
            throw AutomationContractError.terminationUnverified
        })
        model.simulatorID = UUID().uuidString
        let target = TargetIdentity(id: model.simulatorID, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        try await owner.reserveCampaign(runID: "cancelled", target: target)
        model.report = .init(attemptID: "cancelled", result: .init(summary: .cancelled,
            subjectDispatched: false, subjectCompleted: false, assessed: false, evidenceComplete: false,
            failedObservations: [], missingObservations: []), receipts: [], resourcesReleased: false)
        await model.clearUnresolvedAttempt()
        XCTAssertNotNil(model.retainedUnresolvedNormalReport); XCTAssertNotNil(model.recoveryError)
        let absent = try await owner.campaignAbsent(target: target); XCTAssertFalse(absent)
    }

    func testStartupReconcilesAbsentAndReplacedOwners() async throws {
        for absent in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/startup-recovery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("target-leases.json")
            let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
            var dead = try AutomationProcessIdentity.current()
            if absent { dead.pid = 999_999_999 } else { dead.startIdentity = "replaced-start-identity" }
            try AutomationLeaseStore(url: url).transaction { state in
                state.campaigns[target.leaseKey] = .init(runID: "old", target: target, owner: dead, ownerToken: "old-owner")
                state.generations[target.leaseKey] = 1
            }
            let model = AppAutomationStore(supportDirectory: root)
            await model.ownershipRecoveryTask?.value
            XCTAssertTrue(model.recoveryItems.isEmpty); XCTAssertNil(model.recoveryError)
            let next = try AutomationDeviceLeaseManager(storeURL: url)
            let lease = try await next.acquire(runID: "new", target: target, control: .system)
            XCTAssertEqual(lease.generation, 2)
        }
    }

    func testResetWaitForStartupCannotInterruptANewOperation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-startup-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root)
        await model.ownershipRecoveryTask?.value
        let gate = RecoveryStartupGate()
        model.ownershipRecoveryTask = Task { await gate.hold() }
        await gate.waitUntilEntered()
        let reset = Task { await model.clearUnresolvedAttempt() }
        await Task.yield()
        model.progress = "Running the approved action…"
        await gate.release(); await reset.value
        XCTAssertEqual(model.progress, "Running the approved action…")
        XCTAssertNil(model.message)
    }

    func testResetRefusesLiveRunnerBeforeShuttingDownSimulator() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-active-runner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shutdowns = Mutex(0)
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in
            shutdowns.withLock { $0 += 1 }
        })
        await model.ownershipRecoveryTask?.value
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let lease = try await owner.acquire(runID: "active", target: target, control: .ui)
        let scope = AutomationScope(runID: "active", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        try await owner.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease)
        await model.clearUnresolvedAttempt()
        XCTAssertEqual(shutdowns.withLock { $0 }, 0)
        XCTAssertNotNil(model.recoveryError)
        let held = await owner.isCurrent(lease); XCTAssertTrue(held)
    }

    func testStartupLeavesLegacyIntentLabOwnershipForItsJournalRecovery() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/legacy-intentlab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = TargetIdentity(id: UUID().uuidString, kind: .physical)
        let url = root.appendingPathComponent("target-leases.json")
        try AutomationLeaseStore(url: url).transaction { state in
            state.campaigns[target.leaseKey] = .init(runID: "intent-lab-old-journal", target: target,
                owner: .init(pid: Int32.max, startIdentity: "old"), ownerToken: "old-owner")
            state.generations[target.leaseKey] = 1
        }
        let model = AppAutomationStore(supportDirectory: root)
        await model.ownershipRecoveryTask?.value
        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertNotNil(try AutomationLeaseStore(url: url).read().campaigns[target.leaseKey])
    }

}
private actor RecoveryStartupGate {
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
