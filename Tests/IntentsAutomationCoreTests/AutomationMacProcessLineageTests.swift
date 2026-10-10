#if os(macOS)
import XCTest
import Synchronization
@testable import IntentsAutomationCore

final class AutomationMacProcessLineageTests: XCTestCase {
    private let root = AutomationProcessIdentity(pid: 42, startIdentity: "100:0")
    private func record(_ pid: Int32, _ seconds: Int, parent: Int32 = 1, status: UInt32 = 2, path: String = "/bin/fixture") -> AutomationMacProcessInventory.Record {
        .init(identity: .init(pid: pid, startIdentity: "\(seconds):0"), userID: 501, executablePath: path, parentPID: parent, status: status)
    }
    private func inventory(_ records: [AutomationMacProcessInventory.Record]) -> AutomationMacProcessInventory {
        .init(userID: 501, complete: true, processes: records)
    }
    private func ledger() throws -> AutomationMacProcessLineage {
        try .init(root: root, userID: 501, rootExecutablePath: "/bin/fixture")
    }
    func testExactRootTracksTransitiveChildrenButExcludesUnrelatedProcesses() throws {
        var value = try ledger()
        let observed = try value.observe(inventory([record(42, 100), record(43, 101, parent: 42), record(44, 102, parent: 43), record(50, 103)]))
        XCTAssertTrue(observed.rootPresent)
        XCTAssertEqual(observed.matchingObservedDescendants.map(\.pid), [43, 44])
        XCTAssertTrue(observed.absentOrReplacedObservedDescendants.isEmpty)
    }
    func testReparentedObservedChildAndItsNewDescendantsRemainTrackedAfterRootExit() throws {
        var value = try ledger()
        _ = try value.observe(inventory([record(42, 100), record(43, 101, parent: 42)]))
        let retained = try value.observe(inventory([record(43, 101), record(44, 102, parent: 43), record(50, 103)]))
        XCTAssertFalse(retained.rootPresent)
        XCTAssertEqual(retained.matchingObservedDescendants.map(\.pid), [43, 44])
        let final = try value.observe(inventory([record(50, 103)]))
        XCTAssertTrue(final.matchingObservedDescendants.isEmpty)
        XCTAssertEqual(final.absentOrReplacedObservedDescendants.map(\.pid), [43, 44])
    }
    func testReplacementRootAndChildPIDsDoNotLendLineage() throws {
        var value = try ledger()
        _ = try value.observe(inventory([record(42, 100), record(43, 101, parent: 42)]))
        let replacement = try value.observe(inventory([record(42, 200, path: "/bin/foreign"), record(43, 201), record(44, 202, parent: 43)]))
        XCTAssertFalse(replacement.rootPresent)
        XCTAssertTrue(replacement.matchingObservedDescendants.isEmpty)
        XCTAssertEqual(replacement.absentOrReplacedObservedDescendants, [.init(pid: 43, startIdentity: "101:0")])
    }
    func testSamePIDCanRepresentSeparatelyObservedDescendants() throws {
        var value = try ledger()
        _ = try value.observe(inventory([record(42, 100), record(43, 101, parent: 42)]))
        let replacement = try value.observe(inventory([record(42, 100), record(43, 201, parent: 42)]))
        XCTAssertEqual(replacement.matchingObservedDescendants, [.init(pid: 43, startIdentity: "201:0")])
        XCTAssertEqual(replacement.absentOrReplacedObservedDescendants, [.init(pid: 43, startIdentity: "101:0")])
    }
    func testZombieIsStillMatchingObservedDescendant() throws {
        var value = try ledger()
        let zombie = try value.observe(inventory([record(42, 100), record(43, 101, parent: 42, status: 5)]))
        XCTAssertEqual(zombie.matchingObservedDescendants.map(\.pid), [43])
        XCTAssertTrue(zombie.absentOrReplacedObservedDescendants.isEmpty)
    }
    func testLegacyInventoryCannotMeanNoChildrenAndRemainsDecodable() throws {
        let legacy = Data(#"{"userID":501,"complete":true,"processes":[{"identity":{"pid":42,"startIdentity":"100:0"},"userID":501,"executablePath":"/bin/fixture"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(AutomationMacProcessInventory.self, from: legacy)
        try decoded.validate(expectedUserID: 501)
        var value = try ledger()
        XCTAssertThrowsError(try value.observe(decoded))
        XCTAssertEqual(try value.observe(inventory([record(42, 100)])).sequence, 1)
    }
    func testWrongRootIdentityPathUIDAndIncompleteInventoryFailBeforeRetention() throws {
        var value = try ledger()
        for records in [[record(42, 101)], [record(50, 100)], [record(42, 100, path: "/bin/foreign")]] {
            XCTAssertThrowsError(try value.observe(inventory(records)))
        }
        var sample = inventory([record(42, 100)]); sample.userID = 502
        XCTAssertThrowsError(try value.observe(sample))
        sample = inventory([record(42, 100)]); sample.complete = false
        XCTAssertThrowsError(try value.observe(sample))
        _ = try value.observe(inventory([record(42, 100)]))
        XCTAssertThrowsError(try value.observe(inventory([record(42, 100, path: "/bin/changed")])))
    }
    func testMalformedParentsStatesAndCyclesAreRejectedWithoutPartialRetention() throws {
        var value = try ledger()
        for extra in [record(43, 101, parent: -1), record(43, 101, parent: 43), record(43, 101, status: 0), record(43, 101, status: 6), record(43, 99, parent: 42)] {
            XCTAssertThrowsError(try value.observe(inventory([record(42, 100), extra])))
        }
        XCTAssertThrowsError(try value.observe(inventory([record(42, 100), record(43, 101, parent: 44), record(44, 101, parent: 43)])))
        XCTAssertEqual(try value.observe(inventory([record(42, 100)])).sequence, 1)
    }
    func testObservationAndDescendantBounds() throws {
        var value = try ledger()
        let sample = inventory([record(42, 100)])
        for number in 1...256 { XCTAssertEqual(try value.observe(sample).sequence, number) }
        XCTAssertThrowsError(try value.observe(sample))
        value = try ledger()
        let tooMany = [record(42, 100)] + (1000...2024).map { record(Int32($0), $0, parent: 42) }
        XCTAssertThrowsError(try value.observe(inventory(tooMany)))
        XCTAssertEqual(try value.observe(sample).sequence, 1)
    }
    func testStableInventoryBindsParentAndStateAcrossBothScans() throws {
        let facts = AutomationMacProcessInventory.ProcessFacts(pid: 42, parentPID: 1, userID: 501, status: 2, startIdentity: "100:0")
        let stable = try collect(Array(repeating: facts, count: 4))
        XCTAssertEqual(stable.processes[0].parentPID, 1)
        XCTAssertEqual(stable.processes[0].status, 2)
        var sleeping = facts; sleeping.status = 3
        XCTAssertNoThrow(try collect([facts, sleeping, sleeping, facts]))
        for changed in [AutomationMacProcessInventory.ProcessFacts(pid: 42, parentPID: 2, userID: 501, status: 2, startIdentity: "100:0"),
                        .init(pid: 42, parentPID: 1, userID: 501, status: 6, startIdentity: "100:0"),
                        .init(pid: 42, parentPID: 1, userID: 501, status: 2, startIdentity: "101:0"),
                        .init(pid: 42, parentPID: 1, userID: 502, status: 2, startIdentity: "100:0")] {
            XCTAssertThrowsError(try collect([facts, changed, facts, facts]))
            XCTAssertThrowsError(try collect([facts, facts, changed, changed]))
        }
    }
    private func collect(_ facts: [AutomationMacProcessInventory.ProcessFacts]) throws -> AutomationMacProcessInventory {
        let sequence = Mutex(facts)
        let identity = root
        let reader = AutomationMacProcessInventory.Reader(processIDs: { _ in [42] }, identity: { _, _ in identity }, executablePath: { _ in "/bin/fixture" }, facts: { _, _ in
            try sequence.withLock { values in
                guard !values.isEmpty else { throw AutomationContractError.terminationUnverified }
                return values.removeFirst()
            }
        })
        return try .collect(userID: 501, observerPID: 42, reader: reader)
    }
}
#endif
