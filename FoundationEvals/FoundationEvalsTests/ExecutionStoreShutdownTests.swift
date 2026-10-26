import Dispatch
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct ExecutionStoreShutdownTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func evaluationCloseCancelsAndJoinsJudgeOperations(calibration: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = AsyncStream<Void>.makeStream(), cancelled = AsyncStream<Void>.makeStream()
        let cancellationWait = AsyncStream<Void>.makeStream()
        let cleanupAllowed = ShutdownSignal()
        defer {
            started.continuation.finish()
            cancelled.continuation.finish()
            cancellationWait.continuation.finish()
            Task { await cleanupAllowed.open() }
        }
        let client = EvaluationCompatibleJudgeClient(transport: { _ in
            started.continuation.yield(())
            started.continuation.finish()
            var iterator = cancellationWait.stream.makeAsyncIterator()
            _ = await iterator.next()
            #expect(Task.isCancelled)
            cancelled.continuation.yield(())
            cancelled.continuation.finish()
            await cleanupAllowed.wait()
            throw CancellationError()
        })
        var runWrites = 0
        let store = EvaluationStore(
            supportDirectory: root,
            reassessmentService: EvaluationReassessmentService(client: client),
            runWriter: { data, url in
                runWrites += 1
                try data.write(to: url, options: .atomic)
            }
        )
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "Saved output", prompt: "request", expected: "RESULT")]
        try #require(store.saveSuite())
        let run = try await store.runFeatureAdapter(
            expectedRevision: store.currentSuiteRevision(),
            adapter: ClosureFeatureAdapter(displayName: "Saved subject") { _ in "RESULT" }
        )
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Held judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "held-judge"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.criteria = "The response accurately answers the request."
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()
        try #require(store.saveSuite())
        if calibration {
            let assessment = EvaluationAssessment(
                id: UUID(), runID: run.id, createdAt: .now, origin: .reassessment,
                judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Original judge",
                             endpointKind: nil, baseURL: nil, requestedModelID: "original",
                             reportedModelID: nil, provider: nil, providerOrder: []),
                promptVersion: EvaluationRunner.judgePromptVersion,
                rubric: store.suite.criteria, passingScore: EvaluationSuite.judgePassingScore,
                samples: [.init(id: UUID(), sampleID: run.results[0].id, status: .passed,
                                score: 4, rationale: "Original assessment", trace: nil,
                                errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: 1)],
                totalUsage: nil, durationMilliseconds: 1,
                cost: .init(availability: .known, usd: 0, explanation: "Fixture"),
                supersedesAssessmentID: nil, scoringContract: try EvaluationScoringContract(suite: store.suite),
                subjectEvidenceDigest: run.subjectEvidence?.digest
            )
            store.runs[0].assessments = [assessment]
            store.runs[0].selectedAssessmentID = assessment.id
            try store.markJudgmentIncorrect(
                runID: run.id, assessmentID: assessment.id, sampleID: run.results[0].id,
                correctedStatus: .passed, correctedScore: 4, reason: "Reviewed original response",
                collectAsJudgeCheck: true
            )
            store.runJudgeChecks(connectionID: connection.id)
        } else {
            store.reassessRun(id: run.id, connectionID: connection.id)
        }
        var startedIterator = started.stream.makeAsyncIterator()
        guard await startedIterator.next() != nil else { throw CancellationError() }
        let priorAssessmentIDs = store.runs[0].assessments?.map(\.id)
        let priorRunWrites = runWrites
        var closed = false
        let closing = Task { @MainActor in
            await store.closeAndWait()
            closed = true
        }
        var cancelledIterator = cancelled.stream.makeAsyncIterator()
        guard await cancelledIterator.next() != nil else { throw CancellationError() }
        #expect(!closed)
        #expect(store.isReassessing)
        await cleanupAllowed.open()
        await closing.value
        #expect(closed)
        #expect(!store.isReassessing)
        #expect(store.latestJudgeCheck == nil)
        #expect(store.runs[0].assessments?.map(\.id) == priorAssessmentIDs)
        #expect(runWrites == priorRunWrites)
        store.reassessRun(id: run.id, connectionID: connection.id)
        #expect(!store.isReassessing)
        store.runJudgeChecks(connectionID: connection.id)
        #expect(!store.isReassessing)
        await store.closeAndWait()
    }

    /// Checks that closing joins tracked cancellation cleanup even when stop already cancelled the run.
    @Test(arguments: [false, true])
    func developerCloseJoinsCancellationCleanupAndRejectsNewExecution(stopFirst: Bool) async throws {
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
        if stopFirst {
            runners.stop()
            await cancelled.wait()
            #expect(!completed)
            #expect(runners.executingRunID == runID)
        }
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
