import Foundation
import Darwin
import Testing
@testable import FoundationEvals

@MainActor
struct ProductionWorkspaceStoreTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func pauseInterruptsOnlyAfterControlPersistence(failPersistence: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-pause-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ProductionStorage(root: root.appendingPathComponent("ProductionEvals"))
        let entered = AsyncStream<Void>.makeStream(), cancellations = ProductionCancellationObservations()
        let model = ProductionWorkspaceStore(root: root, capturedExecutor: { request in
            try await withTaskCancellationHandler {
                entered.continuation.yield(())
                try await Task.sleep(for: .seconds(300))
                return try ProductionStorage.capturedResponse(request)
            } onCancel: {
                let paused = (try? storage.control(storage.loadJob(request.jobID)).paused) ?? false
                cancellations.append(paused)
            }
        })
        let store = EvaluationStore(supportDirectory: root)
        let dataset = try dataset(storage: storage, root: root)
        let job = try storage.createCapturedJob(name: "Running", datasetRevision: dataset.revision)
        model.jobs = [job]; model.selectedJobID = job.id
        defer { model.interrupt(jobID: job.id); entered.continuation.finish() }
        try model.start(job: job, store: store, externalDisclosureApproved: false)
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let controlFile = storage.jobDirectory(job.id).appendingPathComponent("control.json")
        let retainedControl = root.appendingPathComponent("retained-control.json")
        if failPersistence {
            try FileManager.default.moveItem(at: controlFile, to: retainedControl)
            try FileManager.default.createDirectory(at: controlFile, withIntermediateDirectories: false)
        }
        let update = try #require(model.setControl(paused: true))
        await update.value
        if failPersistence {
            #expect(cancellations.values.isEmpty)
            #expect(model.runningJobID == job.id && model.error != nil)
            try FileManager.default.removeItem(at: controlFile)
            try FileManager.default.moveItem(at: retainedControl, to: controlFile)
            #expect(try storage.control(job).paused == false)
        } else {
            #expect(cancellations.values == [true])
            #expect(try storage.control(job).paused)
        }
        await model.closeAndWait()
    }

    @Test(.timeLimit(.minutes(1)))
    func staleRefreshAndRecordReadsCannotPublishIntoAnotherSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-read-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root), storage = try #require(model.storage)
        let dataset = try dataset(storage: storage, root: root)
        let first = try storage.createCapturedJob(name: "First", datasetRevision: dataset.revision)
        let second = try storage.createCapturedJob(name: "Second", datasetRevision: dataset.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "26", hardware: "Fixture", locale: "en_GB", model: "fixture")
        for job in [first, second] {
            _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, execute: ProductionStorage.capturedResponse)
        }
        let firstRecord = try storage.record(jobID: first.id, slot: 0)
        let secondRecord = try storage.record(jobID: second.id, slot: 0)
        model.jobs = [first, second]; model.selectedJobID = first.id
        // Both report and review use the real storage lock. Hold it so the old
        // request cannot finish until after its selection has been superseded.
        let refreshLock = try ProductionTestStoreLock(root: storage.root)
        defer { refreshLock.release() }
        let refreshing = Task { await model.refresh() }
        while !model.isLoading { await Task.yield() }
        model.selectedJobID = second.id
        refreshLock.release()
        await refreshing.value
        #expect(model.report == nil && model.records.isEmpty && !model.isLoading)

        model.selectedJobID = first.id
        let detailLock = try ProductionTestStoreLock(root: storage.root)
        defer { detailLock.release() }
        let reading = try #require(model.selectRecord(firstRecord))
        model.selectedJobID = second.id; model.selectedRecord = secondRecord
        model.selectedExample = .init(id: "current", prompt: "Current selection")
        detailLock.release()
        await reading.value
        #expect(model.selectedRecord?.response.requestID == secondRecord.response.requestID)
        #expect(model.selectedExample?.id == "current" && model.review == nil && model.error == nil)
        await model.closeAndWait()
    }

    @Test func customSubjectCostsCannotBeReportedAsFreeOrAsOnlyJudgeCost() {
        var suite = EvaluationSuite()
        let judgeCost = EvaluationCost(availability: .known, usd: 0.25, explanation: "Known judge charge")
        #expect(NativeProductionContext(suite: suite, images: []).reportedCost(judgeCost: nil) == 0)
        suite.judgeConfiguration.mode = .connection
        #expect(NativeProductionContext(suite: suite, images: []).reportedCost(judgeCost: judgeCost) == 0.25)
        #expect(NativeProductionContext(suite: suite, images: []).reportedCost(judgeCost: nil) == nil)
        suite.modelConfiguration.provider = .customHTTP
        #expect(NativeProductionContext(suite: suite, images: []).reportedCost(judgeCost: judgeCost) == nil)
        suite.judgeConfiguration.mode = .sameModel
        #expect(NativeProductionContext(suite: suite, images: []).reportedCost(judgeCost: nil) == nil)
    }

    private func dataset(storage: ProductionStorage, root: URL) throws -> ProductionDataset {
        let file = root.appendingPathComponent("input.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "a", prompt: "Input", capturedOutput: "Original"))
        bytes.append(10)
        try bytes.write(to: file)
        return try storage.importDataset(from: file, name: "Fixture", version: "v1")
    }

    @Test(arguments: ["unsupported", "disclosure", "captured-target", "native-target"])
    func rejectedResumePreservesPauseAndReleasesAdmission(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root), store = EvaluationStore(supportDirectory: root)
        let storage = try #require(model.storage)
        let dataset = try dataset(storage: storage, root: root)
        let template = try storage.createCapturedJob(name: "Template", datasetRevision: dataset.revision)
        var configuration = template.configuration
        if reason == "unsupported" {
            configuration.executionContext = Data(#"{"kind":"command"}"#.utf8)
        } else if reason == "disclosure" || reason == "native-target" {
            var suite = store.draftSuite
            if reason == "disclosure" { suite.judgeConfiguration.mode = .connection }
            configuration.executionContext = try ProductionCodec.encode(NativeProductionContext(suite: suite, images: []))
        }
        configuration.executionRevision = ProductionCodec.digest(configuration.executionContext)
        if reason.hasSuffix("target") { configuration.targets = [.init(platform: "unavailable-platform")] }
        let job = try storage.createJob(name: "Rejected admission", datasetRevision: dataset.revision, configuration: configuration)
        try storage.setControl(jobID: job.id, paused: true)
        let before = try storage.control(job)
        await model.resume(job: job, store: store, externalDisclosureApproved: false).value
        let after = try storage.control(job)
        #expect(after.paused && after.evidenceMutationID == before.evidenceMutationID)
        #expect(model.runningJobID == nil && model.error != nil)
        #expect(!store.hasActiveExecution)
        #expect(try storage.records(jobID: job.id).isEmpty)
        await model.closeAndWait()
    }

    @Test func selectingAnotherBatchClearsPriorEvidenceAndRejectsForeignRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root), storage = try #require(model.storage)
        let dataset = try dataset(storage: storage, root: root)
        let first = try storage.createCapturedJob(name: "First", datasetRevision: dataset.revision)
        let second = try storage.createCapturedJob(name: "Second", datasetRevision: dataset.revision)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "26", hardware: "Fixture", locale: "en_GB", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: first.id, worker: worker, execute: ProductionStorage.capturedResponse)
        let record = try storage.record(jobID: first.id, slot: 0)
        model.jobs = [first, second]; model.selectedJobID = first.id
        model.records = [record]; model.selectedRecord = record
        model.selectedExample = .init(id: "a", prompt: "Prior prompt")
        model.report = try storage.report(jobID: first.id)
        model.review = try storage.review(jobID: first.id, requestID: record.response.requestID)
        model.select(second.id)
        #expect(model.records.isEmpty && model.selectedRecord == nil && model.selectedExample == nil)
        #expect(model.report == nil && model.review == nil)
        model.selectRecord(record)
        #expect(model.selectedRecord == nil && model.error != nil)
        await model.closeAndWait()
    }

    @Test func reconciliationPreservesUnavailableLatencyEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root), storage = try #require(model.storage)
        let dataset = try dataset(storage: storage, root: root)
        let template = try storage.createCapturedJob(name: "Template", datasetRevision: dataset.revision)
        var configuration = template.configuration
        configuration.gate.maximumAverageMilliseconds = 100
        let job = try storage.createJob(name: "Unavailable latency", datasetRevision: dataset.revision, configuration: configuration)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "26", hardware: "Fixture", locale: "en_GB", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) {
            .init(requestID: $0.requestID, outcome: .needsEvidence, latencyAvailable: false, cost: 0)
        }
        let record = try storage.record(jobID: job.id, slot: 0)
        try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: record.response.requestID,
            reviewer: "Reviewer", action: .assign, assignee: "Reviewer", note: "Verify result"))
        model.jobs = [job]; model.selectedJobID = job.id; model.selectedRecord = record
        model.appendReview(action: .reconcile, reviewer: "Reviewer", assignee: "", outcome: .passed,
            note: "Verified persisted output", tags: "", verifiedOutput: "Verified", verifiedCost: 0)
        await model.closeAndWait()
        let review = try storage.review(jobID: job.id, requestID: record.response.requestID)
        #expect(review.response?.latencyAvailable == false)
        let report = try storage.report(jobID: job.id)
        #expect(report.counts.passed == 1 && report.exitCode == 20)
        #expect(report.issues.contains("Required latency evidence is unavailable."))
    }

    @Test(arguments: [false, true])
    func schedulePauseNeverOverwritesWorkerAdvancement(advanced: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-schedule-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProductionWorkspaceStore(root: root), storage = try #require(model.storage)
        let dataset = try dataset(storage: storage, root: root)
        let job = try storage.createCapturedJob(name: "Template", datasetRevision: dataset.revision)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = ProductionSchedule(templateJobID: job.id, intervalSeconds: 60, nextRun: now, remainingRuns: 2)
        try storage.saveSchedule(schedule)
        if advanced { #expect(try storage.tickSchedules(now: now).count == 1) }
        model.setSchedulePaused(schedule, paused: true)
        await model.closeAndWait()
        let persisted = try #require(storage.schedules().first)
        #expect(persisted.paused == !advanced)
        #expect(persisted.remainingRuns == (advanced ? 1 : 2))
        #expect(persisted.nextRun == (advanced ? now.addingTimeInterval(60) : now))
        #expect((model.error != nil) == advanced)
    }
}

private final class ProductionCancellationObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    func append(_ paused: Bool) { lock.lock(); defer { lock.unlock() }; observations.append(paused) }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return observations }
}

private final class ProductionTestStoreLock {
    private var descriptor: Int32
    init(root: URL) throws {
        descriptor = Darwin.open(root.appendingPathComponent(".store.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX) == 0 else { Darwin.close(descriptor); descriptor = -1; throw POSIXError(.EIO) }
    }
    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1
    }
    deinit { release() }
}
