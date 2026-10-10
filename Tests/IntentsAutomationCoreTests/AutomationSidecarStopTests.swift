#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Uses /bin/sh as the sidecar runtime so stop escalation runs without the pinned Node runtime.
final class AutomationSidecarStopTests: XCTestCase, @unchecked Sendable {
    private func sidecar(_ script: String, exitGracePeriod: Duration = .seconds(5),
                         terminationGracePeriod: Duration = .seconds(5)) throws -> AutomationSidecarProcess {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let canonical = try AutomationPath.canonical(root), entry = canonical.appendingPathComponent("fixture.sh")
        try Data(script.utf8).write(to: entry)
        let shell = try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sh"))
        let process = try AutomationSidecarProcess(configuration: .init(node: shell, entry: entry, stateDirectory: canonical.appendingPathComponent("state")),
            reverse: { _, _ in .null }, exitGracePeriod: exitGracePeriod, terminationGracePeriod: terminationGracePeriod)
        // Register before start/handshake/assertions can throw. Teardown runs before directory removal.
        addTeardownBlock { await Self.cleanup(process) }
        return process
    }
    private static func cleanup(_ process: AutomationSidecarProcess) async {
        _ = await process.stop()
        guard let owned = await process.processIdentity else { return }
        if owned.presence() == .matching { kill(owned.pid, SIGKILL) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while owned.presence() == .matching && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue([.absent, .replaced].contains(owned.presence()), "Fixture child was not released during teardown")
    }
    private func helloResponder(protocolVersion: String, adapterVersion: String) -> String {
        """
        IFS= read -r line || exit 1
        id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":\(protocolVersion),"adapterVersion":\(adapterVersion)}}\\n' "$id"
        exec cat >/dev/null
        """
    }
    private func identity(_ process: AutomationSidecarProcess) async throws -> AutomationProcessIdentity {
        let identity = await process.processIdentity
        return try XCTUnwrap(identity)
    }

    func testCooperativeChildExitsOnEndOfInputWithoutEscalation() async throws {
        let process = try sidecar(helloResponder(protocolVersion: "1", adapterVersion: "\"0.1.0\""), exitGracePeriod: .seconds(5))
        try await process.start()
        let hello = try await process.handshake()
        XCTAssertEqual(hello.object?["adapterVersion"], .string("0.1.0"))
        let owned = try await identity(process); XCTAssertEqual(owned.presence(), .matching)
        let started = ContinuousClock.now
        let stopped = await process.stop()
        XCTAssertTrue(stopped)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "End of input alone must release a cooperative child")
        XCTAssertEqual(owned.presence(), .absent)
    }

    func testChildIgnoringEndOfInputIsTerminatedAfterGracePeriod() async throws {
        let process = try sidecar("exec /bin/sleep 30\n", exitGracePeriod: .milliseconds(300))
        try await process.start()
        let owned = try await identity(process)
        let started = ContinuousClock.now
        let stopped = await process.stop()
        let elapsed = ContinuousClock.now - started
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300), "Termination must wait for the end-of-input grace period")
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertEqual(owned.presence(), .absent)
    }

    func testChildSurvivingTerminationIsNeverReportedStopped() async throws {
        let process = try sidecar("trap '' TERM\nexec /bin/sleep 30\n", exitGracePeriod: .milliseconds(200),
                                  terminationGracePeriod: .milliseconds(500))
        try await process.start()
        let owned = try await identity(process)
        let stopped = await process.stop()
        XCTAssertFalse(stopped, "A child still running after terminate must not produce a release proof")
        XCTAssertEqual(owned.presence(), .matching)
    }

    func testFixtureCleanupStopsChildWhenSetupFailsBeforeExplicitStop() async throws {
        let process = try sidecar("trap '' TERM\nexec /bin/sleep 30\n", exitGracePeriod: .milliseconds(20),
                                  terminationGracePeriod: .milliseconds(20))
        try await process.start()
        let owned = try await identity(process)
        // Exercise the same cleanup registered by the fixture after a throwing setup step.
        enum SetupFailure: Error { case failed }
        do { throw SetupFailure.failed }
        catch { await Self.cleanup(process) }
        XCTAssertEqual(owned.presence(), .absent)
    }

    func testHandshakeRejectsIncompatibleProtocolOrAdapterVersions() async throws {
        for (protocolVersion, adapterVersion) in [("2", "\"0.1.0\""), ("1", "\"0.2.0\""), ("\"1\"", "\"0.1.0\""), ("1", "null")] {
            let process = try sidecar(helloResponder(protocolVersion: protocolVersion, adapterVersion: adapterVersion))
            try await process.start()
            do {
                _ = try await process.handshake()
                XCTFail("Accepted protocolVersion \(protocolVersion) adapterVersion \(adapterVersion)")
            } catch { XCTAssertEqual(error as? AutomationRPCError, .invalidFrame) }
            let stopped = await process.stop(); XCTAssertTrue(stopped)
        }
    }

    func testSecondStartIsRefusedWithoutReplacingTheOwnedChild() async throws {
        let process = try sidecar("exec cat >/dev/null\n")
        try await process.start()
        let pid = await process.processID, owned = try await identity(process)
        XCTAssertGreaterThan(pid, 0)
        do { try await process.start(); XCTFail("Second start replaced the owned child") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let unchanged = await process.processID; XCTAssertEqual(unchanged, pid)
        let stopped = await process.stop(); XCTAssertTrue(stopped)
        XCTAssertEqual(owned.presence(), .absent)
        do { try await process.start(); XCTFail("A stopped sidecar was relaunched") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
    }
}
#endif
