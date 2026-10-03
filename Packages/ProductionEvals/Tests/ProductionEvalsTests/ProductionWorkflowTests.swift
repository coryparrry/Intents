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
}
