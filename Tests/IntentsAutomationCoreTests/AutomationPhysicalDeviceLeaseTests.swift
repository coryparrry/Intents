import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalDeviceLeaseTests: XCTestCase, @unchecked Sendable {
    func testSameCanonicalPhysicalDeviceBlocksAliasesUntilRelease() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/physical-alias-leases-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("leases.json")
        let first = try AutomationDeviceLeaseManager(storeURL: store), second = try AutomationDeviceLeaseManager(storeURL: store)
        let identifier = UUID().uuidString
        var coreDevice = TargetIdentity(id: identifier, kind: .physical)
        coreDevice.physicalDeviceIdentifier = identifier
        var xcodeDevice = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        xcodeDevice.physicalDeviceIdentifier = identifier.lowercased()
        XCTAssertEqual(coreDevice.leaseKey, xcodeDevice.leaseKey)
        try await first.reserveCampaign(runID: "first", target: coreDevice)
        do { try await second.reserveCampaign(runID: "second", target: xcodeDevice); XCTFail("same physical device must serialize") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        do { _ = try await second.acquire(runID: "second", target: xcodeDevice, control: .system); XCTFail("same device direct acquisition must serialize") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await first.releaseCampaign(runID: "first", target: coreDevice)
        let lease = try await second.acquire(runID: "second", target: xcodeDevice, control: .system)
        try await second.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await second.releaseCampaign(runID: "second", target: xcodeDevice)
    }
    func testDifferentPhysicalDevicesCanReserveAndAcquireIndependently() async throws {
        let leases = AutomationDeviceLeaseManager()
        let first = TargetIdentity(id: UUID().uuidString, kind: .physical)
        let second = TargetIdentity(id: UUID().uuidString, kind: .physical)
        try await leases.reserveCampaign(runID: "first", target: first)
        try await leases.reserveCampaign(runID: "second", target: second)
        let firstLease = try await leases.acquire(runID: "first", target: first, control: .system)
        let secondLease = try await leases.acquire(runID: "second", target: second, control: .ui)
        let firstCurrent = await leases.isCurrent(firstLease), secondCurrent = await leases.isCurrent(secondLease)
        XCTAssertTrue(firstCurrent); XCTAssertTrue(secondCurrent)
        for lease in [firstLease, secondLease] {
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await leases.releaseCampaign(runID: lease.runID, target: lease.target)
        }
    }
    func testLegacyUDIDLeaseBlocksCanonicalAliasWhilePreservingItsRelease() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/physical-legacy-leases-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json"), owner = try AutomationDeviceLeaseManager(storeURL: url)
        let udid = "00008140-001049013EF3401C", uuid = UUID().uuidString
        let legacy = TargetIdentity(id: udid, kind: .physical)
        let lease = try await owner.acquire(runID: "legacy", target: legacy, control: .system)
        let manager = try AutomationDeviceLeaseManager(storeURL: url)
        try await manager.registerPhysicalDeviceAliases([udid: uuid])
        let canonical = TargetIdentity(id: uuid, kind: .physical)
        do { _ = try await manager.acquire(runID: "alias", target: canonical, control: .ui); XCTFail("Canonical alias bypassed the active legacy lease") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let record = try await owner.currentRecord(lease)
        XCTAssertEqual(record.target, legacy, "An existing approved target must remain unchanged")
        let independent = try await manager.acquire(runID: "independent", target: .init(id: UUID().uuidString, kind: .physical), control: .system)
        let current = await owner.isCurrent(lease); XCTAssertTrue(current)
        try await owner.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await owner.releaseCampaign(runID: "legacy", target: legacy)
        let reopened = try AutomationDeviceLeaseManager(storeURL: url)
        let available = try await reopened.acquire(runID: "alias", target: canonical, control: .ui)
        for (manager, lease) in [(manager, independent), (reopened, available)] {
            try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await manager.releaseCampaign(runID: lease.runID, target: lease.target)
        }
    }
    func testResolvedIncomingUDIDRegistersAliasEvenWhenLegacyCampaignIsBusy() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/physical-incoming-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json"), owner = try AutomationDeviceLeaseManager(storeURL: url)
        let udid = "00008140-001049013EF3401C", uuid = UUID().uuidString
        let legacy = TargetIdentity(id: udid, kind: .physical)
        let lease = try await owner.acquire(runID: "legacy", target: legacy, control: .system)
        let manager = try AutomationDeviceLeaseManager(storeURL: url)
        var resolved = legacy; resolved.physicalDeviceIdentifier = uuid
        do { _ = try await manager.acquire(runID: "resolved", target: resolved, control: .system); XCTFail("Resolved UDID bypassed its legacy campaign") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let reopened = try AutomationDeviceLeaseManager(storeURL: url)
        do { _ = try await reopened.acquire(runID: "uuid", target: .init(id: uuid, kind: .physical), control: .system); XCTFail("Resolved alias mapping was not durable") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await owner.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await owner.releaseCampaign(runID: "legacy", target: legacy)
    }
    func testLegacyLowercaseUUIDKeyRemainsReleasableAfterCanonicalAliasRegistration() async throws {
        let manager = AutomationDeviceLeaseManager(), uuid = UUID().uuidString
        let oldTarget = TargetIdentity(id: uuid.lowercased(), kind: .physical)
        let lease = try await manager.acquire(runID: "legacy", target: oldTarget, control: .system)
        XCTAssertEqual(oldTarget.leaseKey, "ios:" + uuid.lowercased())
        try await manager.registerPhysicalDeviceAliases([uuid.lowercased(): uuid])
        var canonical = TargetIdentity(id: uuid, kind: .physical); canonical.physicalDeviceIdentifier = uuid
        do { _ = try await manager.acquire(runID: "new", target: canonical, control: .system); XCTFail("Canonical casing bypassed an old UUID lease") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await manager.releaseCampaign(runID: "legacy", target: oldTarget)
        let next = try await manager.acquire(runID: "new", target: canonical, control: .system)
        try await manager.release(next, commandsDrained: true, ownedRunnerTerminated: true)
        try await manager.releaseCampaign(runID: "new", target: canonical)
    }
    func testDifferentSimulatorsRemainIndependentOfPhysicalReservation() async throws {
        let leases = AutomationDeviceLeaseManager()
        let physical = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        try await leases.reserveCampaign(runID: "physical", target: physical)
        let simulator = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let lease = try await leases.acquire(runID: "simulator", target: simulator, control: .system)
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await leases.releaseCampaign(runID: "simulator", target: simulator)
        try await leases.releaseCampaign(runID: "physical", target: physical)
    }
}
