import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalDeviceLeaseTests: XCTestCase, @unchecked Sendable {
    func testDurablePhysicalAliasReservationBlocksAnotherCampaignUntilRelease() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/physical-alias-leases-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("leases.json")
        let first = try AutomationDeviceLeaseManager(storeURL: store), second = try AutomationDeviceLeaseManager(storeURL: store)
        let coreDevice = TargetIdentity(id: UUID().uuidString, kind: .physical)
        let xcodeDevice = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        try await first.reserveCampaign(runID: "first", target: coreDevice)
        do { try await second.reserveCampaign(runID: "second", target: xcodeDevice); XCTFail("physical aliases must serialize") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        do { _ = try await second.acquire(runID: "second", target: xcodeDevice, control: .system); XCTFail("direct acquisition must serialize") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await first.releaseCampaign(runID: "first", target: coreDevice)
        let lease = try await second.acquire(runID: "second", target: xcodeDevice, control: .system)
        try await second.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await second.releaseCampaign(runID: "second", target: xcodeDevice)
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
