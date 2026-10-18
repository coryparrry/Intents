import Dispatch
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct ExecutionStoreShutdownTests {
    @Test func developerCloseJoinsCancellationCleanupAndRejectsNewExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let runners = DeveloperRunnerStore(evaluationStore: evaluation)
        let started = ShutdownSignal(), cancelled = ShutdownSignal(), cleanupAllowed = ShutdownSignal()
        var completed = false, closed = false
        let runID = UUID()
        runners.startTrackedExecution(runID: runID) {
            await started.open()
            do { try await Task.sleep(for: .seconds(3600)) } catch { }
            await cancelled.open()
            await cleanupAllowed.wait()
            completed = true
        }
        await started.wait()
        let closing = Task { @MainActor in
            await runners.closeAndWait()
            closed = true
        }
        await cancelled.wait()
        #expect(!completed)
        #expect(!closed)
        #expect(runners.executingRunID == runID)
        #expect(throws: EvaluationStoreError.self) {
            try runners.runSelectedSuite(on: UUID(), featureID: "closed")
        }
        await cleanupAllowed.open()
        await closing.value
        #expect(completed)
        #expect(closed)
        #expect(runners.executingRunID == nil)
        runners.startTrackedExecution(runID: UUID()) { Issue.record("Work started after closing.") }
        #expect(runners.executingRunID == nil)
        await runners.closeAndWait()
    }

    @Test func productionCloseDrainsAdmittedStorageWritesAndRejectsLaterWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let production = ProductionWorkspaceStore(root: root)
        _ = try #require(production.storage)
        let written = root.appending(path: "admitted.txt"), unexpected = root.appending(path: "unexpected.txt")
        let started = AsyncStream<Void>.makeStream()
        let allowWrite = DispatchSemaphore(value: 0)
        production.perform { _ in
            started.continuation.yield(())
            allowWrite.wait()
            try Data("retained".utf8).write(to: written)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        var closeEntered = false, closed = false
        let closing = Task { @MainActor in
            closeEntered = true
            await production.closeAndWait()
            closed = true
        }
        while !closeEntered { await Task.yield() }
        #expect(!closed)
        production.perform { _ in try Data("unexpected".utf8).write(to: unexpected) }
        allowWrite.signal()
        await closing.value
        #expect(closed)
        #expect(try String(contentsOf: written, encoding: .utf8) == "retained")
        #expect(!FileManager.default.fileExists(atPath: unexpected.path))
        await production.closeAndWait()
    }
}

private actor ShutdownSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
