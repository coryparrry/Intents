import XCTest
@testable import IntentsAutomationCore

final class AutomationAppleHostPayloadFileTests: XCTestCase {
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1)
    private func fixture(modern: Bool = false) throws -> (AutomationAppleHostPayloadFile, URL, Data) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("apple-host-payload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target: [String: Any] = ["BlueprintName": "OwnedHost", "EnvironmentVariables": ["INTENTS_AUTOMATION_HOST_PLAN_B64": "frozen-plan", "INTENTS_AUTOMATION_INPUT_PROBE_B64": "frozen-probe", "UNCHANGED": "value"]]
        let plist: [String: Any] = modern ? ["TestConfigurations": [["Name": "Debug", "TestTargets": [target]]], "__xctestrun_metadata__": ["FormatVersion": 2]] : ["OwnedHost": target, "__xctestrun_metadata__": ["FormatVersion": 1]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), url = root.appendingPathComponent("host.xctestrun")
        return (try .init(data: data, url: url, scope: scope), url, data)
    }
    func testDurablePendingPayloadFencesReleaseAndReloadedRecoveryUntilExactSanitation() async throws {
        for absent in [false, true] {
            let (file, url, data) = try fixture(), storeURL = url.deletingLastPathComponent().appendingPathComponent("leases.json")
            let target = TargetIdentity(id: "device", kind: .simulator), manager = try AutomationDeviceLeaseManager(storeURL: storeURL)
            let lease = try await manager.acquire(runID: "run", target: target, control: .system)
            try await manager.recordPrivatePayload(file, lease: lease)
            let prewrite = try await manager.currentRecord(lease); XCTAssertEqual(prewrite.privatePayload, file.recoveryReference)
            let serialized = try String(contentsOf: storeURL, encoding: .utf8)
            XCTAssertFalse(serialized.contains("frozen-plan")); XCTAssertFalse(serialized.contains("frozen-probe"))
            try file.write(data)
            do { try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Process proof cannot release a private payload") }
            catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
            // Simulate an exited owner without terminating a user process.
            let store = try AutomationLeaseStore(url: storeURL)
            try store.transaction { state in state.campaigns[target.leaseKey]?.owner.startIdentity = "exited-owner-fixture" }
            let reopened = try AutomationDeviceLeaseManager(storeURL: storeURL), records = try await reopened.recoveryRecords()
            let record = try XCTUnwrap(records.first); XCTAssertEqual(record.privatePayload, file.recoveryReference)
            do { try await reopened.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Recovery released unsanitized bytes") }
            catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
            XCTAssertEqual(try Data(contentsOf: url), data)
            var forged = record; forged.privatePayload = nil
            do { try await reopened.reconcile(forged, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Caller omitted durable pending payload") }
            catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
            if absent { try FileManager.default.removeItem(at: url) } else { try file.clean(scope: scope) }
            try await reopened.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
            let next = try await reopened.acquire(runID: "next", target: target, control: .system)
            XCTAssertEqual(next.generation, lease.generation + 1)
        }
    }
    func testOrphanPayloadStagingFencesDurableReleaseAndRecoveryWithoutFinalFile() async throws {
        let (file, url, data) = try fixture(), storeURL = url.deletingLastPathComponent().appendingPathComponent("leases.json")
        let target = TargetIdentity(id: "device", kind: .simulator), manager = try AutomationDeviceLeaseManager(storeURL: storeURL)
        let lease = try await manager.acquire(runID: "run", target: target, control: .system)
        try await manager.recordPrivatePayload(file, lease: lease)
        // A crash during write can retain a partial plaintext stage before rename.
        let orphan = file.recoveryReference.stagingURL, partial = Data(data.prefix(data.count / 2))
        try partial.write(to: orphan)
        do { try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Orphan stage released") } catch {}
        let store = try AutomationLeaseStore(url: storeURL)
        try store.transaction { $0.campaigns[target.leaseKey]?.owner.startIdentity = "exited-owner-fixture" }
        let reopened = try AutomationDeviceLeaseManager(storeURL: storeURL), records = try await reopened.recoveryRecords()
        let record = try XCTUnwrap(records.first)
        do { try await reopened.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true); XCTFail("Recovery overlooked orphan stage") } catch {}
        XCTAssertEqual(try Data(contentsOf: orphan), partial); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let retained = try await reopened.recoveryRecords(); XCTAssertEqual(retained, records)
    }
    func testRecoveryRefusesChangedLinkedAndMissingParentWithoutMutatingThem() async throws {
        let (file, url, data) = try fixture(); try file.write(data)
        let reference = file.recoveryReference, changed = Data("foreign".utf8)
        try changed.write(to: url)
        XCTAssertThrowsError(try reference.verifyClean()); XCTAssertEqual(try Data(contentsOf: url), changed)
        try FileManager.default.removeItem(at: url)
        let foreign = url.deletingLastPathComponent().appendingPathComponent("foreign")
        try changed.write(to: foreign); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign)
        XCTAssertThrowsError(try reference.verifyClean()); XCTAssertEqual(try Data(contentsOf: foreign), changed)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        XCTAssertThrowsError(try reference.verifyClean())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
    func testPrivateWriteAndExactPayloadCleanupPreserveOtherFieldsAndRawEvidence() throws {
        for modern in [false, true] {
            let (file, url, data) = try fixture(modern: modern)
            let raw = url.deletingLastPathComponent().appendingPathComponent("raw.xcresult")
            try Data("retained raw evidence".utf8).write(to: raw)
            try file.write(data)
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o600)
            try file.clean(scope: scope); try file.clean(scope: scope)
            let cleaned = try Data(contentsOf: url)
            let text = try XCTUnwrap(String(data: cleaned, encoding: .utf8))
            XCTAssertFalse(text.contains("frozen-plan")); XCTAssertFalse(text.contains("frozen-probe")); XCTAssertFalse(text.contains("INTENTS_AUTOMATION_"))
            XCTAssertTrue(text.contains("UNCHANGED")); XCTAssertTrue(text.contains("BlueprintName")); XCTAssertTrue(text.contains("__xctestrun_metadata__"))
            XCTAssertEqual(try Data(contentsOf: raw), Data("retained raw evidence".utf8))
        }
    }
    func testForeignScopeAndChangedDerivativeArePreserved() throws {
        let (file, url, data) = try fixture(); try file.write(data)
        var foreign = scope; foreign.leaseGeneration += 1
        XCTAssertThrowsError(try file.clean(scope: foreign)); XCTAssertEqual(try Data(contentsOf: url), data)
        let changed = Data("unexpected replacement".utf8); try changed.write(to: url)
        XCTAssertThrowsError(try file.clean(scope: scope)); XCTAssertEqual(try Data(contentsOf: url), changed)
    }
    func testMissingWriteCanCleanButExistingOrLinkedFileCannotBeOverwritten() throws {
        let (file, url, data) = try fixture()
        try file.clean(scope: scope)
        let other = url.deletingLastPathComponent().appendingPathComponent("other")
        try data.write(to: other)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: other.path)
        XCTAssertThrowsError(try file.write(data)); XCTAssertThrowsError(try file.clean(scope: scope))
        XCTAssertEqual(try Data(contentsOf: other), data)
    }
    func testWriteAuthorityRejectsDifferentBytesAndExistingFile() throws {
        let (file, url, data) = try fixture()
        XCTAssertThrowsError(try file.write(Data("foreign".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try file.write(data); XCTAssertThrowsError(try file.write(data))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
