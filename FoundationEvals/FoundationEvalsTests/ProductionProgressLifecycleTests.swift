import Foundation
import Testing
@testable import FoundationEvals

/// Checks worker completion clears execution state before refreshing the full report and saved results.
@MainActor struct ProductionProgressLifecycleTests {
    @Test(.timeLimit(.minutes(1))) func completedJobsAutomaticallyReceiveTheFullAudit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root)
        let storage = try #require(model.storage)
        let store = EvaluationStore(supportDirectory: root)
        let input = root.appendingPathComponent("input.jsonl")
        try Data("{\"id\":\"case\",\"prompt\":\"hello\",\"capturedOutput\":\"saved\"}\n".utf8).write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Lifecycle", version: "1")
        let job = try storage.createCapturedJob(name: "Lifecycle", datasetRevision: dataset.revision)
        model.jobs = [job]; model.selectedJobID = job.id; model.pane = .jobs
        try model.start(job: job, store: store, externalDisclosureApproved: false)
        for _ in 0..<500 {
            if model.runningJobID == nil && model.report?.completed == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.runningJobID == nil)
        #expect(model.progress == nil)
        #expect(model.report?.completed == 1)
        #expect(model.records.count == 1)
        #expect(model.report?.evidenceRevision?.isEmpty == false)
    }
}
