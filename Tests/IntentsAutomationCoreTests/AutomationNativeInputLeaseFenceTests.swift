import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeInputLeaseFenceTests: XCTestCase, @unchecked Sendable {
    private let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session")
    func testFenceTracksExactLeaseAndNeverReactivatesForNextGeneration() async throws {
        let leases = AutomationDeviceLeaseManager()
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let fence = try await leases.nativeInputFence(for: lease)
        XCTAssertEqual(fence.lease, lease); XCTAssertTrue(fence.isCurrent)
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        XCTAssertFalse(fence.isCurrent)
        let next = try await leases.acquire(runID: "run", target: target, control: .ui)
        let newer = try await leases.nativeInputFence(for: next)
        XCTAssertTrue(newer.isCurrent); XCTAssertFalse(fence.isCurrent)
        XCTAssertNotEqual(next.generation, lease.generation)
    }
    func testFailedReleaseRetainsLeaseButForeignAndSystemLeasesCannotIssueFence() async throws {
        let leases = AutomationDeviceLeaseManager()
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let fence = try await leases.nativeInputFence(for: lease)
        do { try await leases.release(lease, commandsDrained: false, ownedRunnerTerminated: true); XCTFail("Expected refusal") } catch {}
        XCTAssertTrue(fence.isCurrent)
        var foreign = lease; foreign.generation += 1
        do { _ = try await leases.nativeInputFence(for: foreign); XCTFail("Foreign fence issued") } catch {}
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        let system = try await leases.acquire(runID: "run", target: target, control: .system)
        do { _ = try await leases.nativeInputFence(for: system); XCTFail("System input fence issued") } catch {}
    }
    func testDurableFenceRereadsIndependentStoreMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json")
        let leases = try AutomationDeviceLeaseManager(storeURL: url)
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let fence = try await leases.nativeInputFence(for: lease)
        XCTAssertTrue(fence.isCurrent)
        let independent = try AutomationLeaseStore(url: url)
        try independent.transaction { state in
            state.campaigns[lease.target.leaseKey]?.lease = nil
        }
        XCTAssertFalse(fence.isCurrent)
    }
}
