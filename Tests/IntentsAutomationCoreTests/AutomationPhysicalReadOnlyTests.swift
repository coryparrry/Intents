#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Explicit opt-in exercises official inventory and local ownership only; no device action is launched.
final class AutomationPhysicalReadOnlyTests: XCTestCase, @unchecked Sendable {
    func testOfficialInventoryChildrenAreDurablyTrackedAndDrained() async throws {
        guard let identifier = ProcessInfo.processInfo.environment["INTENTS_READ_ONLY_PHYSICAL_TARGET"], !identifier.isEmpty else {
            throw XCTSkip("Requires an explicitly selected connected physical device for read-only inspection")
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("intents-physical-read-only-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let runID = "read-only-" + UUID().uuidString, target = TargetIdentity(id: identifier, kind: .physical)
        let lease = try await manager.acquire(runID: runID, target: target, control: .system)
        let scope = AutomationScope(runID: runID, attemptID: runID, segmentID: "inventory", leaseGeneration: lease.generation)
        let verifier = try AutomationPhysicalRunnerVerifier(workspace: root)
        // This synthetic name is intentionally absent. It does not qualify a real XCTest runner's release.
        let observation = try await verifier.inspect(target: target, runnerBundleID: "com.example.ReadOnlyAbsentRunner",
            executableName: "ReadOnlyAbsentRunner", ownedPID: nil) { process in
                try await manager.recordRunner(.init(scope: scope, process: process, role: .nativeCommand,
                    executablePath: "/usr/bin/xcrun"), lease: lease)
            }
        XCTAssertEqual(observation.targetID, identifier)
        XCTAssertTrue(observation.runnerAbsent)
        let recorded = try await manager.currentRecord(lease)
        XCTAssertEqual(recorded.runners.count, 2)
        XCTAssertTrue(recorded.runners.allSatisfy { [.absent, .replaced].contains($0.process.presence()) })
        let drained = await verifier.drainInspector(); XCTAssertTrue(drained)
        try await manager.release(lease, commandsDrained: drained, ownedRunnerTerminated: true)
        try await manager.releaseCampaign(runID: runID, target: target)
        print("Official read-only inventory: device=\(observation.deviceIdentifier) appsSHA256=\(observation.appsSHA256) processesSHA256=\(observation.processesSHA256); no runner launched")
    }
}
#endif
