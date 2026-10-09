import XCTest
@testable import IntentsAutomationCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AutomationOwnershipTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testDurableGenerationsAndLiveOwnerSurviveManagerReopen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json"), target = TargetIdentity(id: "simulator", kind: .simulator)
        let first = try AutomationDeviceLeaseManager(storeURL: url)
        let lease = try await first.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        try await first.recordDispatch(.init(scope: scope, operationID: "setup", payloadDigest: String(repeating: "a", count: 64)), lease: lease)
        let second = try AutomationDeviceLeaseManager(storeURL: url)
        do { _ = try await second.acquire(runID: "run", target: target, control: .system); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let records = try await second.recoveryRecords(); XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.lastDispatch?.operationID, "setup")
        do { try await second.reconcile(records[0], commandsDrained: true, ownedRunnerTerminated: true); XCTFail("A live process cannot be reclaimed") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await first.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        do { _ = try await second.acquire(runID: "other", target: target, control: .ui); XCTFail("Campaign persists between controllers") } catch {}
        let system = try await first.acquire(runID: "run", target: target, control: .system)
        XCTAssertEqual(system.generation, 2)
        try await first.release(system, commandsDrained: true, ownedRunnerTerminated: true)
        try await first.releaseCampaign(runID: "run", target: target)
        let next = try await second.acquire(runID: "next", target: target, control: .ui)
        XCTAssertEqual(next.generation, 3)
        let current = await first.isCurrent(lease); XCTAssertFalse(current)
    }
    func testNativeMacLeaseSerializesTheLoginSessionAcrossBackendIDs() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("leases.json")
        let first = try AutomationDeviceLeaseManager(storeURL: url), second = try AutomationDeviceLeaseManager(storeURL: url)
        _ = try await first.acquire(runID: "first", target: .init(id: "mac-a", kind: .nativeMac, loginSession: "login"), control: .ui)
        do { _ = try await second.acquire(runID: "second", target: .init(id: "mac-b", kind: .nativeMac, loginSession: "login"), control: .ui); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
    }
    func testRealChildExitRequiresExplicitReleaseProofAndKeepsAmbiguousJournal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let child = Process(), output = Pipe(), input = Pipe()
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        child.executableURL = directory.appendingPathComponent("IntentsAutomationOwnershipProbe")
        child.arguments = [root.path]; child.standardOutput = output; child.standardInput = input
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("1".utf8))
        let identity = try XCTUnwrap(AutomationProcessIdentity.inspect(pid: child.processIdentifier))
        XCTAssertEqual(identity.presence(), .matching)
        XCTAssertEqual(AutomationProcessIdentity(pid: identity.pid, startIdentity: "different-start").presence(), .replaced)
        let target = TargetIdentity(id: "device", kind: .simulator)
        let manager = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let records = try await manager.recoveryRecords()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].owner, identity)
        XCTAssertEqual(records[0].lastDispatch?.operationID, "subject")
        do { _ = try await manager.acquire(runID: "new", target: target, control: .system); XCTFail("Another process owns this campaign") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try input.fileHandleForWriting.write(contentsOf: Data("1".utf8)); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0); XCTAssertEqual(identity.presence(), .absent)
        do { try await manager.reconcile(records[0], commandsDrained: true, ownedRunnerTerminated: false); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        try await manager.reconcile(records[0], commandsDrained: true, ownedRunnerTerminated: true)
        do { try await manager.reconcile(records[0], commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Old recovery record must be stale") } catch {}
        let next = try await manager.acquire(runID: "new", target: target, control: .system); XCTAssertEqual(next.generation, 2)
        let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
        do { _ = try await journal.begin(operationID: "subject", digest: String(repeating: "a", count: 64)); XCTFail("Recovery never retries a pending mutation") }
        catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
        let unresolved = try await journal.unresolvedEntries(); XCTAssertEqual(unresolved.count, 1)
    }
    func testDeadOwnerRecoveryInspectorRemainsFencedAfterManagerReopen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = Process(), output = Pipe(), input = Pipe()
        owner.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("IntentsAutomationOwnershipProbe")
        owner.arguments = [root.path, "physical"]; owner.standardOutput = output; owner.standardInput = input
        try owner.run(); defer { if owner.isRunning { owner.terminate(); owner.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("1".utf8))
        let url = root.appendingPathComponent("leases.json"), manager = try AutomationDeviceLeaseManager(storeURL: url)
        let initialRecords = try await manager.recoveryRecords()
        let initial = try XCTUnwrap(initialRecords.first)
        let inspector = Process(); inspector.executableURL = URL(fileURLWithPath: "/bin/sleep"); inspector.arguments = ["60"]
        try inspector.run(); defer { if inspector.isRunning { inspector.terminate(); inspector.waitUntilExit() } }
        let process = try XCTUnwrap(AutomationProcessIdentity.inspect(pid: inspector.processIdentifier))
        let runner = AutomationDeviceLeaseManager.OwnedRunner(scope: try XCTUnwrap(initial.lastDispatch?.scope),
            process: process, role: .nativeCommand, executablePath: "/usr/bin/xcrun")
        do { _ = try await manager.recordRecoveryInspector(runner, record: initial); XCTFail("Live owner cannot grant recovery") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try input.fileHandleForWriting.write(contentsOf: Data("1".utf8)); owner.waitUntilExit()
        let tracked = try await manager.recordRecoveryInspector(runner, record: initial)
        XCTAssertEqual(tracked.lastDispatch, initial.lastDispatch)
        let reopened = try AutomationDeviceLeaseManager(storeURL: url)
        let durableRecords = try await reopened.recoveryRecords()
        let durable = try XCTUnwrap(durableRecords.first)
        XCTAssertEqual(durable, tracked)
        do { try await reopened.reconcile(durable, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Unproved child survives manager restart") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        do { _ = try await reopened.recordRecoveryInspector(runner, record: initial); XCTFail("Stale authority cannot append") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        inspector.terminate(); inspector.waitUntilExit()
        try await reopened.reconcile(durable, commandsDrained: true, ownedRunnerTerminated: true)
        let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
        do { _ = try await journal.begin(operationID: "subject", digest: String(repeating: "a", count: 64)); XCTFail("Recovery never authorises repetition") }
        catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
    }
    func testTamperedLeaseStoreFailsClosedForEveryDurableInvariant() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("target-leases.json"), target = TargetIdentity(id: "simulator", kind: .simulator)
        let manager = try AutomationDeviceLeaseManager(storeURL: url)
        let lease = try await manager.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let dispatch = AutomationDeviceLeaseManager.Dispatch(scope: scope, operationID: "setup", payloadDigest: String(repeating: "a", count: 64))
        try await manager.recordDispatch(dispatch, lease: lease)
        try await manager.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand, executablePath: "/usr/bin/true"), lease: lease)
        let original = try Data(contentsOf: url), key = target.leaseKey
        let valid = try JSONDecoder().decode(AutomationLeaseState.self, from: original)
        XCTAssertEqual(valid.generations[key], lease.generation)
        let runner = try XCTUnwrap(valid.campaigns[key]?.runners.first); XCTAssertEqual(valid.campaigns[key]?.runners.count, 1)
        let payload = AutomationDeviceLeaseManager.PrivatePayload(scope: scope, path: root.appendingPathComponent("host.xctestrun").path,
            frozenDigest: String(repeating: "b", count: 64), cleanDigest: String(repeating: "c", count: 64))
        func tampered(_ mutate: (inout AutomationLeaseState) -> Void) -> AutomationLeaseState { var state = valid; mutate(&state); return state }
        // Boundary controls: each rejected case below differs from an accepted state by one field.
        XCTAssertNoThrow(try tampered { $0.campaigns[key]?.privatePayload = payload }.validate())
        XCTAssertNoThrow(try tampered { $0.campaigns[key]?.runners = Array(repeating: runner, count: 16) }.validate())
        let cases: [(String, (inout AutomationLeaseState) -> Void)] = [
            ("unsupported schema version", { $0.schemaVersion = 2 }),
            ("campaign stored under another target's key", { $0.campaigns["ios:other"] = $0.campaigns.removeValue(forKey: key); $0.generations["ios:other"] = lease.generation }),
            ("missing generation entry", { $0.generations.removeValue(forKey: key) }),
            ("non-positive generation", { $0.generations[key] = 0 }),
            ("empty generation key", { $0.generations[""] = 1 }),
            ("lease generation differs from durable generation", { $0.campaigns[key]?.lease?.generation += 1 }),
            ("lease for another run", { $0.campaigns[key]?.lease?.runID = "other" }),
            ("lease for another target", { $0.campaigns[key]?.lease?.target = .init(id: "other", kind: .simulator) }),
            ("empty owner token", { $0.campaigns[key]?.ownerToken = "" }),
            ("missing owner process", { $0.campaigns[key]?.owner.pid = 0 }),
            ("private payload without a lease", { $0.campaigns[key]?.lease = nil; $0.campaigns[key]?.privatePayload = payload }),
            ("private payload for another lease generation", { $0.campaigns[key]?.privatePayload = .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation + 1), path: payload.path, frozenDigest: payload.frozenDigest, cleanDigest: payload.cleanDigest) }),
            ("private payload outside an xctestrun", { $0.campaigns[key]?.privatePayload = .init(scope: scope, path: root.appendingPathComponent("host.plist").path, frozenDigest: payload.frozenDigest, cleanDigest: payload.cleanDigest) }),
            ("dispatch for another run", { $0.campaigns[key]?.lastDispatch?.scope.runId = "other" }),
            ("dispatch scope above the current generation", { $0.campaigns[key]?.lastDispatch?.scope.leaseGeneration = lease.generation + 1 }),
            ("dispatch with a non-hex digest", { $0.campaigns[key]?.lastDispatch?.payloadDigest = String(repeating: "g", count: 64) }),
            ("dispatch without an operation", { $0.campaigns[key]?.lastDispatch?.operationID = "" }),
            ("runner scope above the current generation", { $0.campaigns[key]?.runners[0].scope.leaseGeneration = lease.generation + 1 }),
            ("runner for another run", { $0.campaigns[key]?.runners[0].scope.runId = "other" }),
            ("runner with a relative executable", { $0.campaigns[key]?.runners[0].executablePath = "usr/bin/true" }),
            ("seventeen runners", { $0.campaigns[key]?.runners = Array(repeating: runner, count: 17) }),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (name, mutate) in cases {
            let state = tampered(mutate)
            XCTAssertThrowsError(try state.validate(), name) { XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity, name) }
            let bytes = try encoder.encode(state)
            try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertThrowsError(try AutomationDeviceLeaseManager(storeURL: url), name) { XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity, name) }
            let current = await manager.isCurrent(lease); XCTAssertFalse(current, name)
            do { _ = try await manager.recoveryRecords(); XCTFail(name) }
            catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity, name) }
            do { try await manager.recordDispatch(dispatch, lease: lease); XCTFail(name) }
            catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity, name) }
            XCTAssertEqual(try Data(contentsOf: url), bytes, "A rejected transaction must not rewrite the tampered store: \(name)")
            try original.write(to: url)
            let restored = await manager.isCurrent(lease); XCTAssertTrue(restored, name)
        }
    }
    func testPrivateStoreRejectsSymlinksOversizeAndForeignLockPermissions() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim.json"); try Data("{}".utf8).write(to: victim)
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: victim)
        XCTAssertThrowsError(try AutomationDeviceLeaseManager(storeURL: alias))
        XCTAssertEqual(try Data(contentsOf: victim), Data("{}".utf8))
        let huge = root.appendingPathComponent("huge.json"); try Data(repeating: 32, count: 1_048_577).write(to: huge)
        XCTAssertThrowsError(try AutomationDeviceLeaseManager(storeURL: huge))
        let writable = root.appendingPathComponent("writable.json"); try Data("{}".utf8).write(to: writable)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: writable.path)
        XCTAssertThrowsError(try AutomationDeviceLeaseManager(storeURL: writable))
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
        XCTAssertThrowsError(try AutomationDeviceLeaseManager(storeURL: unsafe.appendingPathComponent("lease.json")))
        let file = try AutomationDurableFile(url: root.appendingPathComponent("store.json"), maximumBytes: 10)
        try Data().write(to: URL(fileURLWithPath: file.url.path + ".lock"))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.url.path + ".lock")
        XCTAssertThrowsError(try file.withLock { try file.write(Data("{}".utf8)) })
    }
    func testPrivateStoreContendsWithAnActualCrossProcessLock() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try AutomationDurableFile(url: root.appendingPathComponent("store.json"), maximumBytes: 100)
        try file.withLock { try file.write(Data("{}".utf8)) }
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,select; f=open(sys.argv[1], 'r+'); fcntl.flock(f,fcntl.LOCK_EX); sys.stdout.write('1'); sys.stdout.flush(); select.select([sys.stdin],[],[],15)", file.url.path + ".lock"]
        child.standardOutput = output; child.standardInput = input
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("1".utf8))
        XCTAssertThrowsError(try file.withLock {}) { XCTAssertEqual($0 as? AutomationContractError, .targetBusy) }
        try input.fileHandleForWriting.write(contentsOf: Data("1".utf8)); child.waitUntilExit()
        try file.withLock { XCTAssertEqual(try file.read(), Data("{}".utf8)) }
    }
}
