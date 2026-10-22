import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct ProductionReviewEvidenceTests {
    @Test(arguments: [false, true])
    func reconciliationPreservesLatencyAvailability(latencyAvailable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "production-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionWorkspaceStore(root: root)
        let storage = try #require(store.storage)
        let source = root.appending(path: "examples.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "saved", prompt: "Input"))
        bytes.append(10)
        try bytes.write(to: source)
        let dataset = try storage.importDataset(from: source, name: "Review fixture", version: "1")
        let context = Data("review-fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.replaySafety = .sideEffects
        config.gate.maximumAverageMilliseconds = 100
        config.gate.maximumP95Milliseconds = 100
        let job = try storage.createJob(name: "Review fixture", datasetRevision: dataset.revision, configuration: config)
        let worker = ProductionWorker(id: "review", name: "Fixture", platform: "macOS",
            operatingSystem: "27", hardware: "fixture", locale: "en_GB", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) {
            .init(requestID: $0.requestID, outcome: .needsEvidence, output: "Retained output",
                latencyMilliseconds: 73, latencyAvailable: latencyAvailable, cost: 0)
        }
        let record = try storage.record(jobID: job.id, slot: 0)
        try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: record.response.requestID,
            reviewer: "Reviewer", action: .assign, assignee: "Reviewer", note: "Verify saved state"))
        store.selectedJobID = job.id
        store.selectedRecord = record
        store.appendReview(action: .reconcile, reviewer: "Reviewer", assignee: "", outcome: .passed,
            note: "Verified saved state", tags: "", verifiedOutput: "Verified output", verifiedCost: 0)
        await store.closeAndWait()
        #expect(store.error == nil)
        let review = try storage.review(jobID: job.id, requestID: record.response.requestID)
        #expect(review.response?.latencyAvailable == latencyAvailable)
        #expect(review.response?.latencyMilliseconds == 73)
        let report = try storage.report(jobID: job.id)
        #expect(report.exitCode == (latencyAvailable ? 0 : 20))
        #expect(report.averageMilliseconds == (latencyAvailable ? 73 : nil))
        #expect(try storage.record(jobID: job.id, slot: 0) == record)
    }
}
