import XCTest
@testable import IntentsAutomationCore

final class AutomationProcessTests: XCTestCase, @unchecked Sendable {
    func testKernelAbsentChildCanReconcileStaleRunningState() throws {
        let child = Process()
        child.executableURL = try AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/true"))
        child.environment = [:]
        try child.run()
        let pid = child.processIdentifier
        child.waitUntilExit()
        XCTAssertGreaterThan(pid, 0)
        // Model Foundation's delayed notification against an actual reaped kernel process.
        XCTAssertTrue(AutomationOwnedCommand.permitsUncapturedExit(pid: pid, isRunning: true))
        XCTAssertTrue(AutomationOwnedCommand.permitsUncapturedExit(pid: pid, isRunning: false))
    }
    func testUncapturedLiveAndInvalidPIDsCannotReconcileRunningState() throws {
        let child = Process()
        child.executableURL = try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep"))
        child.arguments = ["30"]
        child.environment = [:]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        XCTAssertTrue(child.isRunning)
        XCTAssertFalse(AutomationOwnedCommand.permitsUncapturedExit(pid: child.processIdentifier, isRunning: true))
        for pid in [Int32(0), Int32(-1)] {
            XCTAssertFalse(AutomationOwnedCommand.permitsUncapturedExit(pid: pid, isRunning: true))
            XCTAssertFalse(AutomationOwnedCommand.permitsUncapturedExit(pid: pid, isRunning: false))
        }
    }
    func testVeryShortCommandsFinishWithoutInventingAnUnreleasedProcess() async throws {
        let command = AutomationOwnedCommand()
        for _ in 0..<30 {
            let result = try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/true")),
                arguments: [], directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(3))
            XCTAssertEqual(result.exitStatus, 0); XCTAssertFalse(result.logsTruncated)
        }
    }
    func testTimeoutRetainsBoundedFailureOutputAfterStoppingOwnedChild() async throws {
        let command = AutomationOwnedCommand()
        do {
            _ = try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sh")),
                arguments: ["-c", "printf 'failure context\\n'; printf 'diagnostic\\n' >&2; exec /bin/sleep 30"],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(3))
            XCTFail("Expected a timeout")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let retained = await command.retainedLogs()
        XCTAssertTrue(String(decoding: retained.stdout, as: UTF8.self).contains("failure context"))
        XCTAssertTrue(String(decoding: retained.stderr, as: UTF8.self).contains("diagnostic"))
    }
    func testOwnedCommandDrainsLargeOutputAndBoundsRetainedLogs() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp")
        let result = try await AutomationOwnedCommand().run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/python3")),
            arguments: ["-c", "import sys,time; sys.stdout.buffer.write(b'a'*2097152); sys.stdout.flush(); sys.stderr.write('diagnostic'); time.sleep(.1)"],
            directory: directory, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertEqual(result.exitStatus, 0); XCTAssertEqual(result.stdout.count, 1_048_576)
        XCTAssertTrue(result.logsTruncated); XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "diagnostic")
    }
    func testTimeoutTerminatesOnlyTheRecordedChildAndCanRunAReadAfterward() async throws {
        let command = AutomationOwnedCommand(), recorder = ProcessRecorder()
        do {
            _ = try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep")), arguments: ["30"],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .milliseconds(100), didStart: { await recorder.record($0) })
            XCTFail()
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let identity = try await recorder.identity(); XCTAssertEqual(identity.presence(), .absent)
        let result = try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/echo")), arguments: ["done"],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(5))
        XCTAssertEqual(result.exitStatus, 0); XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }
    func testExpiredCommandNeverStartsAProcess() async throws {
        let recorder = ProcessRecorder()
        do {
            _ = try await AutomationOwnedCommand().run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/echo")), arguments: ["unapproved"],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(-1), didStart: { await recorder.record($0) })
            XCTFail()
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let recorded = await recorder.wasRecorded; XCTAssertFalse(recorded)
    }
    func testSuccessfulExitWaitsForKernelAbsenceAndThenPermitsLeaseRelease() async throws {
        for initially in [AutomationProcessIdentity.Presence.matching, .unknown] {
            let reader = ControlledPresence(initially), command = AutomationOwnedCommand(presenceReader: { reader.read($0) })
            let recorder = ProcessRecorder(), leases = AutomationDeviceLeaseManager()
            let lease = try await leases.acquire(runID: "delayed", target: .init(id: "test", kind: .simulator), control: .system)
            let task = Task {
                try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep")), arguments: ["0.1"],
                    directory: FileManager.default.temporaryDirectory, environment: [:], timeout: .seconds(5), didStart: { identity in
                        await recorder.record(identity)
                        try await leases.recordRunner(.init(scope: .init(runID: "delayed", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation),
                            process: identity, role: .nativeCommand, executablePath: "/bin/sleep"), lease: lease)
                    })
            }
            for _ in 0..<200 {
                if await command.retainedLogs().exitStatus == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let held = await command.retainedLogs(); XCTAssertEqual(held.exitStatus, 0)
            do { _ = try await command.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["overwrite"], directory: FileManager.default.temporaryDirectory, environment: [:], timeout: .seconds(1)); XCTFail("Unproved owner was overwritten") } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
            reader.allowActual()
            let result = try await task.value; XCTAssertEqual(result.exitStatus, 0)
            let identity = try await recorder.identity(); XCTAssertTrue([.absent, .replaced].contains(identity.presence()))
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        }
    }
    func testPersistentUnknownExitRetainsLogsAndOwnershipUntilProvenAbsent() async throws {
        let reader = ControlledPresence(.unknown), command = AutomationOwnedCommand(presenceReader: { reader.read($0) })
        do {
            _ = try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sh")), arguments: ["-c", "printf retained; sleep 0.1"],
                directory: FileManager.default.temporaryDirectory, environment: [:], timeout: .milliseconds(300))
            XCTFail("Unknown kernel identity was released")
        } catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let logs = await command.retainedLogs(); XCTAssertEqual(String(decoding: logs.stdout, as: UTF8.self), "retained")
        let stopped = await command.stopOwned(); XCTAssertFalse(stopped)
        do { _ = try await command.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [], directory: FileManager.default.temporaryDirectory, environment: [:], timeout: .seconds(1)); XCTFail("Unknown ownership overwritten") } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        reader.allowActual(); let proved = await command.stopOwned(); XCTAssertTrue(proved)
    }
    func testActualOwnedSimulatorInventoryDrainsBothPipes() async throws {
        guard let target = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_INVENTORY_TEST_TARGET"] else { throw XCTSkip("No explicit owned simulator command profile") }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "spawn", target, "launchctl", "list"], directory: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "HOME": root.path, "TMPDIR": root.path], timeout: .seconds(3))
        XCTAssertEqual(result.exitStatus, 0); XCTAssertFalse(result.logsTruncated)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).hasPrefix("PID\tStatus\tLabel\n"))
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).hasSuffix("\n"))
    }
    func testStoppingDuringLaunchAuthorizationPreventsTheChildFromStarting() async throws {
        let command = AutomationOwnedCommand(), gate = CommandGate()
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-exist")
        let python = try AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/python3"))
        let task = Task {
            try await command.run(executable: python, arguments: ["-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('unapproved')", marker.path],
                directory: root, environment: [:], timeout: .seconds(5), willStart: { await gate.wait() })
        }
        let completion = expectation(description: "Revoked command settles")
        let watcher = Task { _ = await task.result; await gate.completeCommand(); completion.fulfill() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.isWaiting) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard await gate.isWaiting else {
            await gate.finish(); task.cancel(); _ = await command.stopOwned(); watcher.cancel()
            return XCTFail("Launch callback did not start")
        }
        let stopped = await command.stopOwned(); XCTAssertFalse(stopped, "Suspended launch authorization has not drained")
        await gate.finish()
        await fulfillment(of: [completion], timeout: 6)
        guard await gate.commandFinished else {
            task.cancel(); _ = await command.stopOwned(); watcher.cancel()
            return XCTFail("Revoked command exceeded its cleanup bound")
        }
        do { _ = try await task.value; XCTFail("Revoked launch must fail") }
        catch { XCTAssertTrue(error is CancellationError || error as? AutomationContractError == .terminationUnverified) }
        let drained = await command.stopOwned(); XCTAssertTrue(drained)
        watcher.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testAlreadyCancelledCallerNeverLaunchesItsExecutable() async throws {
        let recorder = ProcessRecorder(), gate = CommandGate()
        let task = Task {
            await gate.wait()
            return try await AutomationOwnedCommand().run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep")),
                arguments: ["30"], directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(5),
                didStart: { await recorder.record($0) })
        }
        task.cancel(); await gate.finish()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await recorder.wasRecorded; XCTAssertFalse(recorded)
    }
}
private actor CommandGate {
    var isWaiting: Bool { waiter != nil }
    var finished = false
    var commandFinished = false
    func completeCommand() { commandFinished = true }
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !finished { await withCheckedContinuation { waiter = $0 } } }
    func finish() { finished = true; waiter?.resume(); waiter = nil }
}
private actor ProcessRecorder {
    private var value: AutomationProcessIdentity?
    var wasRecorded: Bool { value != nil }
    func record(_ identity: AutomationProcessIdentity) { value = identity }
    func identity() throws -> AutomationProcessIdentity { try XCTUnwrap(value) }
}

private final class ControlledPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var forced: AutomationProcessIdentity.Presence?
    init(_ value: AutomationProcessIdentity.Presence) { forced = value }
    func read(_ identity: AutomationProcessIdentity) -> AutomationProcessIdentity.Presence { lock.withLock { forced ?? identity.presence() } }
    func allowActual() { lock.withLock { forced = nil } }
}
