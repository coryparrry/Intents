#if os(macOS)
import XCTest
import Synchronization
import Darwin
@testable import IntentsAutomationCore

final class AutomationMacInventoryReconciliationTests: XCTestCase {
    private let observer = AutomationProcessIdentity(pid: 42, startIdentity: "100:0")
    private func identity(_ pid: Int32, _ start: String = "100:0") -> AutomationProcessIdentity { .init(pid: pid, startIdentity: start) }
    private func failure(_ pid: Int32, _ code: Int32 = ESRCH) -> Result<AutomationProcessIdentity, any Error> {
        .failure(AutomationMacProcessInventory.KernelObservationFailure(stage: .metadata, pid: pid, errorNumber: code))
    }
    private func reconcile(_ kernel: ReconciliationKernel, absent: Bool = true) throws -> AutomationMacProcessInventory {
        try .collectReconciled(userID: 501, observerPID: 42, helperExecutablePaths: ["/bin/helper"], reader: kernel.reader,
            confirmAbsent: { kernel.confirmAbsent($0, result: absent) })
    }
    private func exitKernel(_ code: Int32 = ESRCH) -> ReconciliationKernel {
        .init(sets: [[42, 43], [42], [42], [42]],
            identities: Array(repeating: .success(observer), count: 3) + [failure(43, code)] + Array(repeating: .success(observer), count: 6),
            paths: Array(repeating: "/bin/observer", count: 6))
    }
    func testZombieParentFactsCannotReplaceIndependentKernelAbsence() throws {
        let facts = AutomationMacProcessInventory.ProcessFacts(pid: 55592, parentPID: 55434, userID: 501, status: 5, startIdentity: "100:0")
        let failure = AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: 55592, errorNumber: ESRCH, process: facts)
        let reader = AutomationMacProcessInventory.Reader(processIDs: { _ in [42, 55592] },
            identity: { pid, _ in .init(pid: pid, startIdentity: "100:0") }, executablePath: { pid in
                if pid == 55592 { throw failure }; return "/bin/observer"
            })
        XCTAssertTrue(facts.awaitingParentCollection)
        XCTAssertThrowsError(try AutomationMacProcessInventory.collectReconciled(userID: 501, observerPID: 42,
            helperExecutablePaths: ["/bin/helper"], reader: reader, confirmAbsent: { _ in false })) { error in
            let retained = error as? AutomationMacProcessInventory.KernelObservationFailure
            XCTAssertEqual(retained?.stage, .absenceUnconfirmed); XCTAssertEqual(retained?.process, facts)
        }
    }
    func testConfirmedUnrelatedExitRequiresCompleteReplacementObservation() throws {
        let kernel = exitKernel(), inventory = try reconcile(kernel)
        XCTAssertEqual(inventory.reconciliation?.attempts, 2)
        XCTAssertEqual(inventory.reconciliation?.confirmedDisappearedPIDs, [43])
        XCTAssertEqual(inventory.processes.map(\.identity), [observer])
        XCTAssertEqual(kernel.counts().lists, 4); XCTAssertEqual(kernel.counts().confirmed, [43])
        try inventory.validate(expectedUserID: 501)
    }
    func testPermissionFailureAndUnconfirmedDisappearanceDoNotRescan() {
        let permission = exitKernel(EACCES)
        XCTAssertThrowsError(try reconcile(permission))
        XCTAssertEqual(permission.counts().lists, 1); XCTAssertTrue(permission.counts().confirmed.isEmpty)
        let uncertain = exitKernel()
        XCTAssertThrowsError(try reconcile(uncertain, absent: false)) {
            XCTAssertEqual(($0 as? AutomationMacProcessInventory.KernelObservationFailure)?.stage, .absenceUnconfirmed)
        }
        XCTAssertEqual(uncertain.counts().lists, 1)
    }
    func testObservedHelperExitBeforeCompletedRecordCannotBeReconciled() {
        let kernel = ReconciliationKernel(sets: [[42, 43]],
            identities: Array(repeating: .success(observer), count: 3) + [.success(identity(43)), failure(43)],
            paths: ["/bin/observer", "/bin/observer", "/bin/helper"])
        XCTAssertThrowsError(try reconcile(kernel))
        XCTAssertEqual(kernel.counts().lists, 1); XCTAssertTrue(kernel.counts().confirmed.isEmpty)
    }
    func testObservedHelperPlusUnrelatedExitStillRefusesReconciliation() {
        let kernel = ReconciliationKernel(sets: [[42, 43, 44]],
            identities: Array(repeating: .success(observer), count: 3) + Array(repeating: .success(identity(43)), count: 3) + [failure(44)],
            paths: ["/bin/observer", "/bin/observer", "/bin/helper", "/bin/helper"])
        XCTAssertThrowsError(try reconcile(kernel))
        XCTAssertEqual(kernel.counts().lists, 1); XCTAssertTrue(kernel.counts().confirmed.isEmpty)
    }
    func testDisappearedPIDReappearingWithNewIdentityIsNotAccepted() {
        let scan = Array(repeating: Result<AutomationProcessIdentity, any Error>.success(observer), count: 3) +
            Array(repeating: .success(identity(43, "101:0")), count: 3)
        let kernel = ReconciliationKernel(sets: Array(repeating: [42, 43], count: 4),
            identities: Array(repeating: .success(observer), count: 3) + [failure(43)] + scan + scan,
            paths: Array(repeating: "/bin/observer", count: 10))
        XCTAssertThrowsError(try reconcile(kernel))
        XCTAssertEqual(kernel.counts().lists, 2); XCTAssertEqual(kernel.counts().confirmed, [43])
    }
    func testReappearingPIDDuringFailedReplacementCannotDisappearFromHistory() {
        let kernel = ReconciliationKernel(sets: [[42, 43], [42, 43, 44], [42], [42], [42]],
            identities: Array(repeating: .success(observer), count: 3) + [failure(43)] +
                Array(repeating: .success(observer), count: 3) + Array(repeating: .success(identity(43, "101:0")), count: 3) + [failure(44)] +
                Array(repeating: .success(observer), count: 6), paths: Array(repeating: "/bin/observer", count: 10))
        XCTAssertThrowsError(try reconcile(kernel))
        XCTAssertEqual(kernel.counts().lists, 2); XCTAssertEqual(kernel.counts().confirmed, [43])
    }
    func testExecutablePathExitRequiresReplacementAndPermissionFailureDoesNotRetry() throws {
        for code in [ESRCH, EACCES] {
            let kernel = ReconciliationKernel(sets: [[42, 43], [42], [42], [42]],
                identities: Array(repeating: .success(observer), count: 3) + [.success(identity(43))] + Array(repeating: .success(observer), count: 6),
                paths: Array(repeating: "/bin/observer", count: 6),
                pathFailure: (after: 2, error: AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: 43, errorNumber: code)))
            if code == ESRCH {
                let result = try reconcile(kernel)
                XCTAssertEqual(result.reconciliation?.attempts, 2); XCTAssertEqual(kernel.counts().lists, 4)
            } else {
                XCTAssertThrowsError(try reconcile(kernel)); XCTAssertEqual(kernel.counts().lists, 1)
                XCTAssertTrue(kernel.counts().confirmed.isEmpty)
            }
        }
    }
    func testCancellationDuringAbsenceConfirmationPreventsReplacementScan() async {
        let kernel = exitKernel()
        let task = Task.detached { () -> Bool in
            do {
                _ = try AutomationMacProcessInventory.collectReconciled(userID: 501, observerPID: 42,
                    helperExecutablePaths: ["/bin/helper"], reader: kernel.reader, confirmAbsent: { pid in
                        withUnsafeCurrentTask { $0?.cancel() }
                        return kernel.confirmAbsent(pid, result: true)
                    })
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled); XCTAssertEqual(kernel.counts().lists, 1); XCTAssertEqual(kernel.counts().confirmed, [43])
    }
    func testNewPIDMustBeFullyObservedAndHelperPresenceRetained() throws {
        let scan = Array(repeating: Result<AutomationProcessIdentity, any Error>.success(observer), count: 3) +
            Array(repeating: .success(identity(43)), count: 3)
        let kernel = ReconciliationKernel(sets: [[42], [42, 43], [42, 43], [42, 43], [42, 43]],
            identities: Array(repeating: .success(observer), count: 3) + scan + scan,
            paths: ["/bin/observer", "/bin/observer"] + Array(repeating: ["/bin/observer", "/bin/observer", "/bin/helper", "/bin/helper"], count: 2).flatMap { $0 })
        let inventory = try reconcile(kernel)
        XCTAssertEqual(inventory.reconciliation?.attempts, 2)
        XCTAssertEqual(inventory.processes.last?.executablePath, "/bin/helper")
        XCTAssertEqual(inventory.processes.count, 2); XCTAssertTrue(kernel.counts().confirmed.isEmpty)
    }
    func testPersistentChurnStopsAfterThreeAttempts() {
        var identities: [Result<AutomationProcessIdentity, any Error>] = []
        for pid: Int32 in [43, 44, 45] { identities += Array(repeating: .success(observer), count: 3) + [failure(pid)] }
        let kernel = ReconciliationKernel(sets: [[42, 43], [42, 44], [42, 45]], identities: identities,
            paths: Array(repeating: "/bin/observer", count: 6))
        XCTAssertThrowsError(try reconcile(kernel))
        XCTAssertEqual(kernel.counts().lists, 3); XCTAssertEqual(kernel.counts().confirmed, [43, 44])
    }
    func testCancellationCannotInspectOrReconcile() async {
        let kernel = exitKernel()
        let task = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try AutomationMacProcessInventory.collectReconciled(userID: 501, observerPID: 42,
                helperExecutablePaths: ["/bin/helper"], reader: kernel.reader, confirmAbsent: { kernel.confirmAbsent($0, result: true) }); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled); XCTAssertEqual(kernel.counts().lists, 0)
    }
}

private final class ReconciliationKernel: Sendable {
    private struct State: Sendable {
        var sets: [Set<Int32>]
        var identities: [Result<AutomationProcessIdentity, any Error>]
        var paths: [String]
        var pathFailure: (after: Int, error: any Error)?
        var pathReads = 0
        var lists = 0
        var confirmed: [Int32] = []
    }
    private let state: Mutex<State>
    init(sets: [Set<Int32>], identities: [Result<AutomationProcessIdentity, any Error>], paths: [String],
         pathFailure: (after: Int, error: any Error)? = nil) {
        state = Mutex(.init(sets: sets, identities: identities, paths: paths, pathFailure: pathFailure))
    }
    func counts() -> (lists: Int, confirmed: [Int32]) { state.withLock { ($0.lists, $0.confirmed) } }
    func confirmAbsent(_ pid: Int32, result: Bool) -> Bool { state.withLock { $0.confirmed.append(pid) }; return result }
    var reader: AutomationMacProcessInventory.Reader {
        .init(processIDs: { [self] _ in try state.withLock { value in
            value.lists += 1
            guard !value.sets.isEmpty else { throw AutomationContractError.terminationUnverified }
            return value.sets.removeFirst()
        } }, identity: { [self] _, _ in try state.withLock { value in
            guard !value.identities.isEmpty else { throw AutomationContractError.terminationUnverified }
            return try value.identities.removeFirst().get()
        } }, executablePath: { [self] _ in try state.withLock { value in
            let read = value.pathReads; value.pathReads += 1
            if let failure = value.pathFailure, read == failure.after { throw failure.error }
            guard !value.paths.isEmpty else { throw AutomationContractError.terminationUnverified }
            return value.paths.removeFirst()
        } })
    }
}
#endif
