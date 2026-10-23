import Foundation
import Testing
@testable import ProductionEvals

private final class ElapsedRecoveryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("production-elapsed-\(UUID())")
    let storage: ProductionStorage
    let job: ProductionJob
    let worker = ProductionWorker(id: "original", name: "Original", platform: "macOS", operatingSystem: "26",
                                  hardware: "original", locale: "en_GB", model: "fixture")

    init(safety: ProductionReplaySafety = .sideEffects, count: Int = 1, chunkSize: Int = 100) throws {
        storage = try ProductionStorage(root: directory.appendingPathComponent("store"))
        let input = directory.appendingPathComponent("input.jsonl")
        var data = Data()
        for slot in 0..<count {
            data.append(try ProductionCodec.encode(ProductionExample(id: String(slot), prompt: "input")))
            data.append(10)
        }
        try data.write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Recovery", version: "1", sampling: .random)
        let context = Data("fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.replaySafety = safety; config.chunkSize = chunkSize; config.maximumAttempts = 2
        config.maximumElapsedSeconds = 60; config.targets = [.init(platform: "macOS")]
        job = try storage.createJob(name: "Recovery", datasetRevision: dataset.revision, configuration: config)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func setStartedAt(_ date: Date) throws {
        var control = try storage.control(job); control.startedAt = date
        try ProductionCodec.write(control, to: storage.jobDirectory(job.id).appendingPathComponent("control.json"))
    }

    func interrupt(slot: Int = 0, number: Int = 1, leased: Bool = false) throws {
        let index = slot / job.configuration.chunkSize
        var chunk = try storage.chunk(job, index: index)
        var attempt = ProductionAttempt(requestID: storage.requestID(job, slot: slot), number: number,
            startedAt: Date().addingTimeInterval(-120), worker: worker)
        attempt.reportedCost = 0.4; attempt.hasUnknownCost = false
        chunk.attempts[slot] = attempt
        chunk.lease = .init(token: UUID(), workerID: worker.id,
                            expiresAt: Date().addingTimeInterval(leased ? 300 : -1))
        try ProductionCodec.write(chunk, to: storage.chunkURL(job, index))
    }

    func run(worker: ProductionWorker? = nil) async throws -> Int {
        try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker ?? self.worker) { request in
            Issue.record("Elapsed recovery unexpectedly executed slot \(request.slot)")
            return .init(requestID: request.requestID, outcome: .passed, cost: 0)
        }
    }
}

@Suite(.serialized) struct ProductionElapsedRecoveryTests {
    // Layout 0 has only interrupted work; 1 has an earlier fresh slot in the same
    // chunk; 2 has an earlier fresh chunk. Both mixed layouts must terminate.
    @Test(arguments: [ProductionReplaySafety.sideEffects, .inference], [0, 1, 2])
    func expiredBudgetStillFinalizesInterruptedEvidence(safety: ProductionReplaySafety, layout: Int) async throws {
        let mixed = layout != 0, slot = mixed ? 1 : 0
        let fixture = try ElapsedRecoveryFixture(safety: safety, count: mixed ? 2 : 1, chunkSize: layout == 2 ? 1 : 100)
        let number = safety == .sideEffects ? 1 : fixture.job.configuration.maximumAttempts
        try fixture.interrupt(slot: slot, number: number)
        try fixture.setStartedAt(Date().addingTimeInterval(-120))
        var resuming = fixture.worker; resuming.id = "resuming"; resuming.hardware = "different"
        do {
            let count = try await fixture.run(worker: resuming)
            #expect(!mixed && count == 1)
        } catch let error as ProductionFailure {
            guard case .budget = error, mixed else { throw error }
        }
        let record = try fixture.storage.record(jobID: fixture.job.id, slot: slot)
        #expect(record.worker.id == fixture.worker.id && record.worker.hardware == fixture.worker.hardware)
        #expect(record.attempt == number && record.response.cost == 0.4)
        #expect(record.response.outcome == (safety == .sideEffects ? .needsEvidence : .error))
        #expect(try fixture.storage.chunk(fixture.job, index: slot / fixture.job.configuration.chunkSize).lease == nil)
        if mixed { #expect(try fixture.storage.chunk(fixture.job, index: 0).records[0] == nil) }
        if safety == .sideEffects {
            let id = record.response.requestID
            try fixture.storage.appendReview(jobID: fixture.job.id, slot: slot,
                event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "A", note: "Verify action"))
            try fixture.storage.appendReview(jobID: fixture.job.id, slot: slot,
                event: .init(requestID: id, reviewer: "A", action: .reconcile, note: "Verified persisted state",
                    reconciledResponse: .init(requestID: id, outcome: .passed, cost: 0.4)))
            #expect(try fixture.storage.review(jobID: fixture.job.id, requestID: id).response?.outcome == .passed)
        }
    }

    @Test(arguments: [false, true])
    func expiredBudgetNeverAdmitsFreshOrRetryableInference(interrupted: Bool) async throws {
        let fixture = try ElapsedRecoveryFixture(safety: .inference)
        if interrupted { try fixture.interrupt() }
        try fixture.setStartedAt(Date().addingTimeInterval(-120))
        await #expect(throws: ProductionFailure.self) { try await fixture.run() }
        #expect(try fixture.storage.chunk(fixture.job, index: 0).records.isEmpty)
    }

    @Test(arguments: ["paused", "cancelled", "foreign-worker", "leased"])
    func expiredRecoveryPreservesControlMatchingAndLeaseGuards(guardName: String) async throws {
        let fixture = try ElapsedRecoveryFixture()
        try fixture.interrupt(leased: guardName == "leased")
        try fixture.setStartedAt(Date().addingTimeInterval(-120))
        if guardName == "paused" { try fixture.storage.setControl(jobID: fixture.job.id, paused: true) }
        if guardName == "cancelled" { try fixture.storage.setControl(jobID: fixture.job.id, cancelled: true) }
        var worker = fixture.worker
        if guardName == "foreign-worker" { worker.platform = "iOS" }
        #expect(try await fixture.run(worker: worker) == 0)
        #expect(try fixture.storage.chunk(fixture.job, index: 0).records.isEmpty)
    }

    @Test func activeBudgetStillFinalizesInterruptedSideEffectWithoutExecution() async throws {
        let fixture = try ElapsedRecoveryFixture()
        try fixture.interrupt()
        try fixture.setStartedAt(Date())
        #expect(try await fixture.run() == 1)
        #expect(try fixture.storage.record(jobID: fixture.job.id, slot: 0).response.outcome == .needsEvidence)
    }
}
