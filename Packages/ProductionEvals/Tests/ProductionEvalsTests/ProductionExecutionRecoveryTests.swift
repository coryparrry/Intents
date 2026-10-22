import Dispatch
import Foundation
import Testing
@testable import ProductionEvals

private final class ExecutionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-execution-\(UUID())")
    let storage: ProductionStorage
    let worker = ProductionWorker(id: "execution-test", name: "Fixture", platform: "macOS", operatingSystem: "27", hardware: "fixture", locale: "en_GB", model: "fixture")
    init() throws { storage = try ProductionStorage(root: root) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func job(count: Int = 2, safety: ProductionReplaySafety = .inference, chunkSize: Int = 2) throws -> ProductionJob {
        let file = root.appendingPathComponent("examples.jsonl")
        var bytes = Data()
        for index in 0..<count {
            bytes.append(try ProductionCodec.encode(ProductionExample(id: String(index), prompt: "input")))
            bytes.append(10)
        }
        try bytes.write(to: file)
        let dataset = try storage.importDataset(from: file, name: "Fixture", version: "1", sampling: .curated, productionData: false, redactionConfirmed: false)
        let context = Data("execution-fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context), executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.timeoutSeconds = 0.1; config.maximumAttempts = 3
        config.chunkSize = chunkSize; config.replaySafety = safety
        return try storage.createJob(name: "Fixture", datasetRevision: dataset.revision, configuration: config)
    }
}

private actor ExecutionCalls {
    var started = 0
    var finished = 0
    func begin() { started += 1 }
    func end() { finished += 1 }
}

private func delayedResponse(_ request: ProductionRequest, calls: ExecutionCalls, seconds: Double) async -> ProductionResponse {
    await calls.begin()
    let response: ProductionResponse = await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume(returning: .init(requestID: request.requestID, outcome: .passed, output: "late answer", cost: 1))
        }
    }
    await calls.end()
    return response
}

@Suite(.serialized) struct ProductionExecutionRecoveryTests {
    @Test func deadlineReturnsBeforeNonCooperativeWorkAndPausesWithoutReplay() async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(), calls = ExecutionCalls()
        let start = ContinuousClock.now
        let count = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            await delayedResponse($0, calls: calls, seconds: 0.8)
        }
        #expect(start.duration(to: .now) < .seconds(0.6))
        #expect(count == 1)
        #expect(try fixture.storage.control(job).paused)
        #expect(await calls.started == 1)
        let record = try fixture.storage.record(jobID: job.id, slot: 0)
        #expect(record.response.outcome == .error && !record.response.retryable)
        #expect(record.response.explanation?.contains("deadline") == true)
        #expect(record.response.cost == nil)
        try await Task.sleep(for: .seconds(0.9))
        #expect(await calls.finished == 1)
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response == record.response)
        try fixture.storage.setControl(jobID: job.id, paused: false)
        let resumed = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            .init(requestID: $0.requestID, outcome: .passed, cost: 0)
        }
        #expect(resumed == 1)
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response == record.response)
    }

    @Test func timedOutSideEffectKeepsUncertainEvidenceAndNeverRetriesAutomatically() async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(safety: .sideEffects), calls = ExecutionCalls()
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            await delayedResponse($0, calls: calls, seconds: 0.3)
        }
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response.outcome == .needsEvidence)
        #expect(try fixture.storage.chunk(job, index: 0).attempts[0]?.number == 1)
        #expect(try fixture.storage.control(job).paused)
        try await Task.sleep(for: .seconds(0.35))
        #expect(await calls.started == 1)
        #expect(await calls.finished == 1)
    }

    @Test func cancellationReturnsBeforeNonCooperativeWorkAndRetainsItsAttempt() async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(), calls = ExecutionCalls()
        let task = Task {
            try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
                await delayedResponse($0, calls: calls, seconds: 0.8)
            }
        }
        while await calls.started == 0 { await Task.yield() }
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation must propagate") }
        catch is CancellationError { }
        #expect(start.duration(to: .now) < .seconds(0.6))
        #expect(try fixture.storage.control(job).paused)
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response.outcome == .error)
        try await Task.sleep(for: .seconds(0.9))
        #expect(await calls.finished == 1)
    }

    @Test func completedPrefixAdvancesWithoutSkippingPartialChunksAndRebuildsOnReload() async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(count: 6)
        let runner = ProductionBatchRunner(storage: fixture.storage)
        let execute: ProductionExecutor = { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, maximumResponses: 1, execute: execute) == 1)
        #expect(fixture.storage.claimStartIndex(job) == 0)
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, execute: execute) == 5)
        #expect(fixture.storage.claimStartIndex(job) == 3)
        let reopened = try ProductionStorage(root: fixture.root)
        #expect(reopened.claimStartIndex(job) == 0)
        #expect(try reopened.claim(job, worker: fixture.worker) == nil)
        #expect(reopened.claimStartIndex(job) == 3)
        #expect(try reopened.report(jobID: job.id).completed == 6)
    }
}
