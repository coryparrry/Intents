#if os(macOS)
import Foundation
import Darwin
import XCTest
@testable import IntentsAutomationCore

@MainActor
final class AutomationMacAssociatedHostReleaseVerifierTests: XCTestCase {
    private let uid: UInt32 = 501
    private let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
    private var unrelated: AutomationMacProcessInventory.Record {
        .init(identity: .init(pid: 42, startIdentity: "100:0"), userID: uid, executablePath: "/Applications/Other.app/Contents/MacOS/Other")
    }
    private actor State {
        var frames: [AutomationMacProcessInventory], calls = 0, drained = true
        var failure: AutomationMacProcessInventory.KernelObservationFailure?
        var failures: [Int: AutomationMacProcessInventory.KernelObservationFailure]
        var cancelOnCalls: Set<Int>
        init(_ frames: [AutomationMacProcessInventory],
             failures: [Int: AutomationMacProcessInventory.KernelObservationFailure] = [:],
             cancelOnCalls: Set<Int> = []) {
            self.frames = frames; self.failures = failures; self.cancelOnCalls = cancelOnCalls
        }
        func inspect() throws -> AutomationMacProcessInventory {
            calls += 1
            if cancelOnCalls.contains(calls) { withUnsafeCurrentTask { $0?.cancel() } }
            if let failure = failures[calls] { throw failure }
            if let failure { throw failure }
            return frames[min(calls - 1, frames.count - 1)]
        }
        func setDrained(_ value: Bool) { drained = value }
        func setFailure(_ value: AutomationMacProcessInventory.KernelObservationFailure) { failure = value }
    }
    private func host() throws -> AutomationPreparedAppleHost {
        let root = URL(fileURLWithPath: "/private/tmp/associated-release-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("OwnedHost-Runner.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.OwnedHost.xctrunner",
                                  "CFBundleExecutable": "OwnedHost-Runner", "CFBundleSupportedPlatforms": ["MacOSX"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Contents/MacOS/OwnedHost-Runner"))
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64)); app.productDigestVersion = 2
        return .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "unused",
            hostBundlePath: bundle.path, hostProductDigest: try AutomationProductDigest.compute(bundle: bundle, version: 2), hostBundleID: "example.OwnedHost.xctrunner",
            testTarget: "OwnedHost", hostProductDigestVersion: 2)
    }
    private func reader(_ host: AutomationPreparedAppleHost, _ state: State,
                        validate: @escaping AutomationMacAssociatedHostReleaseVerifier.TargetValidator = { _ in }) throws -> AutomationMacAssociatedHostReleaseVerifier {
        try .init(host: host, userID: uid, inspector: { try await state.inspect() }, drain: { await state.drained }, validateTarget: validate)
    }
    private func live(_ host: AutomationPreparedAppleHost) -> AutomationMacProcessInventory {
        .init(userID: uid, complete: true, processes: [unrelated,
            .init(identity: .init(pid: 43, startIdentity: "100:0"), userID: uid,
                  executablePath: host.hostBundlePath + "/Contents/MacOS/OwnedHost-Runner")])
    }
    private var retryableFailures: [AutomationMacProcessInventory.KernelObservationFailure] {
        [.init(stage: .metadata, pid: 43, errorNumber: ESRCH),
         .init(stage: .executablePath, pid: 43, errorNumber: ESRCH),
         .init(stage: .codeIdentity, pid: 43, errorNumber: ESRCH),
         .init(stage: .executableSetChanged, pid: nil, errorNumber: 0)]
    }
    func testExactHostAbsenceRequiresSeparateCompletePrepareAndReleaseInventories() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean, clean]), verifier = try reader(host, state)
        let withoutPrepare = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(withoutPrepare)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertTrue(released)
        let observations = await verifier.retainedObservations()
        XCTAssertEqual(observations.map(\.stage), ["prepare", "release"]); XCTAssertTrue(observations.allSatisfy(\.accepted))
        XCTAssertEqual(observations.last?.inventory?.processes, [unrelated])
    }
    func testLiveOrReusedPIDAtExactExecutableBlocksBothBoundaries() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for start in ["100:0", "101:0"] {
            let live = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated,
                .init(identity: .init(pid: 43, startIdentity: start), userID: uid, executablePath: host.hostBundlePath + "/Contents/MacOS/OwnedHost-Runner")])
            let busyState = State([live, clean]), busy = try reader(host, busyState)
            do { try await busy.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); XCTFail("Live host admitted") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
            let busyCalls = await busyState.calls; XCTAssertEqual(busyCalls, 1)
            let releaseState = State([clean, live]), verifier = try reader(host, releaseState)
            try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
            let releaseCalls = await releaseState.calls, observations = await verifier.retainedObservations()
            XCTAssertEqual(releaseCalls, 11); XCTAssertEqual(observations.count, 11)
            XCTAssertTrue(observations.dropFirst().allSatisfy { !$0.accepted && $0.failure == nil })
        }
    }
    func testTransientExitAndExecutableSetChangeRequireReplacementInventoriesAtBothBoundaries() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for failure in retryableFailures {
            let state = State([clean], failures: [1: failure, 3: failure]), verifier = try reader(host, state)
            try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertTrue(released)
            let calls = await state.calls, observations = await verifier.retainedObservations()
            XCTAssertEqual(calls, 4); XCTAssertEqual(observations.map(\.stage), ["prepare", "prepare", "release", "release"])
            XCTAssertEqual(observations.map(\.accepted), [false, true, false, true])
            XCTAssertEqual(observations[0].failure, failure); XCTAssertNil(observations[0].inventory)
            XCTAssertEqual(observations[2].failure, failure); XCTAssertNil(observations[2].inventory)
        }
    }
    func testReleaseWaitsForObservedHostExitAndRetainsPresence() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean, live(host), live(host), clean]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertTrue(released)
        let calls = await state.calls, observations = await verifier.retainedObservations()
        XCTAssertEqual(calls, 4); XCTAssertEqual(observations.map(\.accepted), [true, false, false, true])
        XCTAssertEqual(observations[1].inventory, live(host)); XCTAssertEqual(observations[2].inventory, live(host))
    }
    func testPersistentKernelRaceIsBoundedAtBothBoundaries() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for prepareFailure in [true, false] {
            let state = State([clean]), verifier = try reader(host, state)
            if !prepareFailure { try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]) }
            let failure = retryableFailures[0]; await state.setFailure(failure)
            if prepareFailure {
                do { try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); XCTFail("Exhausted race admitted") }
                catch { XCTAssertEqual(error as? AutomationMacProcessInventory.KernelObservationFailure, failure) }
                let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
            } else {
                let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
            }
            let calls = await state.calls, observations = await verifier.retainedObservations()
            XCTAssertEqual(calls, prepareFailure ? 10 : 11); XCTAssertEqual(observations.count, calls)
            XCTAssertEqual(observations.filter { $0.failure == failure }.count, 10)
            XCTAssertTrue(observations.suffix(10).allSatisfy { !$0.accepted && $0.inventory == nil })
        }
    }
    func testPermissionAndOtherKernelStagesNeverRetryIntoCleanInventory() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let failures: [AutomationMacProcessInventory.KernelObservationFailure] = [
            .init(stage: .executablePath, pid: 43, errorNumber: EPERM),
            .init(stage: .metadata, pid: 43, errorNumber: EACCES),
            .init(stage: .codeIdentity, pid: 43, errorNumber: EPERM),
            .init(stage: .identityFields, pid: 43, errorNumber: ESRCH),
            .init(stage: .pidList, pid: nil, errorNumber: ESRCH),
            .init(stage: .absenceUnconfirmed, pid: 43, errorNumber: ESRCH),
            .init(stage: .executableSetChanged, pid: nil, errorNumber: ESRCH)]
        for failure in failures {
            let state = State([clean], failures: [2: failure]), verifier = try reader(host, state)
            try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
            let calls = await state.calls, observations = await verifier.retainedObservations()
            XCTAssertEqual(calls, 2); XCTAssertEqual(observations.count, 2)
            XCTAssertEqual(observations.last?.failure, failure); XCTAssertFalse(observations.last?.accepted ?? true)
        }
    }
    func testTransientKernelFailureWithUnprovedDrainCannotRetryOrReuse() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean], failures: [2: retryableFailures[0]]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); await state.setDrained(false)
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
        await state.setDrained(true)
        let reused = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(reused)
        do { try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); XCTFail("Unproved inspector reused") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let calls = await state.calls, observations = await verifier.retainedObservations()
        XCTAssertEqual(calls, 2); XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.last?.failure, retryableFailures[0]); XCTAssertFalse(observations.last?.accepted ?? true)
    }
    func testCancellationDuringReleaseCensusCannotAcceptOrRetry() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean], cancelOnCalls: [2]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let release = Task { await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]) }
        let released = await release.value; XCTAssertFalse(released)
        let calls = await state.calls, observations = await verifier.retainedObservations()
        XCTAssertEqual(calls, 2); XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.last?.inventory, clean); XCTAssertFalse(observations.last?.accepted ?? true)
    }
    func testReplacementCensusRevalidatesPreparedHostProduct() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean]), failure = retryableFailures[0]
        let executable = URL(fileURLWithPath: host.hostBundlePath).appendingPathComponent("Contents/MacOS/OwnedHost-Runner")
        let verifier = try AutomationMacAssociatedHostReleaseVerifier(host: host, userID: uid, inspector: {
            let inventory = try await state.inspect()
            if await state.calls == 2 {
                try Data("changed during rejected census".utf8).write(to: executable)
                throw failure
            }
            return inventory
        }, drain: { true }, validateTarget: { _ in })
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
        let calls = await state.calls, observations = await verifier.retainedObservations()
        XCTAssertEqual(calls, 2); XCTAssertEqual(observations.count, 3)
        XCTAssertEqual(observations[1].failure, failure); XCTAssertFalse(observations[1].accepted)
        XCTAssertNil(observations[2].inventory); XCTAssertNil(observations[2].failure); XCTAssertFalse(observations[2].accepted)
    }
    func testMalformedReleaseInventoryNeverRetriesIntoCleanInventory() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for invalid in [AutomationMacProcessInventory(userID: uid, complete: false, processes: [unrelated]),
                        AutomationMacProcessInventory(userID: uid + 1, complete: true, processes: [unrelated])] {
            let state = State([clean, invalid, clean]), verifier = try reader(host, state)
            try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
            let calls = await state.calls, observations = await verifier.retainedObservations()
            XCTAssertEqual(calls, 2); XCTAssertEqual(observations.last?.inventory, invalid)
            XCTAssertFalse(observations.last?.accepted ?? true)
        }
    }
    func testTotalObservationBudgetCannotBeExtendedByRepeatedReleaseChecks() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        for _ in 0..<63 {
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertTrue(released)
        }
        let exhausted = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(exhausted)
        let calls = await state.calls, observations = await verifier.retainedObservations()
        XCTAssertEqual(calls, 64); XCTAssertEqual(observations.count, 64)
    }
    func testCompleteUIDAndExactBundleSessionScopesAreRequired() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for frame in [AutomationMacProcessInventory(userID: uid, complete: false, processes: [unrelated]),
                      AutomationMacProcessInventory(userID: uid + 1, complete: true, processes: [unrelated]),
                      AutomationMacProcessInventory(userID: uid, complete: true, processes: [])] {
            let verifier = try reader(host, State([frame]))
            do { try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); XCTFail("Invalid inventory admitted") } catch {}
        }
        for bundleIDs in [[], ["foreign"], [host.hostBundleID, host.hostBundleID]] {
            let state = State([clean]), verifier = try reader(host, state)
            do { try await verifier.prepare(target: target, controllerBundleIDs: bundleIDs); XCTFail("Wrong controller scope admitted") } catch {}
            let count = await state.calls; XCTAssertEqual(count, 0)
        }
        var other = target; other.loginSession = "other"
        let verifier = try reader(host, State([clean, clean])); try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let released = await verifier.verifyReleased(target: other, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
    }
    func testUndrainedInspectorPermanentlyWithholdsRelease() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]); await state.setDrained(false)
        let first = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(first)
        await state.setDrained(true)
        let next = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(next)
        let count = await state.calls; XCTAssertEqual(count, 2)
    }
    func testZombieFailureIsRetainedWithoutPartialAcceptance() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        let facts = AutomationMacProcessInventory.ProcessFacts(pid: 55592, parentPID: 55434, userID: uid, status: 5, startIdentity: "100:0")
        let failure = AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: 55592, errorNumber: 1, process: facts)
        await state.setFailure(failure)
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
        let last = await verifier.retainedObservations().last; XCTAssertNil(last?.inventory); XCTAssertEqual(last?.failure, failure); XCTAssertEqual(last?.accepted, false)
    }
    func testChangedHostOrGUIIdentityCannotProduceRelease() async throws {
        let host = try host(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = State([clean, clean]), verifier = try reader(host, state)
        try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID])
        try Data("changed".utf8).write(to: URL(fileURLWithPath: host.hostBundlePath).appendingPathComponent("Contents/MacOS/OwnedHost-Runner"))
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [host.hostBundleID]); XCTAssertFalse(released)
        let count = await state.calls; XCTAssertEqual(count, 1)
        let second = try self.host(), blocked = State([clean])
        let gui = try reader(second, blocked, validate: { _ in throw AutomationContractError.conflictingOperation })
        do { try await gui.prepare(target: target, controllerBundleIDs: [second.hostBundleID]); XCTFail("Stale GUI target admitted") } catch {}
        let blockedCount = await blocked.calls; XCTAssertEqual(blockedCount, 0)
        var wrong = second; wrong.hostProductDigestVersion = nil
        XCTAssertThrowsError(try reader(wrong, State([clean])))
    }
    func testCancelledAdmissionDoesNotInspectOrAccept() async throws {
        let host = try host(), state = State([.init(userID: uid, complete: true, processes: [unrelated])]), verifier = try reader(host, state)
        let task = Task { try await verifier.prepare(target: target, controllerBundleIDs: [host.hostBundleID]) }; task.cancel()
        do { try await task.value; XCTFail("Cancelled preparation admitted") } catch {}
        let count = await state.calls; XCTAssertEqual(count, 0)
    }
}
#endif
