import Foundation
import Darwin
import Testing
@testable import FoundationEvals

/// Exercises batch navigation and review presentation using isolated stores.
@MainActor struct ProductionBatchNavigationTests {
    /// Imports one captured response without invoking a model.
    private func dataset(_ storage: ProductionStorage, root: URL) throws -> ProductionDataset {
        let file = root.appendingPathComponent("examples.jsonl")
        try Data("{\"id\":\"case\",\"prompt\":\"Question\",\"capturedOutput\":\"Saved answer\"}\n".utf8).write(to: file)
        return try storage.importDataset(from: file, name: "Navigation", version: "1")
    }

    /// Checks opening a batch loads its report and results, and dismissing a loading result prevents stale detail restoration.
    @Test func openingBatchLoadsItsOutcomeAndSavedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-results-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root)
        let storage = try #require(model.storage)
        let data = try dataset(storage, root: root)
        let job = try storage.createCapturedJob(name: "Saved batch", datasetRevision: data.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "captured", operatingSystem: "fixture", hardware: "fixture", locale: "en", model: "original")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { try ProductionStorage.capturedResponse($0) }
        model.jobs = [job]; model.pane = .jobs
        model.showResults(for: job.id)
        for _ in 0..<500 {
            if model.report?.job.id == job.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pane == .review && model.selectedJobID == job.id)
        #expect(model.report?.completed == 1 && model.records.count == 1)
        #expect(model.records.first?.response.output == "Saved answer")
        let record = try #require(model.records.first)
        let loading = try #require(model.selectRecord(record))
        model.dismissResult()
        await loading.value
        #expect(model.selectedRecord == nil && model.selectedExample == nil && model.review == nil)
    }

    /// Checks older results retain active progress and explicit controls mutate only the running batch.
    @Test(.timeLimit(.minutes(1))) func olderResultsKeepActiveProgressAndControlsTargetTheirExplicitJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-active-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        let model = ProductionWorkspaceStore(root: root, capturedExecutor: { request in
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(300))
            return try ProductionStorage.capturedResponse(request)
        })
        let storage = try #require(model.storage)
        let store = EvaluationStore(supportDirectory: root)
        let data = try dataset(storage, root: root)
        let active = try storage.createCapturedJob(name: "Active batch", datasetRevision: data.revision)
        let older = try storage.createCapturedJob(name: "Older batch", datasetRevision: data.revision)
        model.jobs = [active, older]; model.selectedJobID = active.id; model.pane = .jobs
        try model.start(job: active, store: store, externalDisclosureApproved: false)
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        model.showResults(for: older.id)
        for _ in 0..<500 {
            if model.report?.job.id == older.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.refreshRunningProgress()
        #expect(model.runningJobID == active.id && model.selectedJobID == older.id)
        #expect(model.runningProgress?.planned == 1 && model.runningProgress?.completed == 0)
        #expect(model.report?.job.id == older.id)
        let cancellation = try #require(model.setControl(jobID: active.id, cancelled: true))
        await cancellation.value
        #expect(try storage.control(active).cancelled)
        #expect(try !storage.control(older).cancelled)
        #expect(model.selectedJobID == older.id)
        await model.closeAndWait()
    }
    /// Checks native artifacts must match saved identity, output and status, and absent latency remains unavailable.
    @Test func nativeDetailsRequireAnArtifactMatchingTheSavedResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-artifact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root)
        let storage = try #require(model.storage)
        let data = try dataset(storage, root: root)
        let job = try storage.createCapturedJob(name: "Evidence", datasetRevision: data.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "captured", operatingSystem: "fixture", hardware: "fixture", locale: "en", model: "original")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { try ProductionStorage.capturedResponse($0) }
        model.jobs = [job]; model.showResults(for: job.id)
        for _ in 0..<500 {
            if !model.records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var record = try #require(model.records.first)
        let result = EvaluationSampleResult(caseID: record.response.requestID, caseName: "Fixture", repetition: 1,
            prompt: "Question", expected: "Saved answer", response: record.response.output,
            status: .unscored, score: nil, rationale: nil, durationMilliseconds: 0, usage: .init(),
            judgeDurationMilliseconds: nil, judgeUsage: nil, errorCategory: nil, errorMessage: nil,
            judgeErrorCategory: nil, judgeErrorMessage: nil)
        var run = EvaluationRun(id: record.response.requestID, suiteID: UUID(), suiteName: "Fixture", suiteVersion: "1",
            instructions: "", criteria: "", scoringMode: .review, repetitions: 1, judgePromptVersion: nil,
            judgePassingScore: nil, plannedSampleCount: 1, suiteRevision: job.revision,
            startedAt: Date(), completedAt: Date(), cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test", locale: "en", model: "Fixture", modelContextSize: 1),
            attachments: [], results: [result])
        record.response.artifact = try ProductionCodec.encode(run)
        #expect(ProductionResultPresentation.nativeRun(record: record, job: job) != nil)
        #expect(ProductionResultPresentation.latency(record.response) == "Unavailable")
        run.results[0].response = "Unrelated output"
        record.response.artifact = try ProductionCodec.encode(run)
        #expect(ProductionResultPresentation.nativeRun(record: record, job: job) == nil)
        run.results[0].response = record.response.output; run.results[0].status = .passed
        record.response.artifact = try ProductionCodec.encode(run)
        #expect(ProductionResultPresentation.nativeRun(record: record, job: job) == nil)
        run.results[0].status = .unscored; run.id = UUID()
        record.response.artifact = try ProductionCodec.encode(run)
        #expect(ProductionResultPresentation.nativeRun(record: record, job: job) == nil)
    }

    /// Blocks a Jobs snapshot at the storage lock and verifies it cannot clear Results after a pane switch.
    @Test(.timeLimit(.minutes(1))) func refreshRejectsSnapshotsFromThePreviousPane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-pane-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root)
        let storage = try #require(model.storage)
        let data = try dataset(storage, root: root)
        let job = try storage.createCapturedJob(name: "Pane race", datasetRevision: data.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "captured", operatingSystem: "fixture", hardware: "fixture", locale: "en", model: "original")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { try ProductionStorage.capturedResponse($0) }
        model.jobs = [job]; model.selectedJobID = job.id; model.pane = .review
        await model.refresh()
        #expect(model.report?.completed == 1 && model.records.count == 1)
        let descriptor = open(root.appendingPathComponent("ProductionEvals/.store.lock").path, O_RDWR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        model.pane = .jobs; model.runningJobID = job.id
        let staleRefresh = Task { await model.refresh() }
        for _ in 0..<500 {
            if model.isLoading { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.isLoading)
        model.pane = .review
        _ = flock(descriptor, LOCK_UN)
        await staleRefresh.value
        #expect(model.report?.completed == 1 && model.records.count == 1)
        model.runningJobID = nil
    }

    /// Checks table outcomes follow reconciled evidence and review disagreement while raw records remain immutable.
    @Test func tableOutcomesFollowReconciliationAndDisagreement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-review-outcome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root)
        let storage = try #require(model.storage)
        let data = try dataset(storage, root: root)
        let job = try storage.createCapturedJob(name: "Reviewed", datasetRevision: data.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "captured", operatingSystem: "fixture", hardware: "fixture", locale: "en", model: "original")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) {
            .init(requestID: $0.requestID, outcome: .needsEvidence, explanation: "Interrupted fixture", cost: 0)
        }
        model.jobs = [job]; model.selectedJobID = job.id; model.pane = .review
        await model.refresh()
        let original = try #require(model.records.first)
        #expect(model.outcome(for: original) == .needsEvidence)
        let id = original.response.requestID
        try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "A", note: "Verify fixture evidence"))
        try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .reconcile, note: "Verified saved state", reconciledResponse: .init(requestID: id, outcome: .passed, output: "Verified", cost: 0)))
        await model.refresh()
        #expect(model.outcome(for: original) == .passed && model.report?.counts.passed == 1)
        #expect(model.records.first?.response.outcome == .needsEvidence)
        for (reviewer, outcome) in [("B", ProductionOutcome.failed), ("A", .passed)] {
            try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: reviewer, outcome: outcome, note: "Independent fixture assessment"))
        }
        await model.refresh()
        #expect(model.outcome(for: original) == .needsEvidence && model.report?.counts.uncertain == 1)
        #expect(model.records.first?.response.outcome == .needsEvidence)
    }

}
