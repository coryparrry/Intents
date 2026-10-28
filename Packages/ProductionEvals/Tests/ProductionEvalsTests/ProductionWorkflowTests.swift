import Foundation
import Testing
@testable import ProductionEvals

private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("production-test-\(UUID().uuidString)")
    let storage: ProductionStorage
    init() throws { storage = try ProductionStorage(root: directory.appendingPathComponent("store")) }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func dataset(_ examples: [ProductionExample], production: Bool = false, confirmed: Bool = false) throws -> ProductionDataset {
        let file = directory.appendingPathComponent("input-\(UUID()).jsonl")
        var data = Data(); for example in examples { data.append(try ProductionCodec.encode(example)); data.append(10) }
        try data.write(to: file)
        return try storage.importDataset(from: file, name: "Fixture", version: "v1", sampling: .random, productionData: production, redactionConfirmed: confirmed)
    }
    func job(_ dataset: ProductionDataset, repetitions: Int = 1, safety: ProductionReplaySafety = .inference,
             targets: [ProductionTarget] = [.init()], budget: Bool = false) throws -> ProductionJob {
        let context = Data("fixture-v1".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(Data("score-v1".utf8)), executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.repetitions = repetitions; config.replaySafety = safety; config.targets = targets
        if budget { config.maximumCost = 100; config.maximumCostPerAttempt = 1 }
        return try storage.createJob(name: "Fixture job", datasetRevision: dataset.revision, configuration: config)
    }
    var worker: ProductionWorker { .init(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "26.0", hardware: "fixture", locale: "en_GB", model: "fixture-model") }
}
private actor Calls {
    var ids = Set<UUID>(); var count = 0
    func record(_ id: UUID) -> Bool { count += 1; return ids.insert(id).inserted }
    func total() -> Int { count }
}

@Suite(.serialized) struct ProductionWorkflowTests {

    @Test func baselineApprovalRequiresEligibleUnchangedEvidence() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        var config = try fixture.job(dataset).configuration
        config.gate.requireBaseline = true
        let baseline = try fixture.storage.createJob(name: "Baseline", datasetRevision: dataset.revision, configuration: config)
        #expect(throws: ProductionFailure.self) {
            try fixture.storage.approveBaseline(jobID: baseline.id, expectedJobRevision: baseline.revision, expectedEvidenceRevision: "stale", note: "reviewed")
        }
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: baseline.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        // A first baseline can be approved without manufacturing a predecessor comparison.
        let before = try fixture.storage.report(jobID: baseline.id)
        #expect(before.exitCode == 20 && before.baselineEligible == true && before.baselineApproval == nil)
        config.baselineJobID = baseline.id
        let candidate = try fixture.storage.createJob(name: "Candidate", datasetRevision: dataset.revision, configuration: config)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: candidate.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 20)
        let approval = try fixture.storage.approveBaseline(jobID: baseline.id, expectedJobRevision: baseline.revision, expectedEvidenceRevision: #require(before.evidenceRevision), note: "Reviewed exact saved results")
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 0)
        let export = fixture.directory.appendingPathComponent("baseline-export")
        try fixture.storage.exportJob(baseline.id, to: export)
        #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("Job/baseline-approvals.jsonl").path))
        let record = try fixture.storage.record(jobID: baseline.id, slot: 0)
        try fixture.storage.appendReview(jobID: baseline.id, slot: 0, event: .init(requestID: record.response.requestID, reviewer: "Reviewer", outcome: .passed, note: "Confirmed result"))
        let changed = try fixture.storage.report(jobID: baseline.id)
        #expect(changed.baselineApproval == nil && changed.evidenceRevision != approval.evidenceRevision)
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 20)
        #expect(throws: ProductionFailure.self) {
            try fixture.storage.approveBaseline(jobID: baseline.id, expectedJobRevision: baseline.revision, expectedEvidenceRevision: approval.evidenceRevision, note: "Stale approval")
        }
        _ = try fixture.storage.approveBaseline(jobID: baseline.id, expectedJobRevision: baseline.revision, expectedEvidenceRevision: #require(changed.evidenceRevision), note: "Reviewed updated evidence")
        try fixture.storage.setControl(jobID: baseline.id, paused: true)
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 20)
        try fixture.storage.setControl(jobID: baseline.id, paused: false)
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 20)
        let resumed = try fixture.storage.report(jobID: baseline.id)
        _ = try fixture.storage.approveBaseline(jobID: baseline.id, expectedJobRevision: baseline.revision, expectedEvidenceRevision: #require(resumed.evidenceRevision), note: "Reviewed resumed evidence")
        try fixture.storage.setControl(jobID: baseline.id, cancelled: true)
        #expect(try fixture.storage.report(jobID: candidate.id).exitCode == 20)
        #expect(throws: ProductionFailure.self) { try fixture.storage.setControl(jobID: baseline.id, cancelled: false) }
        #expect(try fixture.storage.report(jobID: baseline.id).phase == "cancelled")
    }
    @Test func errorEvidenceCannotBeApprovedEvenWhenJobPolicyAllowsErrors() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "one"), .init(id: "b", prompt: "two")])
        var config = try fixture.job(dataset).configuration
        config.gate.maximumErrors = 1; config.gate.minimumPassRate = 0
        let job = try fixture.storage.createJob(name: "Allowed error", datasetRevision: dataset.revision, configuration: config)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: $0.slot == 0 ? .passed : .error, cost: 0) }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 0 && report.baselineEligible == false)
        #expect(throws: ProductionFailure.self) {
            try fixture.storage.approveBaseline(jobID: job.id, expectedJobRevision: job.revision, expectedEvidenceRevision: #require(report.evidenceRevision), note: "Incomplete scoring")
        }
    }
    @Test func criticalCasesTranslateToImportedSourcesBeforeJobPublication() async throws {
        let fixture = try Fixture(), caseID = UUID().uuidString
        let dataset = try fixture.dataset([
            .init(id: caseID, sourceID: "customer-a", prompt: "one"),
            .init(id: "capture-b", sourceID: "customer-b", prompt: "two", metadata: ["suiteCaseID": caseID]),
            .init(id: "capture-c", sourceID: "customer-c", prompt: "three")
        ])
        var config = try fixture.job(dataset).configuration
        config.gate.criticalSourceIDs = [caseID, "customer-c"]
        let job = try fixture.storage.createJob(name: "Mapped", datasetRevision: dataset.revision, configuration: config, resolveCriticalCaseIDs: true)
        #expect(job.configuration.gate.criticalSourceIDs == ["customer-a", "customer-b", "customer-c"])
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 0)
        config.gate.criticalSourceIDs = [UUID().uuidString]
        let count = try fixture.storage.jobs().count
        #expect(throws: ProductionFailure.self) { try fixture.storage.createJob(name: "Unmapped", datasetRevision: dataset.revision, configuration: config) }
        #expect(try fixture.storage.jobs().count == count)
    }
    @Test func cloningDoesNotReinterpretFrozenSourceIDsAsExampleIDs() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([
            .init(id: "native-case", sourceID: "customer-a", prompt: "one"),
            .init(id: "customer-a", sourceID: "customer-b", prompt: "two")
        ])
        var config = try fixture.job(dataset).configuration; config.gate.minimumPassRate = 0
        config.gate.criticalSourceIDs = ["native-case"]
        let original = try fixture.storage.createJob(name: "Mapped", datasetRevision: dataset.revision, configuration: config, resolveCriticalCaseIDs: true)
        let clone = try fixture.storage.createJob(name: "Clone", datasetRevision: dataset.revision, configuration: original.configuration)
        #expect(original.configuration.gate.criticalSourceIDs == ["customer-a"])
        #expect(clone.configuration.gate.criticalSourceIDs == original.configuration.gate.criticalSourceIDs)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: clone.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: $0.slot == 0 ? .passed : .failed, cost: 0) }
        #expect(try fixture.storage.report(jobID: clone.id).exitCode == 0)
    }
    @Test func concurrentReportsNeverCombineCompletedResultsWithOldCost() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        var config = try fixture.job(dataset).configuration
        config.maximumCost = 1; config.maximumCostPerAttempt = 1
        let job = try fixture.storage.createJob(name: "Cost snapshot", datasetRevision: dataset.revision, configuration: config)
        let storage = fixture.storage, worker = fixture.worker
        async let run = ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 2) }
        for _ in 0..<50 {
            let report = try await Task.detached { try storage.report(jobID: job.id) }.value
            #expect(report.exitCode == 20)
            if report.completed == 1 { #expect(report.reportedCost == 2) }
        }
        _ = try await run
        let finished = try storage.report(jobID: job.id)
        #expect(finished.completed == 1 && finished.reportedCost == 2 && finished.exitCode == 20)
    }

    @Test func immutableDatasetsRejectLeakageAndCorruption() throws {
        let fixture = try Fixture(), a = ProductionExample(id: "a", sourceID: "source", prompt: "input", expected: "output")
        #expect(throws: ProductionFailure.self) { try fixture.dataset([a,a]) }
        var heldout = a; heldout.id = "b"; heldout.partition = .test
        #expect(throws: ProductionFailure.self) { try fixture.dataset([a,heldout]) }
        #expect(throws: ProductionFailure.self) { try fixture.dataset([a], production: true) }
        let dataset = try fixture.dataset([a], production: true, confirmed: true)
        #expect(try fixture.dataset([a], production: true, confirmed: true).revision == dataset.revision)
        let folder = try fixture.storage.datasetDirectory(dataset.revision)
        var manifest = dataset; manifest.partitionCounts = ["test": 1]
        try ProductionCodec.write(manifest, to: folder.appendingPathComponent("manifest.json"))
        #expect(throws: ProductionFailure.self) { try fixture.storage.loadDataset(dataset.revision) }
        try ProductionCodec.write(dataset, to: folder.appendingPathComponent("manifest.json"))
        try Data("changed\n".utf8).write(to: folder.appendingPathComponent("examples.jsonl"))
        #expect(throws: ProductionFailure.self) { try ProductionDatasetReader(storage: fixture.storage, revision: dataset.revision) }
    }
    @Test func aggregateExampleSizeIsRejectedBeforePublication() throws {
        let fixture = try Fixture(), text = String(repeating: "a", count: 64_000)
        let example = ProductionExample(id: "large", prompt: text, expected: text, capturedOutput: text, input: Data(repeating: 1, count: 64_000))
        #expect(throws: ProductionFailure.self) { try fixture.dataset([example]) }
        #expect(try fixture.storage.datasets().isEmpty)
    }
    @Test func tenThousandExamplesResumeWithoutDuplicateExecution() async throws {
        let started = Date(), fixture = try Fixture()
        let dataset = try fixture.dataset((0..<10_000).map { .init(id: String($0), sourceID: "source-\($0/2)", prompt: "input", expected: "output", metadata: ["locale": $0 % 2 == 0 ? "en_GB" : "fr_FR"]) })
        let reader = try ProductionDatasetReader(storage: fixture.storage, revision: dataset.revision)
        #expect(try reader.example(at: 9_999).id == "9999")
        let job = try fixture.job(dataset), calls = Calls(), runner = ProductionBatchRunner(storage: fixture.storage)
        let execute: ProductionExecutor = { request in
            guard await calls.record(request.requestID) else { throw ProductionFailure.integrity("Duplicate execution") }
            return .init(requestID: request.requestID, outcome: .passed, output: "output", latencyMilliseconds: 10, cost: 0)
        }
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, maximumResponses: 123, execute: execute) == 123)
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 20)
        try fixture.storage.setControl(jobID: job.id, paused: true)
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, execute: execute) == 0)
        try fixture.storage.setControl(jobID: job.id, paused: false)
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, execute: execute) == 9_877)
        #expect(try await runner.run(jobID: job.id, worker: fixture.worker, execute: execute) == 0)
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.completed == 10_000 && report.exitCode == 0)
        #expect(report.counts.distinctSources == 5_000 && report.cohorts["locale=fr_FR"]?.samples == 5_000)
        #expect(await calls.total() == 10_000)
        print("SCALE: 10,000 fixture responses; 5,000 distinct sources; pause/resume; no duplicate execution; elapsed \(Date().timeIntervalSince(started))s")
    }
    @Test func mismatchedWorkersAndExpiredLeasesCannotCommit() throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset, targets: [.init(locale: "en_GB")])
        var wrong = fixture.worker; wrong.locale = "fr_FR"
        #expect(try fixture.storage.claim(job, worker: wrong) == nil)
        let now = Date(), first = try #require(try fixture.storage.claim(job, worker: fixture.worker, now: now))
        let second = try #require(try fixture.storage.claim(job, worker: fixture.worker, now: now.addingTimeInterval(361)))
        #expect(first.lease?.token != second.lease?.token)
        #expect(throws: ProductionFailure.self) { try fixture.storage.updateChunk(job, index: 0, token: first.lease!.token, now: now.addingTimeInterval(362)) { $0.lease = nil } }
    }
    @Test func repetitionsAndTargetsDoNotInflateSourceConfidence() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", sourceID: "same", prompt: "input"), .init(id: "b", sourceID: "same", prompt: "input")])
        let job = try fixture.job(dataset, repetitions: 3, targets: [.init(), .init()])
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
            .init(requestID: request.requestID, outcome: request.slot == 0 ? .failed : .passed, latencyMilliseconds: 10, cost: 0)
        }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.completed == 12 && report.counts.distinctSources == 1 && report.counts.passingSources == 0)
        #expect(report.exitCode == 10)
    }
    @Test func pauseBetweenRetriesPreventsAnotherExecution() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset)
        let calls = Calls(), storage = fixture.storage
        do {
            _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: fixture.worker) { request in
                _ = await calls.record(request.requestID)
                try storage.setControl(jobID: job.id, paused: true)
                return .init(requestID: request.requestID, outcome: .error, cost: 0, retryable: true)
            }
        } catch is CancellationError { }
        #expect(await calls.total() == 1)
        #expect(try storage.report(jobID: job.id).completed == 0)
        try storage.setControl(jobID: job.id, paused: false)
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(try storage.report(jobID: job.id).exitCode == 0)
    }
    @Test func elapsedDeadlineCannotAdmitRetryAndCompletedJobsAreSkipped() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        var config = try fixture.job(dataset).configuration; config.maximumElapsedSeconds = 1; config.timeoutSeconds = 10
        let job = try fixture.storage.createJob(name: "Deadline", datasetRevision: dataset.revision, configuration: config), calls = Calls()
        do {
            _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
                _ = await calls.record(request.requestID); try await Task.sleep(for: .seconds(2))
                return .init(requestID: request.requestID, outcome: .passed, cost: 0)
            }
        } catch let error as ProductionFailure { guard case .budget = error else { throw error } }
        #expect(await calls.total() == 1)
        let completed = try fixture.job(dataset)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: completed.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(try fixture.storage.claim(completed, worker: fixture.worker, now: Date().addingTimeInterval(90_000)) == nil)
    }
    @Test func interruptedSideEffectsRequireAssignedReconciliationIncludingCost() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset, safety: .sideEffects, budget: true)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .needsEvidence, explanation: "connection lost") }
        let id = fixture.storage.requestID(job, slot: 0)
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 20)
        #expect(throws: ProductionFailure.self) { try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", outcome: .passed, note: "guess")) }
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "A", note: "Verify actual state"))
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .reconcile, note: "Confirmed persisted app state and outstanding charge", reconciledResponse: .init(requestID: id, outcome: .passed, output: "verified", cost: 0.5)))
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 0 && report.missingCostCount == 0 && report.reportedCost == 0.5)
        #expect(report.reviewedCount == 1)
        #expect(try fixture.storage.records(jobID: job.id, offset: 0, limit: 1).first?.response.outcome == .needsEvidence)
        #expect(throws: ProductionFailure.self) { try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .reconcile, note: "again", reconciledResponse: .init(requestID: id, outcome: .passed, cost: 0.5))) }
    }
    @Test func reviewDisagreementCannotPassUntilAdjudicated() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input", capturedOutput: "original")])
        let job = try fixture.storage.createCapturedJob(name: "Captured", datasetRevision: dataset.revision)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker, execute: ProductionStorage.capturedResponse)
        let id = fixture.storage.requestID(job, slot: 0)
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 20)
        for (name,outcome) in [("A",ProductionOutcome.passed),("B",.failed)] { try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: name, outcome: outcome, note: "Manual review")) }
        #expect(try fixture.storage.review(jobID: job.id, requestID: id).disagreement)
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 20)
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "C", note: "Independent adjudication"))
        #expect(throws: ProductionFailure.self) { try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "B", action: .adjudicate, outcome: .passed, note: "not assigned")) }
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "C", action: .adjudicate, outcome: .passed, note: "Verified rubric"))
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 0)
        let output = fixture.directory.appendingPathComponent("export")
        try fixture.storage.exportJob(job.id, to: output)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Dataset/examples.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Reviews/\(job.id)-\(id).jsonl").path))
    }
    @Test func retriesRetainCostsAndMissingCohortsBlockGates() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        var config = try fixture.job(dataset).configuration; config.gate.requiredCohorts = ["locale": "fr_FR"]
        let job = try fixture.storage.createJob(name: "Cohort", datasetRevision: dataset.revision, configuration: config), calls = Calls()
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
            let first = await calls.record(request.requestID)
            return .init(requestID: request.requestID, outcome: first ? .error : .passed, cost: first ? 0.5 : 0.25, retryable: first)
        }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.reportedCost == 0.75 && report.exitCode == 20)
        #expect(report.issues.contains { $0.contains("fr_FR") })
    }
    @Test func fullPayloadChunkRemainsReadableAndForeignResponsesFail() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset((0..<100).map { .init(id: String($0), prompt: "input") }), job = try fixture.job(dataset)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
            .init(requestID: request.requestID, outcome: .passed, output: String(repeating: "a", count: 64_000), explanation: String(repeating: "b", count: 8_000), cost: 0, artifact: Data(repeating: 1, count: 262_144))
        }
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 0)
        let other = try fixture.job(dataset)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: other.id, worker: fixture.worker, maximumResponses: 1) { _ in .init(requestID: UUID(), outcome: .passed, cost: 0) }
        #expect(try fixture.storage.report(jobID: other.id).counts.errors == 1)
    }
    @Test func scheduleTicksAreIdempotentAndPausedSchedulesStayPaused() throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset), now = Date()
        let schedule = ProductionSchedule(templateJobID: job.id, intervalSeconds: 60, nextRun: now, remainingRuns: 2)
        try fixture.storage.saveSchedule(schedule)
        #expect(try fixture.storage.tickSchedules(now: now).count == 1)
        #expect(try fixture.storage.tickSchedules(now: now).isEmpty)
        var paused = try #require(fixture.storage.schedules().first); paused.paused = true
        try fixture.storage.saveSchedule(paused)
        #expect(try fixture.storage.tickSchedules(now: now.addingTimeInterval(120)).isEmpty)
        #expect(try fixture.storage.jobs().count == 2)
    }
    @Test func independentCaptureWritersPreserveEveryRecordOnFirstCreation() async throws {
        let fixture = try Fixture(), file = fixture.directory.appendingPathComponent("shared-capture.jsonl")
        let writers = try (0..<32).map { _ in
            try DeveloperProductionCapture(file: file, sourceKey: Data(repeating: 1, count: 32), metadataKeys: []) { $0 }
        }
        for writer in writers { await writer.setEnabled(true) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, writer) in writers.enumerated() {
                group.addTask { () async throws -> Void in
                    let saved = try await writer.record(eventID: "event-\(index)", sourceID: "source-\(index)", prompt: "prompt", output: "output")
                    #expect(saved)
                }
            }
            try await group.waitForAll()
        }
        let lines = try Data(contentsOf: file).split(separator: 10)
        #expect(lines.count == writers.count)
        let records = try lines.map { try JSONDecoder().decode(DeveloperProductionCapture.Record.self, from: Data($0)) }
        #expect(Set(records.map(\.id)).count == writers.count)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        // Opening an existing capture file must append without truncating its previous evidence.
        #expect(try await writers[0].record(eventID: "later", sourceID: "later", prompt: "prompt", output: "output"))
        #expect(try Data(contentsOf: file).split(separator: 10).count == writers.count + 1)
    }

    @Test func optInCaptureSanitizesAndStopsAtRetentionLimit() async throws {
        let fixture = try Fixture(), file = fixture.directory.appendingPathComponent("capture.jsonl")
        let capture = try DeveloperProductionCapture(file: file, sourceKey: Data(repeating: 1, count: 32), metadataKeys: ["locale"], maximumFileBytes: 262_144) { $0.replacingOccurrences(of: "secret", with: "[redacted]") }
        #expect(try await capture.record(eventID: "private-id", sourceID: "private-source", prompt: "secret", output: "secret") == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await capture.setEnabled(true)
        #expect(try await capture.record(eventID: "private-id", sourceID: "private-source", prompt: "secret", output: "secret", metadata: ["locale": "en_GB", "email": "private"]))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("secret") && !text.contains("private") && text.contains("[redacted]"))
        _ = try fixture.storage.importDataset(from: file, name: "Capture", version: "v1", productionData: true, redactionConfirmed: true)
        let large = String(repeating: "a", count: 64_000)
        for i in 0..<2 { _ = try await capture.record(eventID: "\(i)", sourceID: "source-\(i)", prompt: large, output: large) }
        do { _ = try await capture.record(eventID: "overflow", sourceID: "overflow", prompt: large, output: large); Issue.record("Capture exceeded retention budget") } catch DeveloperProductionCapture.CaptureError.retentionLimit { }
        #expect((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize! <= 262_144)
    }
}

@Suite(.serialized) struct ProductionRecoveryTests {
    @Test func largeFrozenExecutionContextRemainsReadable() throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let context = Data(repeating: 1, count: 53_000_000)
        let config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(Data("score".utf8)),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        let job = try fixture.storage.createJob(name: "Large context", datasetRevision: dataset.revision, configuration: config)
        let file = fixture.storage.jobDirectory(job.id).appendingPathComponent("job.json")
        #expect(try ProductionCodec.fileSize(file) > 70_000_000)
        let loaded = try fixture.storage.loadJob(job.id)
        #expect(loaded.configuration.executionContext == context && loaded.revision == job.revision)
    }

    @Test func escapedFullPayloadChunkRemainsReadable() throws {
        // Character limits permit large combining sequences; the encoded dataset row
        // limit, rather than Character count, bounds retained metadata.
        let metadata = ["note": "a" + String(repeating: "\u{0301}", count: 125_000)]
        let fixture = try Fixture(), dataset = try fixture.dataset((0..<100).map { .init(id: String($0), prompt: "input", metadata: metadata) })
        let job = try fixture.job(dataset)
        var worker = fixture.worker; worker.name = "a" + String(repeating: "\u{0301}", count: 9_000)
        try fixture.storage.register(worker)
        var chunk = ProductionChunk(index: 0)
        for slot in 0..<100 {
            let response = ProductionResponse(requestID: fixture.storage.requestID(job, slot: slot), outcome: .passed,
                output: String(repeating: "\u{0001}", count: 64_000), explanation: String(repeating: "\u{0001}", count: 8_000),
                cost: 0, artifact: Data(repeating: 1, count: 262_144))
            try fixture.storage.validateResponse(response, requestID: response.requestID)
            chunk.records[slot] = ProductionRecord(slot: slot, sourceID: String(slot), exampleID: String(slot), partition: .regression,
                metadata: metadata, targetIndex: 0, repetition: 1, attempt: 1, worker: worker, response: response, completedAt: Date())
            chunk.attempts[slot] = ProductionAttempt(requestID: response.requestID, number: 1, startedAt: Date(), worker: worker)
        }
        let file = fixture.storage.chunkURL(job, 0)
        try ProductionCodec.write(chunk, to: file)
        #expect(try ProductionCodec.fileSize(file) > 100_000_000)
        let restored = try fixture.storage.chunk(job, index: 0)
        #expect(restored.records.count == 100)
        #expect(restored.records[99]?.response == chunk.records[99]?.response)
        #expect(restored.records[99]?.metadata == metadata)
    }

    @Test func oversizedWorkerCannotBeRegisteredOrClaimAChunk() throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset)
        for oversizedName in [false, true] {
            var worker = fixture.worker
            if oversizedName { worker.name = String(repeating: "a", count: 20_000) }
            else { worker.hardware = "a" + String(repeating: "\u{0301}", count: 20_000) }
            #expect(throws: ProductionFailure.self) { try fixture.storage.register(worker) }
            #expect(throws: ProductionFailure.self) { try fixture.storage.claim(job, worker: worker) }
        }
        #expect(try fixture.storage.workers().isEmpty)
        #expect(try fixture.storage.chunk(job, index: 0).lease == nil)
    }

    @Test func boundedWritesPreserveExistingEvidenceWhenEncodingExceedsLimit() throws {
        let fixture = try Fixture(), file = fixture.directory.appendingPathComponent("bounded.json")
        try ProductionCodec.write("old", to: file, maximumBytes: 5)
        #expect(throws: ProductionFailure.self) { try ProductionCodec.write("\u{0001}", to: file, maximumBytes: 5) }
        #expect(try ProductionCodec.read(String.self, from: file, maximumBytes: 5) == "old")
    }

    @Test func datasetIdentityPreservesLegacyNewlinesAndRejectsAmbiguousImports() throws {
        let fixture = try Fixture(), file = fixture.directory.appendingPathComponent("identity.jsonl")
        var input = try ProductionCodec.encode(ProductionExample(id: "a", prompt: "input")); input.append(10)
        try input.write(to: file)
        var original = try fixture.storage.importDataset(from: file, name: "Legacy seed", version: "1")
        let originalFolder = try fixture.storage.datasetDirectory(original.revision)
        original.name = "a\nb"; original.version = "c"
        let legacyIdentity = "\(original.name)\n\(original.version)\n\(original.sampling.rawValue)\n\(original.productionData)\n\(original.dataDigest)\n\(original.indexDigest)\n\(original.count)\n\(try ProductionCodec.digest(ProductionCodec.encode(original.partitionCounts)))"
        original.revision = ProductionCodec.digest(Data(legacyIdentity.utf8))
        try ProductionCodec.write(original, to: originalFolder.appendingPathComponent("manifest.json"))
        try FileManager.default.moveItem(at: originalFolder, to: fixture.storage.datasetDirectory(original.revision))
        #expect(try fixture.storage.loadDataset(original.revision, verifyFiles: true).name == "a\nb")
        for (name, version) in [("a\nb", "c"), ("a", "b\nc")] {
            #expect(throws: ProductionFailure.self) {
                try fixture.storage.importDataset(from: file, name: name, version: version)
            }
        }
        let other = try fixture.storage.importDataset(from: file, name: "a", version: "b")
        #expect(other.revision != original.revision && other.name == "a" && other.version == "b")
        #expect(try fixture.storage.importDataset(from: file, name: "a", version: "b").revision == other.revision)
        // New structured revisions detect an ambiguous name/version boundary change.
        var changed = other; changed.name = "a\nb"; changed.version = "c"
        try ProductionCodec.write(changed, to: fixture.storage.datasetDirectory(other.revision).appendingPathComponent("manifest.json"))
        #expect(throws: ProductionFailure.self) { try fixture.storage.loadDataset(other.revision) }
    }

    @Test(arguments: [ProductionReplaySafety.inference, .sideEffects])
    func multibyteExecutorErrorsLeaveReadableEvidence(safety: ProductionReplaySafety) async throws {
        struct WorkerError: Error, LocalizedError, CustomStringConvertible {
            var errorDescription: String? { description }
            var description: String { String(repeating: "a", count: 7_999) + String(repeating: "🙂", count: 3_000) }
        }
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset, safety: safety)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { _ in
            throw WorkerError()
        }
        let response = try fixture.storage.record(jobID: job.id, slot: 0).response
        #expect((response.explanation?.utf8.count ?? 0) <= 8_000)
        #expect(response.explanation?.hasPrefix(String(repeating: "a", count: 7_999)) == true)
        try fixture.storage.validateResponse(response, requestID: response.requestID)
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.completed == 1 && report.exitCode != 0)
        #expect(response.outcome == (safety == .sideEffects ? .needsEvidence : .error))
    }

    @Test func fullReconciledPayloadRemainsReadable() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset, safety: .sideEffects)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            .init(requestID: $0.requestID, outcome: .needsEvidence)
        }
        let id = fixture.storage.requestID(job, slot: 0)
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "A", note: "Verify state"))
        let response = ProductionResponse(requestID: id, outcome: .passed,
            output: String(repeating: "\u{0001}", count: 64_000), explanation: String(repeating: "\u{0001}", count: 8_000),
            cost: 0, artifact: Data(repeating: 1, count: 262_144))
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .reconcile,
            note: String(repeating: "\u{0001}", count: 8_000), reconciledResponse: response))
        #expect(try fixture.storage.review(jobID: job.id, requestID: id).response == response)
        #expect(try fixture.storage.report(jobID: job.id).exitCode == 0)
    }

    @Test func reconciliationCannotOverrideFailedEvidenceWithPassingVerdict() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset, safety: .sideEffects)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            .init(requestID: $0.requestID, outcome: .needsEvidence)
        }
        let id = fixture.storage.requestID(job, slot: 0)
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: id, reviewer: "A", action: .assign, assignee: "A", note: "Verify state"))
        var event = ProductionReviewEvent(requestID: id, reviewer: "A", action: .reconcile, outcome: .passed,
            note: "Verified failed action", reconciledResponse: .init(requestID: id, outcome: .failed, cost: 0))
        #expect(throws: ProductionFailure.self) { try fixture.storage.appendReview(jobID: job.id, slot: 0, event: event) }
        #expect(try fixture.storage.review(jobID: job.id, requestID: id).events.count == 1)
        event.outcome = nil
        try fixture.storage.appendReview(jobID: job.id, slot: 0, event: event)
        #expect(try fixture.storage.report(jobID: job.id).counts.failed == 1)
        // Older clients could persist conflicting fields; the verified response remains authoritative.
        event.outcome = .passed
        var legacy = try ProductionCodec.encode(event); legacy.append(10)
        try legacy.write(to: fixture.storage.reviewURL(jobID: job.id, requestID: id))
        #expect(try fixture.storage.report(jobID: job.id).counts.failed == 1)
    }

    @Test func captureRejectsUnimportableEncodedRecordsWithoutChangingExistingEvidence() async throws {
        let fixture = try Fixture(), file = fixture.directory.appendingPathComponent("bounded-capture.jsonl")
        let capture = try DeveloperProductionCapture(file: file, sourceKey: Data(repeating: 1, count: 32), metadataKeys: [""]) { $0 }
        await capture.setEnabled(true)
        #expect(try await capture.record(eventID: "valid", sourceID: "valid", prompt: "input", output: "output"))
        let original = try Data(contentsOf: file)
        do {
            _ = try await capture.record(eventID: "escaped", sourceID: "escaped",
                prompt: String(repeating: "\u{0001}", count: 64_000), output: String(repeating: "\u{0001}", count: 64_000))
            Issue.record("Capture accepted a JSONL row larger than the import limit")
        } catch DeveloperProductionCapture.CaptureError.oversizedRecord { }
        do {
            _ = try await capture.record(eventID: "empty-key", sourceID: "empty-key", prompt: "input", output: "output", metadata: ["": "value"])
            Issue.record("Capture accepted an empty metadata key")
        } catch DeveloperProductionCapture.CaptureError.oversizedRecord { }
        #expect(try Data(contentsOf: file) == original)
        #expect(try fixture.storage.importDataset(from: file, name: "Capture", version: "v1").count == 1)
    }

    @Test func canonicalTimestampsRemainStableAcrossRepeatedRoundTrips() throws {
        for index in 0..<100 {
            let date = Date(timeIntervalSince1970: 1_791_000_000 + Double(index)/123.4567)
            let first = try ProductionCodec.encode(date)
            let second = try ProductionCodec.encode(ProductionCodec.decode(Date.self, first))
            #expect(first == second)
        }
    }

    @Test func costJournalRecoversCrashBeforeAndAfterLedgerSettlement() async throws {
        for ledgerAlreadySettled in [false,true] {
            let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset, budget: true)
            let requestID = fixture.storage.requestID(job, slot: 0)
            let chunk = try #require(try fixture.storage.claim(job, worker: fixture.worker))
            try fixture.storage.reserveCost(job, requestID: requestID, slot: 0, attempt: 1)
            // Exact durable state after the attempt journal write, with an expired/lost lease.
            var interrupted = chunk; interrupted.lease = nil
            var attempt = ProductionAttempt(requestID: requestID, number: 1, startedAt: Date(), worker: fixture.worker)
            attempt.reportedCost = 0.4; attempt.hasUnknownCost = false; attempt.pendingCost = 0.4; attempt.pendingCostAttempt = 1
            interrupted.attempts[0] = attempt
            try ProductionCodec.write(interrupted, to: fixture.storage.chunkURL(job, 0))
            if ledgerAlreadySettled {
                var control = try fixture.storage.control(job); control.reportedCost = 0.4; control.costReservations = [:]; control.costReservationSlots = [:]
                try ProductionCodec.write(control, to: fixture.storage.jobDirectory(job.id).appendingPathComponent("control.json"))
            }
            _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0.6) }
            let report = try fixture.storage.report(jobID: job.id)
            #expect(report.reportedCost == 1 && report.missingCostCount == 0 && report.exitCode == 0)
        }
    }
    @Test func interruptedMutatingAttemptIsNeverReplayed() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset, safety: .sideEffects)
        var chunk = try #require(try fixture.storage.claim(job, worker: fixture.worker))
        chunk.lease = nil; chunk.attempts[0] = .init(requestID: fixture.storage.requestID(job, slot: 0), number: 1, startedAt: Date(), worker: fixture.worker)
        try ProductionCodec.write(chunk, to: fixture.storage.chunkURL(job, 0))
        let calls = Calls()
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
            _ = await calls.record(request.requestID); return .init(requestID: request.requestID, outcome: .passed)
        }
        #expect(await calls.total() == 0)
        #expect(try fixture.storage.report(jobID: job.id).counts.uncertain == 1)
    }

    @Test(arguments: [ProductionReplaySafety.inference, .sideEffects])
    func resumingWithoutExecutionRetainsOriginalAttemptWorker(safety: ProductionReplaySafety) async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")])
        let job = try fixture.job(dataset, safety: safety)
        let original = fixture.worker
        var resumed = original
        resumed.id = "resuming-worker"; resumed.name = "Resuming worker"
        resumed.hardware = "different-hardware"; resumed.model = "different-model"
        var chunk = try #require(try fixture.storage.claim(job, worker: original))
        chunk.lease = nil
        let attempts = safety == .sideEffects ? 1 : job.configuration.maximumAttempts
        var attempt = ProductionAttempt(requestID: fixture.storage.requestID(job, slot: 0), number: attempts,
                                        startedAt: Date(), worker: original)
        attempt.reportedCost = 0.4; attempt.hasUnknownCost = false
        chunk.attempts[0] = attempt
        try ProductionCodec.write(chunk, to: fixture.storage.chunkURL(job, 0))
        let journaledWorker = try #require(fixture.storage.chunk(job, index: 0).attempts[0]?.worker)
        let calls = Calls()
        let count = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: resumed) { request in
            _ = await calls.record(request.requestID)
            return .init(requestID: request.requestID, outcome: .passed, cost: 0)
        }
        #expect(count == 1)
        #expect(await calls.total() == 0)
        let record = try fixture.storage.record(jobID: job.id, slot: 0)
        #expect(record.worker == journaledWorker)
        #expect(record.attempt == attempts)
        #expect(record.response.cost == 0.4)
        #expect(record.response.outcome == (safety == .sideEffects ? .needsEvidence : .error))
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.cohorts["hardware=\(original.hardware)"]?.samples == 1)
        #expect(report.cohorts["model=\(original.model)"]?.samples == 1)
        #expect(report.cohorts["hardware=\(resumed.hardware)"] == nil)
        #expect(report.cohorts["model=\(resumed.model)"] == nil)
    }
    @Test func compatibleBaselineShowsCohortDriftAndRejectsChangedScoring() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input", metadata: ["task":"safety"])]), baseline = try fixture.job(dataset)
        let runner = ProductionBatchRunner(storage: fixture.storage)
        _ = try await runner.run(jobID: baseline.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        var configuration = baseline.configuration; configuration.baselineJobID = baseline.id
        let candidate = try fixture.storage.createJob(name: "Candidate", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await runner.run(jobID: candidate.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .failed, cost: 0) }
        let report = try fixture.storage.report(jobID: candidate.id)
        #expect(report.exitCode == 10 && report.baselineCohortPassRates?["task=safety"] == 1)
        configuration.scoringRevision = ProductionCodec.digest(Data("changed-scoring".utf8))
        #expect(throws: ProductionFailure.self) { try fixture.storage.createJob(name: "Incompatible", datasetRevision: dataset.revision, configuration: configuration) }
    }

    /// A later pause must not reuse authority granted for an earlier pause, while cost-only checkpoints remain compatible.
    @Test func controlRevisionsRejectRestoredFlagValuesAndIgnoreCostCheckpoints() throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input")]), job = try fixture.job(dataset)
        try fixture.storage.setControl(jobID: job.id, paused: true)
        let firstPause = try fixture.storage.controlRevision(job)
        try fixture.storage.setControl(jobID: job.id, paused: false, expectedControlRevision: firstPause)
        try fixture.storage.setControl(jobID: job.id, paused: true)
        let laterPause = try fixture.storage.controlRevision(job)
        #expect(firstPause != laterPause)
        #expect(throws: ProductionFailure.self) {
            try fixture.storage.setControl(jobID: job.id, paused: false, expectedControlRevision: firstPause)
        }
        #expect(try fixture.storage.control(job).paused)
        try fixture.storage.setControl(jobID: job.id, paused: true, expectedControlRevision: laterPause)
        #expect(try fixture.storage.controlRevision(job) == laterPause)
        var checkpoint = try fixture.storage.control(job)
        checkpoint.startedAt = Date(); checkpoint.reportedCost = 1
        checkpoint.costReservations = ["fixture": 2]; checkpoint.costReservationSlots = ["fixture": 0]
        #expect(ProductionStorage.controlRevision(checkpoint) == laterPause)
    }

    /// Legacy threshold spellings still match a unique observed identity when either its key or value contains '='.
    @Test(arguments: [false, true])
    func cohortThresholdsPreserveUnambiguousDelimiterNames(keyContainsDelimiter: Bool) async throws {
        let fixture = try Fixture()
        let metadata = keyContainsDelimiter ? ["task=a": "b"] : ["task": "a=b"]
        let dataset = try fixture.dataset([.init(id: "a", prompt: "input", metadata: metadata)])
        var configuration = try fixture.job(dataset).configuration
        configuration.gate.cohortMinimumPassRates = ["task=a=b": 0.5]
        let job = try fixture.storage.createJob(name: "Legacy cohort", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 0)
        #expect(report.cohorts["task=a=b"]?.samples == 1 && report.cohorts["task=a=b"]?.passRate == 1)
    }

    /// Distinct observed dimensions sharing a threshold spelling cannot dilute a failure into passing aggregate evidence.
    @Test func cohortThresholdsRejectAmbiguousObservedDimensions() async throws {
        let fixture = try Fixture()
        let dataset = try fixture.dataset([.init(id: "failed", prompt: "input", metadata: ["task": "a=b"]),
                                           .init(id: "passed", prompt: "input", metadata: ["task=a": "b"])])
        var configuration = try fixture.job(dataset).configuration
        configuration.gate.minimumPassRate = 0; configuration.gate.cohortMinimumPassRates = ["task=a=b": 0.5]
        let job = try fixture.storage.createJob(name: "Colliding threshold", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) {
            .init(requestID: $0.requestID, outcome: $0.example.id == "failed" ? .failed : .passed, cost: 0)
        }
        #expect(throws: ProductionFailure.self) { try fixture.storage.report(jobID: job.id) }
    }

    /// Legacy report keys remain unchanged, but unrepresentable distinct dimensions fail explicitly rather than merge.
    @Test func selectedCohortDisplayCollisionsCannotProduceAPassingReport() async throws {
        let fixture = try Fixture()
        let dataset = try fixture.dataset([.init(id: "a", prompt: "input", metadata: ["task": "a=b", "task=a": "b"])])
        var configuration = try fixture.job(dataset).configuration
        configuration.gate.requiredCohorts = ["task=a": "b"]
        let job = try fixture.storage.createJob(name: "Ambiguous cohort", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        #expect(throws: ProductionFailure.self) { try fixture.storage.report(jobID: job.id) }
    }

    /// A present dimension cannot satisfy a different required key/value pair with the same legacy display name.
    @Test func requiredCohortsKeepDelimiterKeysSeparate() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input", metadata: ["task=a": "b"])])
        var configuration = try fixture.job(dataset).configuration
        configuration.gate.requiredCohorts = ["task": "a=b", "task=a": "b"]
        let job = try fixture.storage.createJob(name: "Missing required dimension", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 0) }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 20)
        #expect(report.issues.contains("Required cohort task=a=b is missing."))
    }

    /// Decimal policy boundaries permit exactly the configured regression without accepting a genuinely smaller allowance.
    @Test func passRateRegressionUsesExactCountBoundaries() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset((0..<10).map { .init(id: String($0), prompt: "input") })
        var configuration = try fixture.job(dataset).configuration; configuration.gate.minimumPassRate = 0
        let baseline = try fixture.storage.createJob(name: "Baseline", datasetRevision: dataset.revision, configuration: configuration)
        let runner = ProductionBatchRunner(storage: fixture.storage)
        _ = try await runner.run(jobID: baseline.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: $0.slot < 8 ? .passed : .failed, cost: 0) }
        configuration.baselineJobID = baseline.id
        for (passing, allowance, expected) in [(7, 0.1, 0), (7, Double(0.1).nextDown, 10), (6, 0.1, 10), (7, 1e-300, 10)] {
            configuration.gate.maximumPassRateRegression = allowance
            let candidate = try fixture.storage.createJob(name: "Candidate", datasetRevision: dataset.revision, configuration: configuration)
            _ = try await runner.run(jobID: candidate.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: $0.slot < passing ? .passed : .failed, cost: 0) }
            #expect(try fixture.storage.report(jobID: candidate.id).exitCode == expected)
        }
    }

    /// Finite measurements near Double's maximum retain a finite mean and conservative P95 that can be exported as JSON.
    @Test(arguments: [Double.greatestFiniteMagnitude, 1e308])
    func extremeFiniteLatenciesProduceSerializableReports(latency: Double) async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input"), .init(id: "b", prompt: "input")]), job = try fixture.job(dataset)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, latencyMilliseconds: latency, cost: 0) }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 0 && report.baselineEligible == true)
        #expect(report.averageMilliseconds == latency)
        #expect(try #require(report.p95UpperMilliseconds).isFinite)
        #expect(try #require(report.p95UpperMilliseconds) >= latency)
        _ = try ProductionCodec.encode(report)
    }

    /// Costs beyond the report's numeric range remain finite diagnostic evidence and cannot qualify or receive baseline approval.
    @Test func overflowingReportedCostsFailQualificationWithoutBreakingJSON() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input"), .init(id: "b", prompt: "input")]), job = try fixture.job(dataset)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { .init(requestID: $0.requestID, outcome: .passed, cost: 1e308) }
        let report = try fixture.storage.report(jobID: job.id)
        #expect(report.exitCode == 20 && report.baselineEligible == false)
        #expect(report.reportedCost == .greatestFiniteMagnitude)
        #expect(report.issues.contains("Cost evidence exceeds the supported numeric range."))
        _ = try ProductionCodec.encode(report)
        #expect(throws: ProductionFailure.self) {
            try fixture.storage.approveBaseline(jobID: job.id, expectedJobRevision: job.revision,
                expectedEvidenceRevision: #require(report.evidenceRevision), note: "Cannot approve unrepresentable charges")
        }
    }

    /// A retry whose combined charges overflow pauses with retained output and an outstanding reservation instead of writing infinity.
    @Test func overflowingRetryCostsPauseWithReadableUncertainEvidence() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input"), .init(id: "b", prompt: "input")])
        var configuration = try fixture.job(dataset).configuration
        configuration.maximumCost = .greatestFiniteMagnitude; configuration.maximumCostPerAttempt = 0
        let job = try fixture.storage.createJob(name: "Retry cost overflow", datasetRevision: dataset.revision, configuration: configuration), calls = Calls()
        let count = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker) { request in
            let first = await calls.record(request.requestID)
            return .init(requestID: request.requestID, outcome: first ? .error : .passed, output: "retained", cost: 1e308, retryable: first)
        }
        #expect(count == 1)
        #expect(await calls.total() == 2)
        let record = try fixture.storage.record(jobID: job.id, slot: 0), control = try fixture.storage.control(job)
        #expect(record.response.outcome == .needsEvidence && record.response.cost == nil && record.response.output == "retained")
        #expect(control.paused && control.reportedCost == 1e308 && control.costReservations.count == 1)
        #expect(try fixture.storage.chunk(job, index: 0).attempts[0]?.reportedCost == 1e308)
        _ = try ProductionCodec.encode(control)
        _ = try ProductionCodec.encode(fixture.storage.report(jobID: job.id))
    }

    /// Recovery refuses an overflowing settled charge without changing the finite ledger or the pending cost checkpoint.
    @Test func overflowingCostRecoveryPreservesLedgerAndPendingEvidence() async throws {
        let fixture = try Fixture(), dataset = try fixture.dataset([.init(id: "a", prompt: "input"), .init(id: "b", prompt: "input")])
        var configuration = try fixture.job(dataset).configuration
        configuration.maximumCost = .greatestFiniteMagnitude; configuration.maximumCostPerAttempt = 0
        let job = try fixture.storage.createJob(name: "Recovery cost overflow", datasetRevision: dataset.revision, configuration: configuration)
        _ = try await ProductionBatchRunner(storage: fixture.storage).run(jobID: job.id, worker: fixture.worker, maximumResponses: 1) { .init(requestID: $0.requestID, outcome: .passed, cost: 1e308) }
        var chunk = try #require(try fixture.storage.claim(job, worker: fixture.worker))
        let requestID = fixture.storage.requestID(job, slot: 1)
        try fixture.storage.reserveCost(job, requestID: requestID, slot: 1, attempt: 1)
        var attempt = ProductionAttempt(requestID: requestID, number: 1, startedAt: Date(), worker: fixture.worker)
        attempt.pendingCost = 1e308; attempt.pendingCostAttempt = 1
        chunk.attempts[1] = attempt; chunk.lease = nil
        try ProductionCodec.write(chunk, to: fixture.storage.chunkURL(job, 0))
        #expect(throws: ProductionFailure.self) { try fixture.storage.report(jobID: job.id) }
        #expect(try fixture.storage.control(job).reportedCost == 1e308)
        #expect(try fixture.storage.chunk(job, index: 0).attempts[1]?.pendingCost == 1e308)
    }
}
