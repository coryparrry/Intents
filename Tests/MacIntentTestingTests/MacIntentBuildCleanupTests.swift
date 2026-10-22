import Darwin
import Foundation
import Testing
@testable import MacIntentTesting

@MainActor
struct MacIntentBuildCleanupTests {
    enum Outcome: CaseIterable, Sendable {
        case success, failure, launchFailure, timeout, callerCancellation, runnerCancellation
    }

    @Test(.timeLimit(.minutes(1)), arguments: Outcome.allCases)
    func buildProductsAreRemovedOnlyAfterTheOwnedProcessEnds(outcome: Outcome) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("MacIntentRun-fixture", isDirectory: true)
        let derivedData = workspace.appendingPathComponent("DerivedData", isDirectory: true)
        try fm.createDirectory(at: derivedData.appendingPathComponent("Build/Products"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("rebuildable product".utf8).write(to: derivedData.appendingPathComponent("Build/Products/host"))
        let source = workspace.appendingPathComponent("Tests/MacIntentTests.swift")
        let bundleEvidence = workspace.appendingPathComponent("Tests.xcresult/diagnostics.txt")
        for url in [source, bundleEvidence] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("retained evidence".utf8).write(to: url)
        }
        let unrelated = root.appendingPathComponent("OtherRun/DerivedData/keep.txt")
        try fm.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("another run".utf8).write(to: unrelated)
        let logURL = workspace.appendingPathComponent("run.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        log.write(Data("retained log\n".utf8))
        let input = workspace.appendingPathComponent("child-input")
        #expect(mkfifo(input.path, 0o600) == 0)
        let script = """
        printf '%s' "$$" > child.pid
        trap 'printf stopped > child-ended; exit 0' INT TERM
        printf ready > child-ready
        IFS= read -r ignored < child-input
        printf finished > child-ended
        exit \(outcome == .failure ? 7 : 0)
        """
        let runner = MacIntentRunner()
        let task = Task {
            try await runner.executeBuild(
                executable: URL(fileURLWithPath: outcome == .launchFailure ? "/missing-build-command" : "/bin/sh"),
                arguments: ["-c", script], directory: workspace,
                environment: ProcessInfo.processInfo.environment, log: log,
                timeout: outcome == .timeout ? 1 : 30)
        }
        defer { task.cancel() }
        var cancellationRequestedAt: ContinuousClock.Instant?
        if outcome != .launchFailure {
            let ready = workspace.appendingPathComponent("child-ready")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !fm.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(fm.fileExists(atPath: ready.path), "The owned build process did not start")
            #expect(fm.fileExists(atPath: derivedData.path), "Active worker products must still exist")
            switch outcome {
            case .callerCancellation:
                cancellationRequestedAt = .now
                task.cancel()
            case .runnerCancellation:
                cancellationRequestedAt = .now
                runner.cancel()
            case .success, .failure:
                let writer = try FileHandle(forWritingTo: input)
                try writer.write(contentsOf: Data("finish\n".utf8))
                try writer.close()
            case .timeout, .launchFailure: break
            }
        }
        let result = await task.result
        if let cancellationRequestedAt {
            #expect(cancellationRequestedAt.duration(to: .now) < .seconds(10),
                    "Cancellation must stop the child before the ordinary 30-second timeout")
        }
        switch (outcome, result) {
        case (.success, .success(let status)): #expect(status == 0)
        case (.failure, .success(let status)): #expect(status == 7)
        case (.launchFailure, .failure): break
        case (.timeout, .failure(let error)): #expect(error.localizedDescription.contains("timeout"))
        case (.callerCancellation, _), (.runnerCancellation, _): break
        default: Issue.record("Unexpected build outcome: \(result)")
        }
        if outcome != .launchFailure {
            let pidText = try String(contentsOf: workspace.appendingPathComponent("child.pid"), encoding: .utf8)
            let pid = try #require(Int32(pidText))
            #expect(kill(pid, 0) == -1 && errno == ESRCH, "Cleanup must follow owned-process exit")
            #expect(fm.fileExists(atPath: workspace.appendingPathComponent("child-ended").path))
        }
        #expect(!fm.fileExists(atPath: derivedData.path))
        #expect(try Data(contentsOf: source) == Data("retained evidence".utf8))
        #expect(try Data(contentsOf: bundleEvidence) == Data("retained evidence".utf8))
        // A stopped shell may append its own interruption diagnostic. Cleanup
        // must retain the existing log, including all subsequently appended bytes.
        #expect(try Data(contentsOf: logURL).starts(with: Data("retained log\n".utf8)))
        #expect(try Data(contentsOf: unrelated) == Data("another run".utf8))
    }
}
