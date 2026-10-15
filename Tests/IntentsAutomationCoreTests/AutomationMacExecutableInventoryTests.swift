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

    func testExactExecutableRetainsItsObservedIdentity() throws {
        let occupied = try Inventory.collectExecutables(userID: 501, paths: paths,
            reader: reader(), inactive: { _ in false })
        XCTAssertEqual(occupied.processes.map(\.identity), [.init(pid: 42, startIdentity: "100:0")])
        try occupied.validate(expectedUserID: 501, matchingExecutablePaths: paths)
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
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: reused, inactive: { _ in false })) {
            XCTAssertEqual($0 as? Inventory.KernelObservationFailure,
                Inventory.KernelObservationFailure(stage: .executableSetChanged, pid: 42, errorNumber: 0))
        }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        let pathCalls = Mutex(0)
        let execChanged = reader(path: { _ in pathCalls.withLock { $0 += 1; return $0 == 1 ? "/bin/owned-helper" : "/bin/unrelated" } })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: execChanged, inactive: { _ in false })) {
            XCTAssertEqual($0 as? Inventory.KernelObservationFailure,
                Inventory.KernelObservationFailure(stage: .executableSetChanged, pid: 42, errorNumber: 0))
        }
        XCTAssertEqual(pathCalls.withLock { $0 }, 2)
        let arrivals = Mutex(0)
        let arriving = reader(path: { _ in arrivals.withLock { $0 += 1; return $0 == 1 ? "/bin/unrelated" : "/bin/owned-helper" } })
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: arriving, inactive: { _ in false }))
    }

    func testMalformedInitialOrResampledPathAndWrongInitialPIDRemainContractFailures() throws {
        for malformedPath in ["relative/helper", "/bin/../owned-helper", "/bin/owned-helper\0", ""] {
            for malformedRead in [1, 2] {
                let reads = Mutex(0)
                let malformed = reader(path: { _ in
                    let call = reads.withLock { $0 += 1; return $0 }
                    return call == malformedRead ? malformedPath : "/bin/owned-helper"
                })
                XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: malformed,
                    inactive: { _ in XCTFail("Malformed paths cannot be discarded"); return true })) {
                    XCTAssertEqual($0 as? AutomationContractError, .terminationUnverified)
                    XCTAssertNil($0 as? Inventory.KernelObservationFailure)
                }
                XCTAssertEqual(reads.withLock { $0 }, malformedRead)
            }
        }
        let reads = Mutex(0)
        var wrongPID = reader(path: { _ in reads.withLock { $0 += 1 }; return "/bin/owned-helper" })
        wrongPID.identity = { pid, _ in .init(pid: pid + 1, startIdentity: "100:0") }
        XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: wrongPID,
            inactive: { _ in XCTFail("Mismatched PIDs cannot be discarded"); return true })) {
            XCTAssertEqual($0 as? AutomationContractError, .terminationUnverified)
            XCTAssertNil($0 as? Inventory.KernelObservationFailure)
        }
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }

    func testMalformedInitialAndResampledBirthIdentitiesCannotBecomeRetryableChanges() throws {
        for malformedBirth in ["", "0100:0", "100:1000000"] {
            for malformedRead in [1, 2] {
                let pathReads = Mutex(0), identityReads = Mutex(0)
                var malformed = reader(path: { _ in
                    let call = pathReads.withLock { $0 += 1; return $0 }
                    return malformedRead == 1 && call == 2 ? "/bin/unrelated" : "/bin/owned-helper"
                })
                malformed.identity = { pid, _ in
                    let call = identityReads.withLock { $0 += 1; return $0 }
                    return .init(pid: pid, startIdentity: call == malformedRead ? malformedBirth : "100:0")
                }
                XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: malformed,
                    inactive: { _ in XCTFail("Malformed birth identities cannot be discarded"); return true })) {
                    XCTAssertEqual($0 as? AutomationContractError, .terminationUnverified)
                    XCTAssertNil($0 as? Inventory.KernelObservationFailure)
                }
                XCTAssertEqual(identityReads.withLock { $0 }, malformedRead)
                XCTAssertEqual(pathReads.withLock { $0 }, malformedRead)
            }
        }
    }

    func testHelperExitAfterPathReadRetainsFailureAndNeverDropsItsRecord() throws {
        for exitAtRead in [1, 2] {
            let identities = Mutex(0), pathReads = Mutex(0)
            let failure = Inventory.KernelObservationFailure(stage: .metadata, pid: 42, errorNumber: ESRCH)
            var exiting = reader(path: { _ in
                pathReads.withLock { $0 += 1 }
                return "/bin/owned-helper"
            })
            exiting.identity = { pid, _ in
                let call = identities.withLock { $0 += 1; return $0 }
                if call == exitAtRead { throw failure }
                return .init(pid: pid, startIdentity: "100:0")
            }
            XCTAssertThrowsError(try Inventory.collectExecutables(userID: 501, paths: paths, reader: exiting,
                inactive: { _ in XCTFail("An observed helper must require a fresh full observation"); return true })) {
                XCTAssertEqual($0 as? Inventory.KernelObservationFailure, failure)
            }
            XCTAssertEqual(identities.withLock { $0 }, exitAtRead)
            XCTAssertEqual(pathReads.withLock { $0 }, exitAtRead)
        }
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
