import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationDeviceOwnershipResetTests: XCTestCase, @unchecked Sendable {
    func testExplicitCurrentProcessResetClearsRetainedCampaignAndAllowsAnotherRun() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ownership-reset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json")
        let owner = try AutomationDeviceLeaseManager(storeURL: url)
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let lease = try await owner.acquire(runID: "cancelled", target: target, control: .system)
        let recovery = try AutomationDeviceLeaseManager(storeURL: url)
        let records = try await recovery.recoveryRecords(), record = try XCTUnwrap(records.first)
        try await recovery.resetCurrentProcessCampaign(record)
        let stale = await owner.isCurrent(lease); XCTAssertFalse(stale)
        do { try await recovery.resetCurrentProcessCampaign(record); XCTFail("Stale recovery snapshot was accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let next = try await recovery.acquire(runID: "retry", target: target, control: .system)
        XCTAssertGreaterThan(next.generation, lease.generation)
        try await recovery.release(next, commandsDrained: true, ownedRunnerTerminated: true)
        try await recovery.releaseCampaign(runID: "retry", target: target)
    }
    func testCurrentProcessResetRefusesAnOwnedLiveRunner() async throws {
        let manager = AutomationDeviceLeaseManager(), target = TargetIdentity(id: "simulator", kind: .simulator)
        let lease = try await manager.acquire(runID: "active", target: target, control: .ui)
        let scope = AutomationScope(runID: "active", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        try await manager.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease)
        let record = try await manager.currentRecord(lease)
        do { try await manager.resetCurrentProcessCampaign(record); XCTFail("Live runner ownership was cleared") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let current = await manager.isCurrent(lease); XCTAssertTrue(current)
    }
    func testAbsentAndReplacedOwnersReconcileWithoutAffectingOtherTargets() async throws {
        for replaced in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/ownership-reconcile-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("leases.json"), manager = try AutomationDeviceLeaseManager(storeURL: url)
            let target = TargetIdentity(id: UUID().uuidString, kind: .physical)
            _ = try await manager.acquire(runID: "old", target: target, control: .system)
            let store = try AutomationLeaseStore(url: url)
            try store.transaction { state in
                state.campaigns[target.leaseKey]?.owner = replaced
                    ? .init(pid: try AutomationProcessIdentity.current().pid, startIdentity: "different-start")
                    : .init(pid: Int32.max, startIdentity: "1:0")
            }
            let records = try await manager.recoveryRecords(), record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.owner.presence(), replaced ? .replaced : .absent)
            try await manager.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
            let next = try await manager.acquire(runID: "next", target: target, control: .system)
            try await manager.release(next, commandsDrained: true, ownedRunnerTerminated: true)
            try await manager.releaseCampaign(runID: "next", target: target)
        }
    }
}
