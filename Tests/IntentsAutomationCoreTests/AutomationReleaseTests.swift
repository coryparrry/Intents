#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationReleaseTests: XCTestCase {
    func testLoadedDeviceRunnerIsNotReleasedEvenWithoutItsDaemonOrPID() throws {
        let prefix = "PID\tStatus\tLabel\n"
        let runner = "UIKitApplication:com.callstack.agentdevice.runner.uitests.xctrunner[1895][rb-legacy]"
        XCTAssertEqual(try AutomationSimulatorReleaseVerifier.parseRunnerJobs(Data((prefix + "1772\t0\t" + runner + "\n").utf8)), [1772])
        XCTAssertEqual(try AutomationSimulatorReleaseVerifier.parseRunnerJobs(Data((prefix + "-\t0\t" + runner + "\n").utf8)), [-1])
        XCTAssertEqual(try AutomationSimulatorReleaseVerifier.parseRunnerJobs(Data((prefix + "24\t0\tUIKitApplication:com.example.Subject[1]\n").utf8)), [])
    }
    func testActualOwnedSimulatorRetainedRunnerCannotBeReportedReleased() async throws {
        guard let targetID = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_RELEASE_TEST_TARGET"] else { throw XCTSkip("No explicit owned simulator inventory profile") }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = AutomationSimulatorReleaseVerifier(developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), workspace: root)
        let released = await verifier.verifyReleased(target: TargetIdentity(id: targetID, kind: .simulator), controllerBundleIDs: [])
        XCTAssertFalse(released, "This explicit engineering profile intentionally retains a positively observed SDK runner")
    }
    func testMalformedOrIncompleteInventoryNeverProvesRelease() {
        for text in ["", "PID\tStatus\tLabel", "PID\tStatus\tLabel\n0\t0\tapp\n", "PID\tStatus\tLabel\n123\t0\tapp", "PID\tStatus\tLabel\n123\t0\n"] {
            XCTAssertThrowsError(try AutomationSimulatorReleaseVerifier.parseRunnerJobs(Data(text.utf8)))
        }
        XCTAssertThrowsError(try AutomationSimulatorReleaseVerifier.parseRunnerJobs(Data([0xff])))
    }
    func testFailedInspectionRetainsDiagnosticsWithoutGrantingRelease() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let verifier = AutomationSimulatorReleaseVerifier(developerDirectory: root.appendingPathComponent("MissingXcode"), workspace: root)
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(released)
        let file = root.appendingPathComponent("release-inspection.json")
        let record = try JSONDecoder().decode(AutomationSimulatorReleaseVerifier.Inspection.self, from: Data(contentsOf: file))
        XCTAssertFalse(record.completed); XCTAssertEqual(record.targetID, target.id)
        XCTAssertNotNil(record.error); XCTAssertEqual(record.exitStatus, -1)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let again = await verifier.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(again)
        let history = root.appendingPathComponent("release-inspections")
        let records = try FileManager.default.contentsOfDirectory(atPath: history.path).filter { $0.hasSuffix(".json") }.map {
            try JSONDecoder().decode(AutomationSimulatorReleaseVerifier.Inspection.self, from: Data(contentsOf: history.appendingPathComponent($0)))
        }
        XCTAssertEqual(records.map(\.ordinal).sorted(), [1, 2])
        XCTAssertTrue(records.allSatisfy { !$0.completed && $0.stage == "verify" })
    }
    func testFailedLeaseReleaseRetainsTheExactDecisionGateAndKernelPresence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let lease = try await manager.acquire(runID: "source-fixture", target: .init(id: UUID().uuidString, kind: .simulator), control: .system)
        let scope = AutomationScope(runID: lease.runID, attemptID: "attempt", segmentID: "prepare.install", leaseGeneration: lease.generation)
        // Contract data only: a live PID prevents proof; this test never signals or runs a controller.
        try await manager.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand, executablePath: "/usr/bin/true"), lease: lease)
        for terminated in [true, false] {
            do { try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: terminated); XCTFail("Failed proof released ownership") }
            catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        }
        let directory = root.appendingPathComponent("release-failures")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        let records = try names.map { try JSONDecoder().decode(AutomationLeaseReleaseDiagnostics.Record.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
        XCTAssertEqual(Set(records.map(\.failedGate)), ["runnerPresence", "controllerTermination"])
        XCTAssertTrue(records.allSatisfy { $0.lease == lease && $0.runners.first?.presence == "matching" })
        let held = await manager.isCurrent(lease); XCTAssertTrue(held)
    }
}
#endif
