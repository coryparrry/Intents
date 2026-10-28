import Foundation
import Testing
@testable import ProductionEvals

private final class ExecutionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-execution-\(UUID())")
    let storage: ProductionStorage
    let worker = ProductionWorker(id: "execution-test", name: "Fixture", platform: "macOS", operatingSystem: "27", hardware: "fixture", locale: "en_GB", model: "fixture")
    init() throws { storage = try ProductionStorage(root: root) }
    deinit { try? FileManager.default.removeItem(at: root) }
    /// Creates isolated jobs with a short deadline by default; cancellation cases can avoid racing that separate mechanism.
    func job(count: Int = 2, safety: ProductionReplaySafety = .inference, chunkSize: Int = 2, timeoutSeconds: Double = 0.1) throws -> ProductionJob {
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
        config.timeoutSeconds = timeoutSeconds; config.maximumAttempts = 3
        config.chunkSize = chunkSize; config.replaySafety = safety
        return try storage.createJob(name: "Fixture", datasetRevision: dataset.revision, configuration: config)
    }
}

private actor ExecutionCalls {
    var started = 0
    var finished = 0
    var returned = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func end() { finished += 1 }
    func didReturn() { returned = true }
}

private func gatedResponse(_ request: ProductionRequest, calls: ExecutionCalls) async -> ProductionResponse {
    // This continuation deliberately ignores cancellation until the test releases it.
    await calls.waitForRelease()
    await calls.end()
    return .init(requestID: request.requestID, outcome: .passed, output: "late answer", cost: 1)
}

private func waitForExecution(_ condition: () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite(.serialized) struct ProductionExecutionRecoveryTests {
    @Test(arguments: [ProductionReplaySafety.inference, .sideEffects])
    func deadlineReturnsBeforeNonCooperativeWorkAndPausesWithoutReplay(safety: ProductionReplaySafety) async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(safety: safety), calls = ExecutionCalls()
        let task = Task {
            do {
                let count = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
                    await gatedResponse($0, calls: calls)
                }
                await calls.didReturn()
                return count
            } catch { await calls.didReturn(); throw error }
        }
        let returnedWhileWorkWasBlocked = try await waitForExecution { await calls.returned }
        let finishedBeforeRelease = await calls.finished
        await calls.release() // Always unblock the worker, including a regressed runner.
        let count = try await task.value
        #expect(returnedWhileWorkWasBlocked, "The request deadline must return without waiting for the executor.")
        #expect(finishedBeforeRelease == 0)
        #expect(count == 1)
        #expect(try fixture.storage.control(job).paused)
        #expect(await calls.started == 1)
        let record = try fixture.storage.record(jobID: job.id, slot: 0)
        #expect(record.response.outcome == (safety == .sideEffects ? .needsEvidence : .error))
        #expect(!record.response.retryable)
        #expect(record.response.explanation?.contains("deadline") == true)
        #expect(record.response.cost == nil)
        #expect(try fixture.storage.chunk(job, index: 0).attempts[0]?.number == 1)
        #expect(try await waitForExecution { await calls.finished == 1 })
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response == record.response)
        try fixture.storage.setControl(jobID: job.id, paused: false)
        let resumed = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            .init(requestID: $0.requestID, outcome: .passed, cost: 0)
        }
        #expect(resumed == 1)
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response == record.response)
    }

    /// Keeps the request deadline outside this bounded cancellation check so a loaded executor cannot win by timing out first.
    @Test func cancellationReturnsBeforeNonCooperativeWorkAndRetainsItsAttempt() async throws {
        let fixture = try ExecutionFixture(), job = try fixture.job(timeoutSeconds: 60), calls = ExecutionCalls()
        let task = Task {
            do {
                let count = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
                    await gatedResponse($0, calls: calls)
                }
                await calls.didReturn()
                return count
            } catch { await calls.didReturn(); throw error }
        }
        let started = try await waitForExecution { await calls.started == 1 }
        task.cancel()
        let returnedWhileWorkWasBlocked = try await waitForExecution { await calls.returned }
        let finishedBeforeRelease = await calls.finished
        await calls.release()
        do { _ = try await task.value; Issue.record("Cancellation must propagate") }
        catch is CancellationError { }
        #expect(started)
        #expect(returnedWhileWorkWasBlocked, "Cancellation must return without waiting for the executor.")
        #expect(finishedBeforeRelease == 0)
        #expect(try fixture.storage.control(job).paused)
        #expect(try fixture.storage.record(jobID: job.id, slot: 0).response.outcome == .error)
        #expect(try await waitForExecution { await calls.finished == 1 })
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
