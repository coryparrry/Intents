#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationAppleRouteDriverTests {
    private typealias Runner = AutomationLiveRunnerFixture.Runner
    /// Installs the prepared host into the target's CoreSimulator container, where a simulator runner executes.
    private func installedExecutable(_ h: Harness) throws -> URL {
        let bundle = h.root.appendingPathComponent("CoreSimulator/Devices/\(h.host.target.id)/data/Containers/Bundle/Application/\(UUID().uuidString)/OwnedHost-Runner.app")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: h.host.hostBundlePath), to: bundle)
        return bundle.appendingPathComponent("OwnedHost-Runner")
    }
    private func adopt(_ h: Harness, _ runner: Runner,
                       presence: (@Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence)? = nil) async throws -> AutomationAppleRouteDriver {
        var commands = CommandFixture(h, runner: runner).adapter; commands.runnerPresence = presence
        let driver = try driver(h, commands: commands)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let receipt = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        XCTAssertTrue(receipt.completed)
        let record = try await h.leases.currentRecord(h.lease)
        XCTAssertEqual(record.runners.map(\.process), [runner.identity])
        XCTAssertEqual(record.runners.map(\.role), [.appleHost])
        XCTAssertEqual(record.runners.map(\.executablePath), [runner.executable.path])
        return driver
    }
    private func assertOwnershipRetained(_ h: Harness, _ proof: AutomationReleaseProof, _ runner: Runner,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(proof.commandsDrained, file: file, line: line)
        XCTAssertFalse(proof.runnerTerminated, file: file, line: line)
        XCTAssertFalse(proof.privatePayloadCleaned, file: file, line: line)
        XCTAssertEqual(runner.identity.presence(), .matching, "Runner must not be treated as stopped", file: file, line: line)
        let current = await h.leases.isCurrent(h.lease); XCTAssertTrue(current, file: file, line: line)
        do { try await h.leases.release(h.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated); XCTFail("Lease released with a live runner", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified, file: file, line: line) }
    }
    func testOwnedLiveRunnerIsAdoptedAndTerminatedBeforeTheLeaseCanRelease() async throws {
        let h = try await fixture(liveHost: true), runner = try AutomationLiveRunnerFixture.launch(installedExecutable(h), in: self)
        let driver = try await adopt(h, runner)
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        XCTAssertTrue([.absent, .replaced].contains(runner.identity.presence()))
        try await h.leases.release(h.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated)
    }
    func testRunnerIgnoringTerminationRetainsOwnershipUntilItIsGone() async throws {
        let h = try await fixture(liveHost: true)
        let runner = try AutomationLiveRunnerFixture.launch(installedExecutable(h), ignoringTerminate: true, in: self)
        let driver = try await adopt(h, runner)
        let started = ContinuousClock.now
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(2))
        try await assertOwnershipRetained(h, proof, runner)
        try await AutomationLiveRunnerFixture.forceStop(runner)
        let retry = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(retry.runnerTerminated); XCTAssertTrue(retry.privatePayloadCleaned)
        try await h.leases.release(h.lease, commandsDrained: retry.commandsDrained, ownedRunnerTerminated: retry.runnerTerminated)
    }
    func testRunnerWhoseInstalledProductDriftedIsNeverSignalled() async throws {
        let h = try await fixture(liveHost: true), runner = try AutomationLiveRunnerFixture.launch(installedExecutable(h), in: self)
        let driver = try await adopt(h, runner)
        let info = runner.executable.deletingLastPathComponent().appendingPathComponent("Info.plist")
        try (Data(contentsOf: info) + Data([0])).write(to: info)
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        try await assertOwnershipRetained(h, proof, runner)
    }
    func testRunnerOutsideTheTargetSimulatorIsNeverAdopted() async throws {
        let h = try await fixture(liveHost: true)
        let runner = try AutomationLiveRunnerFixture.launch(URL(fileURLWithPath: h.host.hostBundlePath).appendingPathComponent("OwnedHost-Runner"), in: self)
        let commands = CommandFixture(h, runner: runner), driver = try driver(h, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Foreign runner adopted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let record = try await h.leases.currentRecord(h.lease); XCTAssertTrue(record.runners.isEmpty)
        XCTAssertEqual(runner.identity.presence(), .matching)
    }
    func testUnknownRunnerPresenceFailsClosedWithoutSignalling() async throws {
        let h = try await fixture(liveHost: true), runner = try AutomationLiveRunnerFixture.launch(installedExecutable(h), in: self)
        let driver = try await adopt(h, runner, presence: { _ in .unknown })
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        try await assertOwnershipRetained(h, proof, runner)
    }
}
#endif
