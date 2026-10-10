#if os(macOS) || os(Linux)
import XCTest
import Synchronization
@testable import IntentsAutomationCore

final class AutomationCommandCallbackDrainTests: XCTestCase, @unchecked Sendable {
    private actor CallbackGate {
        var entered = false
        var finished = false
        var opened = false
        var taskFinished = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if opened { finished = true; return }
            await withCheckedContinuation { continuation = $0 }
            finished = true
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
        func completeTask() { taskFinished = true }
        func begin() { entered = true }
        func finishCallback() { finished = true }
    }
    private func check(phase: String, cancelled: Bool) async throws {
        let command = AutomationOwnedCommand(), gate = CallbackGate()
        let executable = try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep"))
        let task = Task {
            try await command.run(executable: executable, arguments: ["30"], directory: URL(fileURLWithPath: "/private/tmp"),
                environment: [:], timeout: cancelled ? .seconds(10) : .seconds(1),
                willStart: { if phase == "will" { await gate.wait() } },
                didStart: { _ in if phase == "did" { await gate.wait() } })
        }
        let completion = expectation(description: "Command ends while unresolved callback remains owned")
        let watcher = Task { _ = await task.result; await gate.completeTask(); completion.fulfill() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else {
            task.cancel(); await gate.open(); _ = await command.stopOwned(); watcher.cancel()
            return XCTFail("Callback did not start")
        }
        do {
            try await exercise(command: command, gate: gate, task: task, completion: completion,
                               executable: executable, phase: phase, cancelled: cancelled)
        } catch {
            await gate.open(); task.cancel(); _ = await command.stopOwned(); watcher.cancel()
            throw error
        }
        await gate.open(); task.cancel(); _ = await command.stopOwned(); watcher.cancel()
    }
    private func exercise(command: AutomationOwnedCommand, gate: CallbackGate,
                          task: Task<AutomationOwnedCommand.Result, any Error>, completion: XCTestExpectation,
                          executable: URL, phase: String, cancelled: Bool) async throws {
        if cancelled { task.cancel() }
        await fulfillment(of: [completion], timeout: 6)
        guard await gate.taskFinished else { return XCTFail("Command did not finish within its cleanup bound") }
        do { _ = try await task.value; XCTFail("Unsettled callback was released") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let logs = await command.retainedLogs()
        XCTAssertFalse(logs.callbacksDrained)
        if phase == "did" { XCTAssertNotNil(logs.ownedIdentity) }
        let finishedBeforeRelease = await gate.finished
        XCTAssertFalse(finishedBeforeRelease)
        do {
            _ = try await command.run(executable: executable, arguments: ["0"], directory: URL(fileURLWithPath: "/private/tmp"),
                                      environment: [:], timeout: .seconds(2))
            XCTFail("A new command overwrote unresolved callback ownership")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        await gate.open()
        let stopped = await command.stopOwned()
        XCTAssertTrue(stopped)
        let finishedAfterRelease = await gate.finished
        XCTAssertTrue(finishedAfterRelease)
        let next = try await command.run(executable: executable, arguments: ["0"], directory: URL(fileURLWithPath: "/private/tmp"),
                                         environment: [:], timeout: .seconds(2))
        XCTAssertEqual(next.exitStatus, 0)
        XCTAssertTrue(next.callbacksDrained)
    }
    func testTimedOutPrelaunchCallbackRetainsOwnership() async throws { try await check(phase: "will", cancelled: false) }
    func testCancelledPrelaunchCallbackRetainsOwnership() async throws { try await check(phase: "will", cancelled: true) }
    func testTimedOutPostlaunchCallbackRetainsOwnership() async throws { try await check(phase: "did", cancelled: false) }
    func testCancelledPostlaunchCallbackRetainsOwnership() async throws { try await check(phase: "did", cancelled: true) }
    func testUnknownProcessIdentityStillCancelsPostlaunchCallback() async throws {
        let actual = Mutex(false), gate = CallbackGate()
        let command = AutomationOwnedCommand(presenceReader: { identity in actual.withLock { $0 } ? identity.presence() : .unknown })
        let task = Task {
            try await command.run(executable: try AutomationPath.canonical(URL(fileURLWithPath: "/bin/sleep")), arguments: ["30"],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(10), didStart: { _ in
                    await gate.begin()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { await gate.finishCallback(); throw error }
                })
        }
        let completion = expectation(description: "Uncertain process callback cancellation settles")
        let watcher = Task { _ = await task.result; await gate.completeTask(); completion.fulfill() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        let stopped = await command.stopOwned()
        XCTAssertFalse(stopped)
        let cancelled = await gate.finished
        XCTAssertTrue(cancelled, "Identity uncertainty must not bypass callback cancellation")
        actual.withLock { $0 = true }
        task.cancel()
        let cleaned = await command.stopOwned()
        XCTAssertTrue(cleaned)
        await fulfillment(of: [completion], timeout: 6)
        let finished = await gate.taskFinished
        XCTAssertTrue(finished)
        watcher.cancel()
    }
}
#endif
