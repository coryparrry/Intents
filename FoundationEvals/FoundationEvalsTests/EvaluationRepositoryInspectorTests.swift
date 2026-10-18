import Darwin
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationRepositoryInspectorTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func hangingRepositoryInspectionStopsItsChild(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fixture-git")
        // A shell builtin loop creates one owned process, with no descendants
        // that could outlive the timeout and obscure the termination assertion.
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > child.pid\nwhile :; do :; done\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = ContinuousClock.now
        let inspection = Task {
            await EvaluationRepositoryInspector.snapshot(rootPath: root.path, gitExecutable: executable,
                timeout: cancel ? .seconds(30) : .seconds(2))
        }
        let pidFile = root.appending(path: "child.pid")
        let launchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < launchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if cancel { inspection.cancel() }
        let snapshot = await inspection.value
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(snapshot.error != nil)
        #expect(snapshot.commit == nil && snapshot.isDirty == nil)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedInspectionPreservesCommitAndDirtyStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fixture-git")
        let commit = String(repeating: "a", count: 40)
        let script = """
        #!/bin/sh
        case "$*" in
          *"rev-parse HEAD") printf '%s\\n' '\(commit)' ;;
          *) printf ' M tracked.txt\\n' ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let snapshot = await EvaluationRepositoryInspector.snapshot(rootPath: root.path, gitExecutable: executable)
        #expect(snapshot.error == nil)
        #expect(snapshot.commit == commit)
        #expect(snapshot.isDirty == true)
    }
}
