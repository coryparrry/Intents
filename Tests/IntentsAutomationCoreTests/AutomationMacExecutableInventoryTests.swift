#if os(macOS)
import XCTest
import Darwin
import Synchronization
@testable import IntentsAutomationCore

final class AutomationMacExecutableInventoryTests: XCTestCase {
    private typealias Inventory = AutomationMacProcessInventory
    private let paths: Set<String> = ["/bin/owned-helper"]

    func testUnrelatedIdentityFailuresZombieAndProcessChurnDoNotBlock() throws {
        let scans = Mutex(0)
        let reader = Inventory.Reader(processIDs: { _ in
            scans.withLock { $0 += 1; return $0 == 1 ? [41, 42] : [42, 43] }
        }, identity: { _, _ in XCTFail("Unrelated identities must not be inspected"); throw Failure.unrelated }, executablePath: { pid in
            if pid == 42 { throw Inventory.KernelObservationFailure(stage: .executablePath, pid: pid, errorNumber: ESRCH) }
            return "/bin/unrelated"
        })
        let result = try Inventory.collectExecutables(userID: 501, paths: paths, reader: reader, inactive: { $0 == 42 })
        XCTAssertTrue(result.processes.isEmpty)
        XCTAssertEqual(result.executableScope, paths.sorted())
        try result.validate(expectedUserID: 501, matchingExecutablePaths: paths)
        // Scoped observations must never stand in for a full UID/descendant census.
        XCTAssertThrowsError(try result.validate(expectedUserID: 501))
        XCTAssertThrowsError(try result.validate(expectedUserID: 501, matchingExecutablePaths: ["/bin/other-helper"]))
        XCTAssertEqual(try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(result)), result)
    }

    func testExactHelperRetainsIdentityAndBlocksReleaseVerifier() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try AutomationPath.canonical(folder).appendingPathComponent("helper")
        let bytes = Data("owned helper fixture".utf8); try bytes.write(to: executable)
        let selected: Set<String> = [executable.path]
        let helper = AutomationMacHelperReleaseVerifier.Helper(executable: executable, sha256: AutomationArtifactRegistry.digest(bytes))
        let occupied = try Inventory.collectExecutables(userID: 501, paths: selected,
            reader: reader(path: { _ in executable.path }), inactive: { _ in false })
        XCTAssertEqual(occupied.processes.map(\.identity), [.init(pid: 42, startIdentity: "100:0")])
        var empty = Inventory(userID: 501, complete: true, processes: []); empty.executableScope = selected.sorted()
        let state = Frames([empty, occupied])
        let verifier = try AutomationMacHelperReleaseVerifier(helpers: [helper], loginSession: "fixture", userID: 501,
            inspector: { try await state.next() }, drain: { true })
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "fixture")
        try await verifier.prepare(target: target, controllerBundleIDs: [])
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(released)
    }

    func testUnreadableLivePathAndOwnedIdentityStillFailClosed() throws {
        let unreadable = reader(path: { pid in throw Inventory.KernelObservationFailure(stage: .executablePath, pid: pid, errorNumber: EACCES) })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: unreadable, inactive: { _ in false }))
        var owned = reader()
        owned.identity = { _, _ in throw Failure.owned }
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: owned,
            inactive: { _ in XCTFail("Owned identity errors cannot be discarded"); return true }))
    }

    func testOwnedPIDReuseExecChangeAndArrivalBetweenScansFail() throws {
        let calls = Mutex(0)
        var reused = reader()
        reused.identity = { pid, _ in
            let count = calls.withLock { $0 += 1; return $0 }
            return .init(pid: pid, startIdentity: count == 1 ? "100:0" : "101:0")
        }
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: reused, inactive: { _ in false }))
        let pathCalls = Mutex(0)
        let execChanged = reader(path: { _ in pathCalls.withLock { $0 += 1; return $0 == 1 ? "/bin/owned-helper" : "/bin/unrelated" } })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: execChanged, inactive: { _ in false }))
        let arrivals = Mutex(0)
        let arriving = reader(path: { _ in arrivals.withLock { $0 += 1; return $0 == 1 ? "/bin/unrelated" : "/bin/owned-helper" } })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: arriving, inactive: { _ in false }))
    }

    func testBadScopeIncompletePIDListAndInactiveProbeFailureAreRejected() throws {
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: [], reader: reader(), inactive: { _ in true }))
        var empty = reader(); empty.processIDs = { _ in [] }
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: empty, inactive: { _ in true }))
        let unknown = reader(path: { _ in throw Failure.unrelated })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: unknown, inactive: { _ in throw Failure.owned }))
    }

    func testActualExitedChildIsRecognizedWithoutReapingAnUnrelatedProcess() throws {
        var pid: pid_t = 0
        let argument = strdup("true"); defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let spawned = posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, &environment)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        defer { var status: Int32 = 0; while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
        var status = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(pid), &status, WEXITED | WNOWAIT), 0)
        XCTAssertTrue(try Inventory.inactiveProcess(pid: pid, userID: getuid()))
        XCTAssertFalse(try Inventory.inactiveProcess(pid: getpid(), userID: getuid()))
        XCTAssertThrowsError(try Inventory.inactiveProcess(pid: pid, userID: getuid() + 1))
        // The observer did not reap even this test-owned child; its parent still can.
        XCTAssertEqual(kill(pid, 0), 0)
    }

    private func reader(path: @escaping @Sendable (Int32) throws -> String = { _ in "/bin/owned-helper" }) -> Inventory.Reader {
        .init(processIDs: { _ in [42] }, identity: { pid, _ in .init(pid: pid, startIdentity: "100:0") }, executablePath: path)
    }
    private enum Failure: Error { case unrelated, owned }
    private actor Frames {
        var frames: [Inventory]
        init(_ frames: [Inventory]) { self.frames = frames }
        func next() throws -> Inventory { guard !frames.isEmpty else { throw Failure.owned }; return frames.removeFirst() }
    }
}
#endif
