#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationBootReleaseTests: XCTestCase {
    private let target = TargetIdentity(id: "157CA066-44BD-46F1-9803-F3B061AFF8A8", kind: .simulator)

    func testOnlyExactApprovedSuccessfulBootCanSkipRemoteControllerInspection() throws {
        let result = try completedResult()
        let arguments = ["simctl", "boot", target.id]
        XCTAssertTrue(allows(arguments, result: result))
        for altered in [
            ["simctl", "install", target.id, "/tmp/app.app"],
            ["simctl", "launch", target.id, "example.subject"],
            ["simctl", "bootstatus", target.id],
            ["simctl", "boot", UUID().uuidString],
            ["simctl", "boot", "booted"],
            ["simctl", "boot", target.id, "--extra"],
            ["simctl", "spawn", target.id, "launchctl", "list"]
        ] { XCTAssertFalse(allows(altered, result: result), String(describing: altered)) }
        XCTAssertFalse(AutomationApplicationRunner.canReleaseBootCommand(arguments: arguments, operation: "install", target: target, result: result))
        for kind in [TargetIdentity.Kind.physical, .nativeMac] {
            XCTAssertFalse(AutomationApplicationRunner.canReleaseBootCommand(arguments: arguments, operation: "boot",
                target: .init(id: target.id, kind: kind), result: result))
        }
        XCTAssertFalse(AutomationApplicationRunner.canReleaseBootCommand(arguments: ["simctl", "boot", "invalid"], operation: "boot",
            target: .init(id: "invalid", kind: .simulator), result: result))
    }

    func testSuccessfulExitCannotReplaceCapturedAbsentIdentityAndDrainProof() throws {
        let arguments = ["simctl", "boot", target.id]
        let result = try completedResult()
        var invalid = result; invalid.exitStatus = 1
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.logsTruncated = true
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.directChildReaped = false
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.pipesDrained = false
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.callbacksDrained = false
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.ownedIdentity = nil
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.ownedIdentity = .init(pid: 0, startIdentity: "unknown")
        XCTAssertFalse(allows(arguments, result: invalid))
        invalid = result; invalid.ownedIdentity = try .current()
        XCTAssertFalse(allows(arguments, result: invalid))
    }

    func testBootLeaseReleaseRetainsRootReservationThroughReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let competitor = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        try await owner.reserveCampaign(runID: "owner", target: target)
        let boot = try await owner.acquire(runID: "owner", target: target, control: .system)
        let proof = allows(["simctl", "boot", target.id], result: try completedResult())
        try await owner.release(boot, commandsDrained: true, ownedRunnerTerminated: proof)
        do { try await competitor.reserveCampaign(runID: "competitor", target: target); XCTFail("Boot released root campaign") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let readiness = try await owner.acquire(runID: "owner", target: target, control: .system)
        XCTAssertGreaterThan(readiness.generation, boot.generation)
        do { try await competitor.reserveCampaign(runID: "competitor", target: target); XCTFail("Readiness released root campaign") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await owner.release(readiness, commandsDrained: true, ownedRunnerTerminated: true)
        try await owner.releaseCampaign(runID: "owner", target: target)
        try await competitor.reserveCampaign(runID: "competitor", target: target)
        try await competitor.releaseCampaign(runID: "competitor", target: target)
    }

    func testBootExceptionCannotBypassStoredRunnerOrPrivatePayloadProof() async throws {
        for hasLiveRunner in [true, false] {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
            try await owner.reserveCampaign(runID: "owner", target: target)
            let lease = try await owner.acquire(runID: "owner", target: target, control: .system)
            let scope = AutomationScope(runID: "owner", attemptID: "attempt", segmentID: "prepare.boot", leaseGeneration: lease.generation)
            if hasLiveRunner {
                try await owner.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand,
                    executablePath: "/usr/bin/xcrun"), lease: lease)
            } else {
                let path = root.appendingPathComponent("private.xctestrun")
                let bytes = try PropertyListSerialization.data(fromPropertyList: ["Host": [
                    "TestBundlePath": "__TESTROOT__/Host.xctest",
                    "EnvironmentVariables": ["INTENTS_AUTOMATION_UI_PLAN_B64": Data("private binding".utf8).base64EncodedString()]
                ]], format: .xml, options: 0)
                let payload = try AutomationAppleHostPayloadFile(data: bytes, url: path, scope: scope)
                try await owner.recordPrivatePayload(payload, lease: lease)
                try payload.write(bytes)
                XCTAssertNotEqual(payload.recoveryReference.frozenDigest, payload.recoveryReference.cleanDigest)
            }
            let proof = allows(["simctl", "boot", target.id], result: try completedResult())
            do { try await owner.release(lease, commandsDrained: true, ownedRunnerTerminated: proof); XCTFail("Boot bypassed stored ownership proof") }
            catch { XCTAssertEqual(error as? AutomationContractError, hasLiveRunner ? .terminationUnverified : .conflictingOperation) }
            let held = await owner.isCurrent(lease)
            XCTAssertTrue(held)
        }
    }

    private func allows(_ arguments: [String], result: AutomationOwnedCommand.Result) -> Bool {
        AutomationApplicationRunner.canReleaseBootCommand(arguments: arguments, operation: "boot", target: target, result: result)
    }

    private func completedResult() throws -> AutomationOwnedCommand.Result {
        let current = try AutomationProcessIdentity.current()
        // Prove replacement without launching or signalling any process.
        let replaced = AutomationProcessIdentity(pid: current.pid, startIdentity: current.startIdentity + ":replaced")
        return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false,
            ownedIdentity: replaced, directChildReaped: true, pipesDrained: true, callbacksDrained: true)
    }
}
#endif
