#if os(macOS)
import XCTest
import Synchronization
import Darwin
@testable import IntentsAutomationCore

final class AutomationMacProcessInventoryTests: XCTestCase {
    private let old = AutomationProcessIdentity(pid: 42, startIdentity: "100:0")
    private func collect(_ sequence: KernelSequence) throws -> AutomationMacProcessInventory {
        try .collect(userID: 501, observerPID: 42, reader: sequence.reader)
    }
    func testMatchingFullObservationsRetainIdentityAndPath() throws {
        let result = try collect(.init(identities: Array(repeating: old, count: 6), paths: Array(repeating: "/bin/fixture", count: 4)))
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.processes, [.init(identity: old, userID: 501, executablePath: "/bin/fixture")])
    }
    func testPIDReuseWithUnchangedPIDSetIsRejected() {
        let replacement = AutomationProcessIdentity(pid: 42, startIdentity: "101:0")
        XCTAssertThrowsError(try collect(.init(identities: Array(repeating: old, count: 3) + Array(repeating: replacement, count: 3),
            paths: Array(repeating: "/bin/fixture", count: 4))))
    }
    func testExecutableChangeDuringPathCaptureIsRejected() {
        XCTAssertThrowsError(try collect(.init(identities: Array(repeating: old, count: 6),
            paths: ["/bin/fixture", "/bin/helper"])))
    }
    func testExecutableChangeBetweenFullScansIsRejected() {
        XCTAssertThrowsError(try collect(.init(identities: Array(repeating: old, count: 6),
            paths: ["/bin/fixture", "/bin/fixture", "/bin/helper", "/bin/helper"])))
    }
    func testMissingMetadataAndObservedPIDChurnAreRejected() {
        XCTAssertThrowsError(try collect(.init(identities: [old], paths: ["/bin/fixture"])))
        XCTAssertThrowsError(try collect(.init(identities: Array(repeating: old, count: 6),
            paths: Array(repeating: "/bin/fixture", count: 4), sets: [[42], [42, 43]])))
    }
    func testObserverAndReturnedPIDMustMatch() {
        XCTAssertThrowsError(try collect(.init(identities: [], paths: [], sets: [[43]])))
        XCTAssertThrowsError(try collect(.init(identities: [.init(pid: 43, startIdentity: "100:0")], paths: ["/bin/fixture"])))
    }
    func testNativeReadOnlyInventoryWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MAC_READ_ONLY_INVENTORY"] == "1" else {
            throw XCTSkip("Actual current-UID kernel observation is opt-in")
        }
        let inventory = try AutomationMacProcessInventory.currentUser()
        try inventory.validate(expectedUserID: getuid())
        XCTAssertTrue(inventory.processes.contains { $0.identity.pid == getpid() })
        // Retain only aggregate diagnostic facts in test output, never other app paths.
        print("Read-only Mac inventory: \(inventory.processes.count) records; two matching observations; non-atomic; no GUI or cleanup qualification")
    }
}

private final class KernelSequence: Sendable {
    private struct State: Sendable {
        var identities: [AutomationProcessIdentity]
        var paths: [String]
        var sets: [Set<Int32>]
    }
    private let state: Mutex<State>
    init(identities: [AutomationProcessIdentity], paths: [String], sets: [Set<Int32>] = [[42], [42], [42]]) {
        state = Mutex(.init(identities: identities, paths: paths, sets: sets))
    }
    var reader: AutomationMacProcessInventory.Reader {
        .init(processIDs: { [self] _ in try state.withLock { value in
            guard !value.sets.isEmpty else { throw AutomationContractError.terminationUnverified }
            return value.sets.removeFirst()
        } }, identity: { [self] _, _ in try state.withLock { value in
            guard !value.identities.isEmpty else { throw AutomationContractError.terminationUnverified }
            return value.identities.removeFirst()
        } }, executablePath: { [self] _ in try state.withLock { value in
            guard !value.paths.isEmpty else { throw AutomationContractError.terminationUnverified }
            return value.paths.removeFirst()
        } })
    }
}
#endif
