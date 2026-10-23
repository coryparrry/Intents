import Foundation
import Synchronization
import Testing
@testable import ProductionEvals

private final class CommitCounter: Sendable {
    let value = Mutex(0)
}

private final class CommitProgressFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("production-progress-\(UUID())")
    let storage: ProductionStorage
    let job: ProductionJob
    let worker = ProductionWorker(id: "progress", name: "Progress", platform: "macOS", operatingSystem: "26",
                                  hardware: "fixture", locale: "en_GB", model: "fixture")

    init(count: Int = 2, costCap: Double? = nil, allowance: Double = 1) throws {
        storage = try ProductionStorage(root: directory.appendingPathComponent("store"))
        let input = directory.appendingPathComponent("input.jsonl")
        var data = Data()
        for slot in 0..<count {
            data.append(try ProductionCodec.encode(ProductionExample(id: String(slot), prompt: "input")))
            data.append(10)
        }
        try data.write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Progress", version: "1", sampling: .random)
        let context = Data("fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.replaySafety = .inference
        config.maximumCost = costCap
        if costCap != nil { config.maximumCostPerAttempt = allowance }
        job = try storage.createJob(name: "Progress", datasetRevision: dataset.revision, configuration: config)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) struct ProductionCommitProgressTests {
    @Test func successfulAndResumedRunsNotifyOnlyTheirNewCommits() async throws {
        let fixture = try CommitProgressFixture(), first = CommitCounter(), resumed = CommitCounter()
        let runner = ProductionBatchRunner(storage: fixture.storage)
        let initial = try await runner.run(jobID: fixture.job.id, worker: fixture.worker, maximumResponses: 1,
            onCommit: { first.value.withLock { $0 += 1 } }) {
                .init(requestID: $0.requestID, outcome: .passed, cost: 1)
            }
        #expect(initial == 1 && first.value.withLock { $0 } == 1)
        let remaining = try await runner.run(jobID: fixture.job.id, worker: fixture.worker,
            onCommit: { resumed.value.withLock { $0 += 1 } }) {
                .init(requestID: $0.requestID, outcome: .passed, cost: 1)
            }
        #expect(remaining == 1 && resumed.value.withLock { $0 } == 1)
        #expect(try fixture.storage.report(jobID: fixture.job.id).completed == 2)
    }

    @Test func partialBudgetFailurePreservesProgressAndOriginalError() async throws {
        let fixture = try CommitProgressFixture(costCap: 1), progress = CommitCounter(), calls = CommitCounter()
        do {
            _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: fixture.job.id, worker: fixture.worker,
                onCommit: { progress.value.withLock { $0 += 1 } }) { request in
                    calls.value.withLock { $0 += 1 }
                    return .init(requestID: request.requestID, outcome: .passed, cost: 1)
                }
            Issue.record("The second attempt should exhaust the cost budget")
        } catch let error as ProductionFailure {
            guard case .budget = error else { throw error }
        }
        #expect(progress.value.withLock { $0 } == 1 && calls.value.withLock { $0 } == 1)
        #expect(try fixture.storage.report(jobID: fixture.job.id).completed == 1)
    }

    @Test func failureBeforeAnyCommitDoesNotNotify() async throws {
        let fixture = try CommitProgressFixture(costCap: 1, allowance: 2), progress = CommitCounter()
        do {
            _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: fixture.job.id, worker: fixture.worker,
                onCommit: { progress.value.withLock { $0 += 1 } }) { request in
                    Issue.record("The initial reservation must prevent execution")
                    return .init(requestID: request.requestID, outcome: .passed, cost: 1)
                }
            Issue.record("The initial reservation should exceed the cost budget")
        } catch let error as ProductionFailure {
            guard case .budget = error else { throw error }
        }
        #expect(progress.value.withLock { $0 } == 0)
        #expect(try fixture.storage.chunk(fixture.job, index: 0).records.isEmpty)
    }

    @Test func bookkeepingFailureAfterRecordStillNotifiesExactlyOnce() async throws {
        let fixture = try CommitProgressFixture(count: 1), progress = CommitCounter()
        let workers = fixture.storage.root.appendingPathComponent("Workers")
        let savedWorkers = fixture.storage.root.appendingPathComponent("Workers-before-failure")
        do {
            _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: fixture.job.id, worker: fixture.worker,
                onCommit: { progress.value.withLock { $0 += 1 } }) { request in
                    // Initial registration already succeeded. Only post-response worker
                    // registration uses this path; record/attempt journals remain writable.
                    try FileManager.default.moveItem(at: workers, to: savedWorkers)
                    try Data("not a directory".utf8).write(to: workers)
                    return .init(requestID: request.requestID, outcome: .passed, cost: 1)
                }
            Issue.record("Post-record worker registration should fail")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
        }
        #expect(progress.value.withLock { $0 } == 1)
        #expect(try fixture.storage.record(jobID: fixture.job.id, slot: 0).response.outcome == .passed)
        #expect(try fixture.storage.chunk(fixture.job, index: 0).lease == nil)
    }
}
