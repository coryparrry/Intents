#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparationBuildRecoveryTests: XCTestCase, @unchecked Sendable {
    private actor Calls {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
        func all() -> [String] { values }
        func count(_ prefix: String) -> Int { values.filter { $0.hasPrefix(prefix) }.count }
    }
    private static func result(_ status: Int32, _ text: String = "") -> AutomationOwnedCommand.Result {
        .init(exitStatus: status, stdout: Data(text.utf8), stderr: Data(), logsTruncated: false)
    }
    func testSemanticBaselineFailureStopsWithoutRepairOrRetryAndPreservesAppBytes() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App.swift"), source = Data("let value: Int = \"bad\"".utf8)
        try source.write(to: app)
        let calls = Calls(), recovery = AutomationPreparationBuildRecovery(pinnedDependencies: true)
        do {
            try await recovery.baseline(build: { await calls.add("baseline"); return Self.result(65, "App.swift:1: error: cannot convert value") }, retain: { _, _ in })
            try await recovery.host(build: { await calls.add("host"); return Self.result(0) },
                recheckBaseline: {}, repair: { _ in await calls.add("repair"); return true }, retain: { _, _, _ in })
            XCTFail("Invalid app baseline must fail preparation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("unmodified app baseline"))
        }
        let events = await calls.all(); XCTAssertEqual(events, ["baseline"])
        XCTAssertEqual(try Data(contentsOf: app), source)
    }
    func testHostFailureRechecksBaselineThenRecoversOnce() async throws {
        let calls = Calls(), recovery = AutomationPreparationBuildRecovery(pinnedDependencies: false)
        try await recovery.host(build: {
            await calls.add("host")
            return await calls.count("host") == 1 ? Self.result(65) : Self.result(0)
        }, recheckBaseline: { await calls.add("baseline") }, repair: { pass in
            await calls.add("repair-\(pass)"); return true
        }, retain: { _, _, _ in })
        let events = await calls.all(); XCTAssertEqual(events, ["host", "baseline", "repair-1", "host"])
    }
    func testPersistentHostFailureHasOnlyTwoRepairPasses() async throws {
        let calls = Calls(), recovery = AutomationPreparationBuildRecovery(pinnedDependencies: false)
        do {
            try await recovery.host(build: { await calls.add("host"); return Self.result(65) },
                recheckBaseline: { await calls.add("baseline") }, repair: { pass in await calls.add("repair-\(pass)"); return true },
                retain: { _, _, _ in })
            XCTFail("Host cannot retry forever")
        } catch { XCTAssertTrue(String(describing: error).contains("associated host support failed")) }
        let events = await calls.all()
        XCTAssertEqual(events, ["host", "baseline", "repair-1", "host", "baseline", "repair-2", "host", "baseline"])
    }
    func testRecheckAppFailureNeverRepairsGeneratedSupport() async throws {
        let calls = Calls(), recovery = AutomationPreparationBuildRecovery(pinnedDependencies: false)
        do {
            try await recovery.host(build: { Self.result(65) }, recheckBaseline: {
                throw AutomationContractError.missingEvidence("unmodified app baseline failed")
            }, repair: { _ in await calls.add("repair"); return true }, retain: { _, _, _ in })
            XCTFail("Baseline regression must be retained")
        } catch { XCTAssertTrue(String(describing: error).contains("unmodified app baseline")) }
        let events = await calls.all(); XCTAssertTrue(events.isEmpty)
    }
    func testTransientPackageRetryIsPinnedAndSharedAcrossPreparation() async throws {
        let transient = Self.result(65, "Could not resolve package dependencies: Connection reset by peer")
        let calls = Calls(), recovery = AutomationPreparationBuildRecovery(pinnedDependencies: true)
        try await recovery.baseline(build: {
            await calls.add("baseline"); return await calls.count("baseline") == 1 ? transient : Self.result(0)
        }, retain: { _, _ in })
        do {
            try await recovery.host(build: { await calls.add("host"); return transient }, recheckBaseline: {},
                repair: { _ in false }, retain: { _, _, _ in })
            XCTFail("Retry budget was consumed by baseline")
        } catch { }
        let baselineCount = await calls.count("baseline"), hostCount = await calls.count("host")
        XCTAssertEqual(baselineCount, 2); XCTAssertEqual(hostCount, 1)
        XCTAssertFalse(AutomationPreparationBuildRecovery.transientPackageFailure(Self.result(65, "App.swift: error: The request timed out")))
        let unpinned = AutomationPreparationBuildRecovery(pinnedDependencies: false), unpinnedCalls = Calls()
        do {
            try await unpinned.baseline(build: { await unpinnedCalls.add("baseline"); return transient }, retain: { _, _ in })
            XCTFail("Unpinned dependency inputs cannot be retried")
        } catch { }
        let unpinnedCount = await unpinnedCalls.count("baseline"); XCTAssertEqual(unpinnedCount, 1)
    }
    func testBaselineProjectSwapRestoresGeneratedProjectOnFailure() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project.pbxproj"), baseline = Data("baseline".utf8), generated = Data("host".utf8)
        try generated.write(to: project)
        do {
            try await AutomationPreparationBuildRecovery.recheckBaseline(project: project, baseline: baseline, generated: generated) {
                XCTAssertEqual(try Data(contentsOf: project), baseline)
                throw AutomationContractError.missingEvidence("baseline compile failure")
            }
            XCTFail("Failure must survive restoration")
        } catch { XCTAssertTrue(String(describing: error).contains("baseline compile failure")) }
        XCTAssertEqual(try Data(contentsOf: project), generated)
    }
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/preparation-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
#endif
