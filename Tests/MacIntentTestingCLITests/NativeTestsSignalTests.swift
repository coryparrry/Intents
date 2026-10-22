import Darwin
import Foundation
import Testing
@testable import MacIntentTesting

struct NativeTestsSignalTests {
    @Test(.timeLimit(.minutes(1)))
    func interruptAndTerminateDrainOwnedChildrenAndRestoreDispositions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-signals-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("signal-fixture")
        let compilationLog = root.appendingPathComponent("compile.log")
        FileManager.default.createFile(atPath: compilationLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: compilationLog)
        defer { try? log.close() }
        let compiler = await MacIntentOwnedCommand()
        let compilationStatus = try await compiler.execute(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", root.appendingPathComponent("modules").path,
            repository.appendingPathComponent("Sources/MacIntentTestingCLI/NativeTestsSignals.swift").path,
            repository.appendingPathComponent("Sources/MacIntentTesting/MacIntentOwnedCommand.swift").path,
            repository.appendingPathComponent("Tests/Fixtures/NativeTestsSignalFixture.swift").path,
            "-o", executable.path],
            directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 20)
        let diagnostics = try String(contentsOf: compilationLog, encoding: .utf8)
        try #require(compilationStatus == 0, "Fixture compilation failed: \(diagnostics)")

        for number in [SIGINT, SIGTERM] {
            let directory = root.appendingPathComponent("signal-\(number)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fifo = directory.appendingPathComponent("child-input")
            try #require(mkfifo(fifo.path, 0o600) == 0)
            let outputURL = directory.appendingPathComponent("command.log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let fixture = Process()
            fixture.executableURL = executable; fixture.arguments = [directory.path]
            fixture.standardOutput = output; fixture.standardError = output
            try fixture.run()
            var childPID: Int32?
            do {
                let pidFile = directory.appendingPathComponent("child.pid")
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while fixture.isRunning && ContinuousClock.now < deadline {
                    if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                        childPID = pid; break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(childPID, "Owned child did not start for signal \(number)")
                if number == SIGINT { fixture.interrupt() } else { fixture.terminate() }
                try await waitForExit(fixture, seconds: 8)
                try #require(fixture.terminationStatus == 1, "Signal \(number)")
                try #require(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "Owned child remains after signal \(number)")
                let result = try String(contentsOf: outputURL, encoding: .utf8)
                #expect(result.contains("cancelled; restored; released"), "Signal \(number): \(result)")
            } catch {
                // Release only this fixture's FIFO if the cancellation contract fails.
                if fixture.isRunning { fixture.terminate() }
                let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    _ = "finish\n".withCString { write(descriptor, $0, 7) }
                    close(descriptor)
                }
                try? await waitForExit(fixture, seconds: 5)
                if let childPID {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while Darwin.kill(childPID, 0) == 0 && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                throw error
            }
        }
    }

    private func waitForExit(_ process: Process, seconds: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else {
            throw NSError(domain: "NativeTestsSignalTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Owned test process exceeded \(seconds) seconds"])
        }
    }
}
