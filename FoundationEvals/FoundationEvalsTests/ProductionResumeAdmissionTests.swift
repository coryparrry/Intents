import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct ProductionResumeAdmissionTests {
    @Test(arguments: ["externalDisclosure", "unsupportedBackend", "busyEvaluation"])
    func rejectedResumeKeepsPausedJobPaused(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "resume-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let production = ProductionWorkspaceStore(root: root)
        let storage = try #require(production.storage)
        var suite = EvaluationSuite()
        if reason == "externalDisclosure" {
            suite.judgeConfiguration = .init(mode: .connection, connectionID: UUID())
        } else {
            suite.scoringMode = .review
        }
        let context = NativeProductionContext(suite: suite, images: [])
        let encoded = reason == "unsupportedBackend" ? Data(#"{"kind":"command-worker-fixture"}"#.utf8)
            : try ProductionCodec.encode(context)
        let job = try makeJob(storage: storage, root: root, context: encoded)
        try storage.setControl(jobID: job.id, paused: true)
        let before = try storage.controlRevision(job)
        let existingOwner = reason == "busyEvaluation"
            ? try evaluation.beginProductionExecution(context, externalDisclosureApproved: false).0 : nil
        defer { if let existingOwner { evaluation.endProductionExecution(existingOwner) } }
        await production.resume(job: job, store: evaluation, externalDisclosureApproved: false).value
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while production.runningJobID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(production.error != nil)
        #expect(production.runningJobID == nil)
        #expect(try storage.control(job).paused)
        #expect(try storage.controlRevision(job) == before)
        #expect(try storage.report(jobID: job.id).completed == 0)
        await production.closeAndWait()
    }

    @Test func failedUnpauseReleasesExecutionAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "resume-storage-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let production = ProductionWorkspaceStore(root: root)
        let storage = try #require(production.storage)
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        let context = try ProductionCodec.encode(NativeProductionContext(suite: suite, images: []))
        let job = try makeJob(storage: storage, root: root, context: context)
        try FileManager.default.removeItem(at: root.appending(path: "ProductionEvals/Jobs/\(job.id.uuidString)/control.json"))
        await production.resume(job: job, store: evaluation, externalDisclosureApproved: false).value
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while production.runningJobID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(production.error != nil)
        #expect(production.runningJobID == nil)
        _ = try evaluation.productionSnapshot()
        await production.closeAndWait()
    }

    private func makeJob(storage: ProductionStorage, root: URL, context: Data) throws -> ProductionJob {
        let source = root.appending(path: "examples.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "one", prompt: "Fixture"))
        bytes.append(10)
        try bytes.write(to: source)
        let dataset = try storage.importDataset(from: source, name: "Resume fixture", version: "1")
        let config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(Data("score".utf8)),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        return try storage.createJob(name: "Resume fixture", datasetRevision: dataset.revision, configuration: config)
    }
}
