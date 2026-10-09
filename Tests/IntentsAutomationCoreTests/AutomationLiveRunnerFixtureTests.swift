#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationLiveRunnerFixtureTests: XCTestCase, @unchecked Sendable {
    private let identity = AutomationProcessIdentity(pid: 12345, startIdentity: "1:2")

    func testCleanupDoesNotSignalReplacedAbsentOrUnknownIdentity() {
        for state in [AutomationProcessIdentity.Presence.replaced, .absent, .unknown] {
            var signalled = false
            let stopped = AutomationLiveRunnerFixture.signalIfMatching(identity, presence: { _ in state },
                signal: { _, _ in signalled = true; return 0 })
            XCTAssertFalse(stopped); XCTAssertFalse(signalled)
        }
    }
    func testCleanupSignalsOnlyTheMatchingIdentity() {
        var signals: [(Int32, Int32)] = []
        XCTAssertTrue(AutomationLiveRunnerFixture.signalIfMatching(identity, presence: { _ in .matching },
            signal: { signals.append(($0, $1)); return 0 }))
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.0, identity.pid); XCTAssertEqual(signals.first?.1, SIGKILL)
    }
    func testCaptureRejectsPIDThatIsNoLongerTheLaunchersChild() {
        XCTAssertThrowsError(try AutomationLiveRunnerFixture.captureOwnedIdentity(pid: identity.pid, launcherPID: 99,
            inspect: { _ in self.identity }, parent: { _ in 100 })) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
    func testCaptureRejectsIdentityReplacementDuringParentCheck() {
        var reads = 0
        XCTAssertThrowsError(try AutomationLiveRunnerFixture.captureOwnedIdentity(pid: identity.pid, launcherPID: 99,
            inspect: { _ in
                reads += 1
                return reads == 1 ? self.identity : .init(pid: self.identity.pid, startIdentity: "3:4")
            }, parent: { _ in 99 })) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
    func testCaptureRejectsMissingKernelIdentity() {
        XCTAssertThrowsError(try AutomationLiveRunnerFixture.captureOwnedIdentity(pid: identity.pid, launcherPID: 99,
            inspect: { _ in nil }, parent: { _ in 99 })) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
    func testStartupWaitTimesOutWithoutExecutingAnyPIDSignal() {
        XCTAssertThrowsError(try AutomationLiveRunnerFixture.waitForExecutable(identity,
            executable: URL(fileURLWithPath: "/synthetic/fixture"), timeout: .zero,
            presence: { _ in .matching }, path: { _ in nil })) {
            XCTAssertEqual($0 as? AutomationRPCError, .timedOut)
        }
    }
    func testStartupRejectsReplacementEvenWhenExecutablePathMatches() {
        var reads = 0
        XCTAssertThrowsError(try AutomationLiveRunnerFixture.waitForExecutable(identity,
            executable: URL(fileURLWithPath: "/synthetic/fixture"), presence: { _ in
                reads += 1; return reads == 1 ? .matching : .replaced
            }, path: { _ in "/synthetic/fixture" })) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
    func testForceStopLeavesReplacedIdentityProcessAlive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("sleep")
        try AutomationLiveRunnerFixture.installExecutable(at: executable)
        let runner = try AutomationLiveRunnerFixture.launch(executable, in: self)
        var stale = runner.identity; stale.startIdentity += "-stale"
        try await AutomationLiveRunnerFixture.forceStop(.init(identity: stale, executable: executable))
        XCTAssertEqual(runner.identity.presence(), .matching)
        try await AutomationLiveRunnerFixture.forceStop(runner)
        XCTAssertTrue([.absent, .replaced].contains(runner.identity.presence()))
    }
}
#endif
