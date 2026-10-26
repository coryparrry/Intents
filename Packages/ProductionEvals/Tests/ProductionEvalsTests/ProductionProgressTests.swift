import Foundation
import Testing
@testable import ProductionEvals

struct ProductionProgressTests {
    /// Checks durable progress through partial execution, resume, completed pause, cancellation and malformed slot rejection.
    @Test func pollingMatchesDurableCountsAcrossPartialResumeAndControlChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-counts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ProductionStorage(root: root)
        let input = root.appendingPathComponent("input.jsonl")
        try Data((0..<3).map { "{\"id\":\"\($0)\",\"prompt\":\"hello\"}\n" }.joined().utf8).write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Progress", version: "1")
        let context = Data("fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context), executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.chunkSize = 2
        let job = try storage.createJob(name: "Progress", datasetRevision: dataset.revision, configuration: config)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "27", hardware: "fixture", locale: "en", model: "fixture")
        #expect(try storage.progress(jobID: job.id).completed == 0)
        let runner = ProductionBatchRunner(storage: storage)
        _ = try await runner.run(jobID: job.id, worker: worker, maximumResponses: 1) { .init(requestID: $0.requestID, outcome: .passed, output: "saved", cost: 0) }
        #expect(try storage.progress(jobID: job.id).completed == 1)
        #expect(try storage.report(jobID: job.id).completed == 1)
        try storage.setControl(jobID: job.id, paused: true)
        #expect(try storage.progress(jobID: job.id).phase == "paused")
        try storage.setControl(jobID: job.id, paused: false)
        _ = try await runner.run(jobID: job.id, worker: worker) { .init(requestID: $0.requestID, outcome: .passed, output: "saved", cost: 0) }
        let progress = try storage.progress(jobID: job.id)
        #expect(progress.completed == 3 && progress.planned == 3 && progress.phase == "completed")
        #expect(try storage.report(jobID: job.id).completed == progress.completed)
        try storage.setControl(jobID: job.id, paused: true)
        #expect(try storage.progress(jobID: job.id).phase == "paused")
        #expect(try storage.progress(jobID: job.id).phase == storage.report(jobID: job.id).phase)
        try storage.setControl(jobID: job.id, cancelled: true)
        #expect(try storage.progress(jobID: job.id).phase == "cancelled")
        // Lightweight counts must still reject malformed or out-of-range slot identities.
        var chunk = try storage.chunk(job, index: 0)
        chunk.records[0]?.slot = 99
        try ProductionCodec.write(chunk, to: storage.chunkURL(job, 0))
        #expect(throws: (any Error).self) { try storage.progress(jobID: job.id) }
    }
}
