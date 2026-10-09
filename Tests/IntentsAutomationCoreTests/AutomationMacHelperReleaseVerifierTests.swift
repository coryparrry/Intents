#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor
final class AutomationMacHelperReleaseVerifierTests: XCTestCase {
    private let uid: UInt32 = 501
    private var target: TargetIdentity { .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login") }
    private var unrelated: AutomationMacProcessInventory.Record {
        .init(identity: .init(pid: 42, startIdentity: "100:0"), userID: uid, executablePath: "/Applications/Other.app/Contents/MacOS/Other")
    }
    private func helper() throws -> AutomationMacHelperReleaseVerifier.Helper {
        let requestedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        let root = try AutomationPath.canonical(requestedRoot)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agent-device-macos-helper")
        let data = Data("synthetic helper bytes".utf8); try data.write(to: executable)
        return .init(executable: executable, sha256: AutomationArtifactRegistry.digest(data))
    }
    private func verifier(_ helper: AutomationMacHelperReleaseVerifier.Helper, _ state: InventoryState) throws -> AutomationMacHelperReleaseVerifier {
        try .init(helpers: [helper], loginSession: "synthetic-login", userID: uid,
                  inspector: { try await state.inspect() }, drain: { await state.drained() })
    }
    private actor FailureInspector {
        let clean: AutomationMacProcessInventory, failure: AutomationMacProcessInventory.KernelObservationFailure
        var calls = 0
        init(clean: AutomationMacProcessInventory, failure: AutomationMacProcessInventory.KernelObservationFailure) { self.clean = clean; self.failure = failure }
        func inspect() throws -> AutomationMacProcessInventory { calls += 1; if calls == 1 { return clean }; throw failure }
    }
    func testTypedParentStateFailureIsRetainedWithoutPartialInventoryOrAcceptance() async throws {
        for status in [UInt32(5), 2] {
            let facts = AutomationMacProcessInventory.ProcessFacts(pid: 55592, parentPID: 55434, userID: uid, status: status, startIdentity: "100:0")
            let failure = AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: 55592, errorNumber: EPERM, process: facts)
            let state = FailureInspector(clean: .init(userID: uid, complete: true, processes: [unrelated]), failure: failure)
            let item = try helper(), reader = try AutomationMacHelperReleaseVerifier(helpers: [item], loginSession: "synthetic-login", userID: uid,
                inspector: { try await state.inspect() }, drain: { true })
            try await reader.prepare(target: target, controllerBundleIDs: [])
            let released = await reader.verifyReleased(target: target, controllerBundleIDs: []); XCTAssertFalse(released)
            let observations = await reader.retainedObservations(), last = try XCTUnwrap(observations.last)
            XCTAssertFalse(last.accepted); XCTAssertNil(last.inventory); XCTAssertEqual(last.failure?.process, facts)
            let decoded = try JSONDecoder().decode(AutomationMacHelperReleaseVerifier.Observation.self, from: JSONEncoder().encode(last))
            XCTAssertEqual(decoded.failure, failure); XCTAssertEqual(decoded.failure?.process?.awaitingParentCollection, status == 5)
        }
    }
    func testExactHelperAbsenceBeforeAndAfterIsIndependentOfUnrelatedApps() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = InventoryState(frames: [frame, frame]), reader = try verifier(item, state)
        try await reader.prepare(target: target, controllerBundleIDs: [])
        let released = await reader.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertTrue(released)
        let observations = await reader.retainedObservations()
        XCTAssertEqual(observations.map(\.stage), ["prepare", "release"]); XCTAssertTrue(observations.allSatisfy(\.accepted))
        XCTAssertEqual(observations.first?.inventory?.processes, [unrelated])
    }
    func testMatchingExecutablePathBlocksPrepareAndReleaseRegardlessOfPIDReuse() async throws {
        let item = try helper(), clean = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        for start in ["100:0", "101:0"] {
            let live = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated,
                .init(identity: .init(pid: 43, startIdentity: start), userID: uid, executablePath: item.executable.path)])
            let busyReader = try verifier(item, InventoryState(frames: [live]))
            do { try await busyReader.prepare(target: target, controllerBundleIDs: []); XCTFail("Live helper admitted") } catch {}
            let reader = try verifier(item, InventoryState(frames: [clean, live]))
            try await reader.prepare(target: target, controllerBundleIDs: [])
            let released = await reader.verifyReleased(target: target, controllerBundleIDs: [])
            XCTAssertFalse(released)
        }
    }
    func testIncompleteEmptyWrongUIDAndMalformedRecordsCannotProveAbsence() throws {
        let good = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        try good.validate(expectedUserID: uid)
        for bad in [AutomationMacProcessInventory(userID: uid, complete: false, processes: [unrelated]),
                    .init(userID: uid, complete: true, processes: []),
                    .init(userID: uid + 1, complete: true, processes: [unrelated]),
                    .init(userID: uid, complete: true, processes: [unrelated, unrelated])] {
            XCTAssertThrowsError(try bad.validate(expectedUserID: uid))
        }
        for identity in [AutomationProcessIdentity(pid: 0, startIdentity: "100:0"),
                         .init(pid: 1, startIdentity: "0:0"), .init(pid: 1, startIdentity: "100:1000000"),
                         .init(pid: 1, startIdentity: "100:00"), .init(pid: 1, startIdentity: "18446744073709551616:0")] {
            let bad = AutomationMacProcessInventory(userID: uid, complete: true, processes: [.init(identity: identity, userID: uid, executablePath: unrelated.executablePath)])
            XCTAssertThrowsError(try bad.validate(expectedUserID: uid))
        }
        for path in ["relative", "/Applications/../Other", "/Applications//Other", "/Applications/Other\0"] {
            let bad = AutomationMacProcessInventory(userID: uid, complete: true, processes: [.init(identity: unrelated.identity, userID: uid, executablePath: path)])
            XCTAssertThrowsError(try bad.validate(expectedUserID: uid))
        }
    }
    func testTargetAndControllerScopeMustMatchPreparedLocalMac() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = InventoryState(frames: [frame]), reader = try verifier(item, state)
        for wrong in [TargetIdentity(id: "other", kind: .nativeMac, loginSession: "synthetic-login"),
                      .init(id: target.id, kind: .physical), .init(id: target.id, kind: .nativeMac, loginSession: "other")] {
            do { try await reader.prepare(target: wrong, controllerBundleIDs: []); XCTFail("Invalid scope admitted") } catch {}
        }
        do { try await reader.prepare(target: target, controllerBundleIDs: ["example.Controller"]); XCTFail("Ignored bundle scope") } catch {}
        let queries = await state.calls(); XCTAssertEqual(queries, 0)
        try await reader.prepare(target: target, controllerBundleIDs: [])
        var wrong = target; wrong.loginSession = "other"
        let released = await reader.verifyReleased(target: wrong, controllerBundleIDs: [])
        XCTAssertFalse(released)
    }
    func testHelperBytesAreBoundAgainBeforeReleaseInspection() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = InventoryState(frames: [frame, frame]), reader = try verifier(item, state)
        try await reader.prepare(target: target, controllerBundleIDs: [])
        try Data("changed helper".utf8).write(to: item.executable)
        let released = await reader.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(released); let queries = await state.calls(); XCTAssertEqual(queries, 1)
    }
    func testUnprovedInspectorDrainLatchesAndNeverStartsAnotherInspection() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = InventoryState(frames: [frame, frame], drains: [false, true]), reader = try verifier(item, state)
        do { try await reader.prepare(target: target, controllerBundleIDs: []); XCTFail("Unproved drain admitted") } catch {}
        do { try await reader.prepare(target: target, controllerBundleIDs: []); XCTFail("Latched reader reused") } catch {}
        let released = await reader.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(released); let queries = await state.calls(); XCTAssertEqual(queries, 1)
    }
    func testAliasDigestAndDuplicateHelperDescriptorsAreRejected() throws {
        let item = try helper()
        XCTAssertThrowsError(try AutomationMacHelperReleaseVerifier(helpers: [item, item], loginSession: "synthetic-login"))
        XCTAssertThrowsError(try AutomationMacHelperReleaseVerifier(helpers: [.init(executable: item.executable, sha256: String(repeating: "0", count: 64))], loginSession: "synthetic-login"))
        let alias = item.executable.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: item.executable)
        XCTAssertThrowsError(try AutomationMacHelperReleaseVerifier(helpers: [.init(executable: alias, sha256: item.sha256)], loginSession: "synthetic-login"))
    }
    func testReentrantCallsDuringInspectionOrDrainCannotStartAnotherInspection() async throws {
        for suspendDrain in [false, true] {
            let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
            let gate = InventoryGate(frame: frame, suspendDrain: suspendDrain)
            let reader = try AutomationMacHelperReleaseVerifier(helpers: [item], loginSession: "synthetic-login", userID: uid,
                inspector: { await gate.inspect() }, drain: { await gate.drain() })
            let selected = target
            let preparing = Task { try await reader.prepare(target: selected, controllerBundleIDs: []) }
            await gate.waitUntilEntered()
            let earlyRelease = await reader.verifyReleased(target: selected, controllerBundleIDs: [])
            XCTAssertFalse(earlyRelease)
            do { try await reader.prepare(target: selected, controllerBundleIDs: []); XCTFail("Reentrant preparation admitted") } catch {}
            let calls = await gate.calls(); XCTAssertEqual(calls, 1)
            await gate.resume()
            try await preparing.value
            let released = await reader.verifyReleased(target: selected, controllerBundleIDs: [])
            XCTAssertTrue(released)
        }
    }
    func testObservationExhaustionCannotGrowEvidenceOrInspectAgain() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let state = InventoryState(frames: Array(repeating: frame, count: 65)), reader = try verifier(item, state)
        try await reader.prepare(target: target, controllerBundleIDs: [])
        for _ in 0..<63 {
            let released = await reader.verifyReleased(target: target, controllerBundleIDs: [])
            XCTAssertTrue(released)
        }
        let exhausted = await reader.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(exhausted)
        let calls = await state.calls(), observations = await reader.retainedObservations()
        XCTAssertEqual(calls, 64); XCTAssertEqual(observations.count, 64)
    }
    func testReleaseDrainFailureAndThrowingInspectorPermanentlyLatch() async throws {
        for throwInspection in [false, true] {
            let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
            let state = InventoryState(frames: throwInspection ? [frame] : [frame, frame], drains: [true, false, true])
            let reader = try verifier(item, state)
            try await reader.prepare(target: target, controllerBundleIDs: [])
            let first = await reader.verifyReleased(target: target, controllerBundleIDs: [])
            let second = await reader.verifyReleased(target: target, controllerBundleIDs: [])
            XCTAssertFalse(first); XCTAssertFalse(second)
            do { try await reader.prepare(target: target, controllerBundleIDs: []); XCTFail("Unproved reader reused") } catch {}
            let calls = await state.calls(), observations = await reader.retainedObservations()
            XCTAssertEqual(calls, 2); XCTAssertEqual(observations.count, 2); XCTAssertEqual(observations.last?.accepted, false)
        }
    }
    func testHelperMutationDuringInspectionAndMalformedInventoryAreRetainedFailures() async throws {
        let item = try helper(), frame = AutomationMacProcessInventory(userID: uid, complete: true, processes: [unrelated])
        let reader = try AutomationMacHelperReleaseVerifier(helpers: [item], loginSession: "synthetic-login", userID: uid,
            inspector: { try Data("modified inside inspector".utf8).write(to: item.executable); return frame }, drain: { true })
        do { try await reader.prepare(target: target, controllerBundleIDs: []); XCTFail("Changed helper admitted") } catch {}
        let changed = await reader.retainedObservations()
        XCTAssertEqual(changed.count, 1); XCTAssertEqual(changed.last?.accepted, false)
        let cleanItem = try helper(), malformed = AutomationMacProcessInventory(userID: uid, complete: false, processes: [unrelated])
        let badReader = try verifier(cleanItem, InventoryState(frames: [malformed]))
        do { try await badReader.prepare(target: target, controllerBundleIDs: []); XCTFail("Incomplete inventory admitted") } catch {}
        let rejected = await badReader.retainedObservations()
        XCTAssertEqual(rejected.last?.inventory?.complete, false); XCTAssertEqual(rejected.last?.accepted, false)
    }
}

private actor InventoryGate {
    private let frame: AutomationMacProcessInventory
    private let suspendDrain: Bool
    private var entered = false, resumed = false
    private var queried = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    init(frame: AutomationMacProcessInventory, suspendDrain: Bool) { self.frame = frame; self.suspendDrain = suspendDrain }
    func inspect() async -> AutomationMacProcessInventory {
        queried += 1
        if !suspendDrain { await pause() }
        return frame
    }
    func drain() async -> Bool { if suspendDrain { await pause() }; return true }
    private func pause() async {
        if resumed { return }
        entered = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() { resumed = true; blocked?.resume(); blocked = nil }
    func calls() -> Int { queried }
}

private actor InventoryState {
    private var frames: [AutomationMacProcessInventory]
    private var drains: [Bool]
    private var queried = 0
    init(frames: [AutomationMacProcessInventory], drains: [Bool] = []) { self.frames = frames; self.drains = drains }
    func inspect() throws -> AutomationMacProcessInventory {
        queried += 1
        guard !frames.isEmpty else { throw AutomationContractError.terminationUnverified }
        return frames.removeFirst()
    }
    func drained() -> Bool { drains.isEmpty ? true : drains.removeFirst() }
    func calls() -> Int { queried }
}
#endif
