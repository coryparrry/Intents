#if os(macOS)
import XCTest
import Darwin
import Synchronization
@testable import IntentsAutomationCore

final class AutomationMacConcurrentInventoryTests: XCTestCase {
    private typealias Inventory = AutomationMacProcessInventory

    func testParallelInventoryRetainsEveryRecordAndBothFullObservations() throws {
        let kernel = ConcurrentInventoryKernel()
        let inventory = try Inventory.collect(userID: 501, observerPID: 42, reader: kernel.reader)
        try inventory.validate(expectedUserID: 501)
        XCTAssertEqual(inventory.processes.map(\.identity.pid), Array(42...49))
        let counts = kernel.counts
        XCTAssertEqual(counts.lists, 3)
        XCTAssertEqual(counts.peak, 4)
        for pid: Int32 in 42...49 {
            XCTAssertEqual(counts.identities[pid], 6)
            XCTAssertEqual(counts.paths[pid], 4)
            XCTAssertEqual(counts.facts[pid], 4)
        }
    }

    func testHelperInSameBatchAsExitPreventsReconciliation() {
        let confirmations = Mutex(0)
        let reader = stableReader(identity: { pid, _ in
            if pid == 42 { throw Inventory.KernelObservationFailure(stage: .metadata, pid: pid, errorNumber: ESRCH) }
            return .init(pid: pid, startIdentity: "100:0")
        }, path: { $0 == 43 ? "/bin/helper" : "/bin/other" })
        XCTAssertThrowsError(try Inventory.collectReconciled(userID: 501, observerPID: 44,
            helperExecutablePaths: ["/bin/helper"], reader: reader,
            confirmAbsent: { _ in confirmations.withLock { $0 += 1 }; return true }))
        XCTAssertEqual(confirmations.withLock { $0 }, 0)
    }

    func testMultipleFailuresCannotHidePermissionFailureBehindRetryableExit() {
        let confirmations = Mutex(0)
        let reader = stableReader(identity: { pid, _ in
            if pid == 42 || pid == 43 {
                throw Inventory.KernelObservationFailure(stage: .metadata, pid: pid, errorNumber: pid == 42 ? ESRCH : EACCES)
            }
            return .init(pid: pid, startIdentity: "100:0")
        })
        XCTAssertThrowsError(try Inventory.collectReconciled(userID: 501, observerPID: 44,
            helperExecutablePaths: [], reader: reader,
            confirmAbsent: { _ in confirmations.withLock { $0 += 1 }; return true }))
        XCTAssertEqual(confirmations.withLock { $0 }, 0)
    }

    func testSingleConfirmedExitStillRequiresTwoFullReplacementScans() throws {
        let lists = Mutex(0), confirmations = Mutex<[Int32]>([])
        var reader = stableReader(identity: { pid, _ in
            if pid == 42 { throw Inventory.KernelObservationFailure(stage: .metadata, pid: pid, errorNumber: ESRCH) }
            return .init(pid: pid, startIdentity: "100:0")
        })
        reader.processIDs = { _ in
            let count = lists.withLock { $0 += 1; return $0 }
            return count == 1 ? [42, 43, 44, 45] : [43, 44, 45]
        }
        let inventory = try Inventory.collectReconciled(userID: 501, observerPID: 44,
            helperExecutablePaths: [], reader: reader,
            confirmAbsent: { pid in confirmations.withLock { $0.append(pid) }; return true })
        XCTAssertEqual(inventory.processes.map(\.identity.pid), [43, 44, 45])
        XCTAssertEqual(inventory.reconciliation?.attempts, 2)
        XCTAssertEqual(inventory.reconciliation?.confirmedDisappearedPIDs, [42])
        XCTAssertEqual(confirmations.withLock { $0 }, [42])
        XCTAssertEqual(lists.withLock { $0 }, 4)
    }

    func testParallelReadsStillRejectExecIdentityAndParentChanges() {
        for mutation in 0...2 {
            let reads = Mutex<[Int32: Int]>([:])
            var reader = stableReader()
            if mutation == 0 {
                reader.executablePath = { pid in
                    let count = reads.withLock { values in values[pid, default: 0] += 1; return values[pid]! }
                    return pid == 43 && count == 2 ? "/bin/replaced" : "/bin/fixture"
                }
            } else if mutation == 1 {
                reader.identity = { pid, _ in
                    let count = reads.withLock { values in values[pid, default: 0] += 1; return values[pid]! }
                    return .init(pid: pid, startIdentity: pid == 43 && count == 2 ? "101:0" : "100:0")
                }
            } else {
                reader.facts = { pid, _ in
                    let count = reads.withLock { values in values[pid, default: 0] += 1; return values[pid]! }
                    return .init(pid: pid, parentPID: pid == 43 && count == 2 ? 2 : 1,
                        userID: 501, status: 2, startIdentity: "100:0")
                }
            }
            XCTAssertThrowsError(try Inventory.collect(userID: 501, observerPID: 42, reader: reader))
        }
    }

    func testParallelReadsRejectPIDSetChangeAndUnboundedWidth() {
        let calls = Mutex(0)
        var changed = stableReader()
        changed.processIDs = { _ in
            let count = calls.withLock { $0 += 1; return $0 }
            return count == 1 ? [42, 43, 44, 45] : [42, 43, 44, 45, 46]
        }
        XCTAssertThrowsError(try Inventory.collect(userID: 501, observerPID: 42, reader: changed))
        for width in [0, 5, Int.max] {
            var reader = stableReader(); reader.maximumConcurrentReads = width
            XCTAssertThrowsError(try Inventory.collect(userID: 501, observerPID: 42, reader: reader))
        }
    }

    func testCancellationDuringBatchDrainsReadersAndCannotReturnInventory() async {
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let completed = Mutex(0)
        let reader = stableReader(identity: { pid, _ in
            if pid == 42 {
                started.signal()
                guard finish.wait(timeout: .now() + 5) == .success else { throw AutomationContractError.terminationUnverified }
            }
            completed.withLock { $0 += 1 }
            return .init(pid: pid, startIdentity: "100:0")
        })
        let task = Task.detached {
            do { _ = try Inventory.collect(userID: 501, observerPID: 42, reader: reader); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        // All three identity reads for this PID may proceed, then the batch
        // must drain and observe cancellation before starting another batch.
        for _ in 0..<3 { finish.signal() }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(completed.withLock { $0 }, 12)
    }

    private func stableReader(
        identity: @escaping @Sendable (Int32, UInt32) throws -> AutomationProcessIdentity = { pid, _ in .init(pid: pid, startIdentity: "100:0") },
        path: @escaping @Sendable (Int32) throws -> String = { _ in "/bin/fixture" }
    ) -> Inventory.Reader {
        .init(processIDs: { _ in [42, 43, 44, 45] }, identity: identity, executablePath: path,
            facts: { pid, _ in .init(pid: pid, parentPID: 1, userID: 501, status: 2, startIdentity: "100:0") },
            maximumConcurrentReads: 4)
    }
}

private final class ConcurrentInventoryKernel: Sendable {
    struct Counts: Sendable {
        var identities: [Int32: Int] = [:], paths: [Int32: Int] = [:], facts: [Int32: Int] = [:]
        var lists = 0, active = 0, peak = 0
    }
    private let state = Mutex(Counts())
    private let firstWave = DispatchGroup()
    init() { for _ in 0..<4 { firstWave.enter() } }
    var counts: Counts { state.withLock { $0 } }
    var reader: AutomationMacProcessInventory.Reader {
        .init(processIDs: { [self] _ in state.withLock { $0.lists += 1 }; return Set(42...49) },
            identity: { [self] pid, _ in
                let first = state.withLock { value in
                    value.identities[pid, default: 0] += 1
                    value.active += 1; value.peak = max(value.peak, value.active)
                    return value.identities[pid] == 1
                }
                defer { state.withLock { $0.active -= 1 } }
                if first && pid < 46 {
                    firstWave.leave()
                    guard firstWave.wait(timeout: .now() + 5) == .success else { throw AutomationContractError.terminationUnverified }
                }
                return .init(pid: pid, startIdentity: "100:0")
            }, executablePath: { [self] pid in
                state.withLock { $0.paths[pid, default: 0] += 1 }; return "/bin/fixture"
            }, facts: { [self] pid, _ in
                state.withLock { $0.facts[pid, default: 0] += 1 }
                return .init(pid: pid, parentPID: 1, userID: 501, status: 2, startIdentity: "100:0")
            }, maximumConcurrentReads: 4)
    }
}
#endif
