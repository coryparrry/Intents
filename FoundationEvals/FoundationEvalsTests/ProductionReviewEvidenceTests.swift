import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct ProductionReviewEvidenceTests {
    /// Reconciliation preserves latency and original evidence, clears only a consumed draft, and retains input edited while saving.
    @Test(arguments: [false, true], [false, true])
    func reconciliationPreservesLatencyAvailability(latencyAvailable: Bool, editsDuringWrite: Bool) async throws {
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
        let draft = ProductionReviewDraft(reviewer: "Reviewer", note: "Verified saved state", outcome: .passed, verifiedOutput: "Verified output", verifiedCost: "0")
        store.updateReviewDraft(draft, jobID: job.id, requestID: record.response.requestID)
        store.appendReview(action: .reconcile, reviewer: "Reviewer", assignee: "", outcome: .passed,
            note: "Verified saved state", tags: "", verifiedOutput: "Verified output", verifiedCost: 0)
        var expectedDraft = ProductionReviewDraft()
        if editsDuringWrite {
            expectedDraft = draft; expectedDraft.verifiedOutput = "Additional evidence entered while saving"
            store.updateReviewDraft(expectedDraft, jobID: job.id, requestID: record.response.requestID)
        }
        await store.closeAndWait()
        #expect(ProductionWorkspaceStore(root: root).reviewDraft(jobID: job.id, requestID: record.response.requestID) == expectedDraft)
        #expect(store.error == nil)
        let review = try storage.review(jobID: job.id, requestID: record.response.requestID)
        #expect(review.response?.latencyAvailable == latencyAvailable)
        #expect(review.response?.latencyMilliseconds == 73)
        let report = try storage.report(jobID: job.id)
        #expect(report.exitCode == (latencyAvailable ? 0 : 20))
        #expect(report.averageMilliseconds == (latencyAvailable ? 73 : nil))
        #expect(try storage.record(jobID: job.id, slot: 0) == record)
    }

    /// Creates two persisted captured results so review drafts can be exercised without a model or private data.
    private func reviewFixture(root: URL) async throws -> (ProductionWorkspaceStore, ProductionJob, [ProductionRecord]) {
        let store = ProductionWorkspaceStore(root: root)
        let storage = try #require(store.storage)
        let source = root.appending(path: "draft-examples.jsonl")
        try Data("{\"id\":\"a\",\"prompt\":\"First\",\"capturedOutput\":\"One\"}\n{\"id\":\"b\",\"prompt\":\"Second\",\"capturedOutput\":\"Two\"}\n".utf8).write(to: source)
        let dataset = try storage.importDataset(from: source, name: "Draft fixture", version: "1")
        let job = try storage.createCapturedJob(name: "Draft fixture", datasetRevision: dataset.revision)
        let worker = ProductionWorker(id: "draft", name: "Fixture", platform: "captured", operatingSystem: "27", hardware: "fixture", locale: "en", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, execute: ProductionStorage.capturedResponse)
        store.jobs = [job]; store.selectedJobID = job.id; store.pane = .review
        return (store, job, try storage.records(jobID: job.id, offset: 0, limit: 50))
    }

    /// Drafts retain every input across result, page, pane, job, and process replacement boundaries.
    @Test func operatorDraftsSurviveNavigationAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-draft-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, job, records) = try await reviewFixture(root: root)
        let first = try #require(records.first), second = try #require(records.last)
        let draft = ProductionReviewDraft(reviewer: "A", assignee: "B", note: "Verified fixture", tags: "format, date", outcome: .passed, verifiedOutput: "Verified output", verifiedCost: "0.25")
        store.selectedRecord = first
        store.updateReviewDraft(draft, jobID: job.id, requestID: first.response.requestID)
        let selection = try #require(store.selectRecord(second)); await selection.value
        #expect(store.reviewDraft(jobID: job.id, requestID: second.response.requestID) == ProductionReviewDraft())
        store.dismissResult(); store.offset = 50; store.pane = .jobs
        store.selectedJobID = UUID()
        #expect(store.reviewDraft(jobID: job.id, requestID: first.response.requestID) == draft)
        await store.closeAndWait()
        let reopened = ProductionWorkspaceStore(root: root)
        #expect(reopened.reviewDraft(jobID: job.id, requestID: first.response.requestID) == draft)
        #expect(reopened.reviewDraftSaveError == nil)
        #expect(try #require(reopened.storage).review(jobID: job.id, requestID: first.response.requestID).events.isEmpty)
    }

    /// An unwritable draft file keeps input in memory, blocks quit, and can be retried without adopting partial bytes.
    @Test func draftWriteFailureRetainsInputAndBlocksTermination() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-draft-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionWorkspaceStore(root: root), job = UUID(), request = UUID()
        let file = root.appending(path: "ProductionReviewDrafts.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let draft = ProductionReviewDraft(reviewer: "A", note: "Retained evidence")
        store.updateReviewDraft(draft, jobID: job, requestID: request)
        #expect(store.reviewDraft(jobID: job, requestID: request) == draft)
        #expect(store.reviewDraftSaveError != nil)
        #expect(throws: (any Error).self) { try store.persistForTermination() }
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: file)
        store.saveReviewDrafts()
        #expect(store.reviewDraftSaveError == nil)
        #expect(ProductionWorkspaceStore(root: root).reviewDraft(jobID: job, requestID: request) == draft)
    }

    /// A failed audit write retains the submitted draft and never invents a successful recorded review.
    @Test func failedAuditWriteRetainsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-audit-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, job, records) = try await reviewFixture(root: root)
        let record = try #require(records.first), storage = try #require(store.storage)
        let draft = ProductionReviewDraft(reviewer: "A", note: "Needs checking")
        store.selectedRecord = record
        store.updateReviewDraft(draft, jobID: job.id, requestID: record.response.requestID)
        let audit = root.appending(path: "ProductionEvals/Reviews/\(job.id.uuidString)-\(record.response.requestID.uuidString).jsonl")
        try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
        let write = try #require(store.appendReview(action: .label, reviewer: draft.reviewer, assignee: "", outcome: .failed, note: draft.note, tags: "", verifiedOutput: "", verifiedCost: nil))
        await write.value
        #expect(store.error != nil)
        #expect(store.reviewDraft(jobID: job.id, requestID: record.response.requestID) == draft)
        try FileManager.default.removeItem(at: audit)
        #expect(try storage.review(jobID: job.id, requestID: record.response.requestID).events.isEmpty)
    }

    /// Label completion retains newer form input and another result's draft through shutdown and reopening.
    @Test func labelCompletionRetainsFormInputAndOtherDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-audit-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, job, records) = try await reviewFixture(root: root)
        let first = try #require(records.first), second = try #require(records.last)
        let draft = ProductionReviewDraft(reviewer: "A", note: "Original evidence")
        store.selectedRecord = first
        store.updateReviewDraft(draft, jobID: job.id, requestID: first.response.requestID)
        let write = try #require(store.appendReview(action: .label, reviewer: draft.reviewer, assignee: "", outcome: .failed, note: draft.note, tags: "", verifiedOutput: "", verifiedCost: nil))
        var edited = draft; edited.note = "New evidence entered while saving"
        store.updateReviewDraft(edited, jobID: job.id, requestID: first.response.requestID)
        store.selectedRecord = second
        store.updateReviewDraft(draft, jobID: job.id, requestID: second.response.requestID)
        await write.value
        #expect(store.reviewDraft(jobID: job.id, requestID: first.response.requestID) == edited)
        #expect(store.reviewDraft(jobID: job.id, requestID: second.response.requestID) == draft)
        store.selectedRecord = first
        _ = try #require(store.appendReview(action: .label, reviewer: edited.reviewer, assignee: "", outcome: .failed, note: edited.note, tags: "", verifiedOutput: "", verifiedCost: nil))
        await store.closeAndWait()
        let reopened = ProductionWorkspaceStore(root: root)
        #expect(reopened.reviewDraft(jobID: job.id, requestID: first.response.requestID) == edited)
        #expect(reopened.reviewDraft(jobID: job.id, requestID: second.response.requestID) == draft)
        #expect(try #require(reopened.storage).review(jobID: job.id, requestID: first.response.requestID).events.count == 2)
    }

    /// Assignment and labels do not consume verified reconciliation evidence, so it survives both actions and reopening.
    @Test func assignmentAndLabelRetainVerifiedOutputAndCost() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-assign-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, job, records) = try await reviewFixture(root: root)
        let record = try #require(records.first)
        let draft = ProductionReviewDraft(reviewer: "A", assignee: "A", note: "Verified pending reconciliation", outcome: .passed, verifiedOutput: "Confirmed app state", verifiedCost: "0.25")
        store.selectedRecord = record
        store.updateReviewDraft(draft, jobID: job.id, requestID: record.response.requestID)
        for action in [ProductionReviewAction.assign, .label] {
            let write = try #require(store.appendReview(action: action, reviewer: draft.reviewer, assignee: draft.assignee, outcome: draft.outcome, note: draft.note, tags: draft.tags, verifiedOutput: draft.verifiedOutput, verifiedCost: Double(draft.verifiedCost)))
            await write.value
            #expect(store.error == nil)
            #expect(store.reviewDraft(jobID: job.id, requestID: record.response.requestID) == draft)
        }
        await store.closeAndWait()
        let reopened = ProductionWorkspaceStore(root: root)
        #expect(reopened.reviewDraft(jobID: job.id, requestID: record.response.requestID) == draft)
        let audit = try #require(reopened.storage).review(jobID: job.id, requestID: record.response.requestID)
        #expect(audit.events.map(\.action) == [.assign, .label])
        #expect(audit.response == nil)
    }

    /// Missing candidate scores never appear as a zero-percent regression, while a genuine zero retains its delta.
    @Test func baselinePresentationRequiresScoredCandidate() {
        #expect(ProductionResultPresentation.baselineComparison(before: 0.9, after: nil).contains("Comparison unavailable"))
        #expect(!ProductionResultPresentation.baselineComparison(before: 0.9, after: nil).contains("-90"))
        #expect(ProductionResultPresentation.baselineComparison(before: 0.9, after: 0).contains("-90.0"))
        #expect(ProductionResultPresentation.baselineComparison(before: 0.9, after: 1).contains("+10.0"))
    }

    /// Schedule rows expose next due time and distinguish paused and exhausted schedules with identical intervals.
    @Test func schedulePresentationRetainsDueTimeAndState() {
        var schedule = ProductionSchedule(templateJobID: UUID(), intervalSeconds: 3600, nextRun: Date(timeIntervalSince1970: 1_800_000_000), remainingRuns: 3)
        #expect(ProductionSchedulePresentation.details(schedule).contains("Next due"))
        #expect(ProductionSchedulePresentation.details(schedule).contains("3 remaining"))
        schedule.paused = true
        #expect(ProductionSchedulePresentation.details(schedule).contains("Paused"))
        schedule.remainingRuns = 0
        #expect(ProductionSchedulePresentation.details(schedule).contains("Complete"))
        #expect(ProductionSchedulePresentation.details(schedule).contains("No further runs"))
    }


    /// Real pending, unscored and error-only reports all leave a candidate comparison unavailable.
    @Test func unscoredBatchStatesDoNotInventBaselineChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-report-states-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, template, _) = try await reviewFixture(root: root)
        let storage = try #require(store.storage)
        let pending = try storage.createCapturedJob(name: "Pending", datasetRevision: template.datasetRevision)
        #expect(try storage.report(jobID: pending.id).counts.passRate == nil)
        #expect(try storage.report(jobID: template.id).counts.passRate == nil)
        let errors = try storage.createCapturedJob(name: "Errors", datasetRevision: template.datasetRevision)
        let worker = ProductionWorker(id: "error", name: "Fixture", platform: "captured", operatingSystem: "27", hardware: "fixture", locale: "en", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: errors.id, worker: worker) {
            .init(requestID: $0.requestID, outcome: .error, explanation: "Synthetic failure", cost: 0)
        }
        for id in [pending.id, template.id, errors.id] {
            let report = try storage.report(jobID: id)
            #expect(ProductionResultPresentation.baselineComparison(before: 0.9, after: report.counts.passRate).contains("Comparison unavailable"))
        }
    }

    /// A stopped-writer directory snapshot restores every independent evidence root and reloads native records without merging stores.
    @Test func completeBackupRestoresIndependentEvidenceRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "operator-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source"), backup = root.appending(path: "backup"), restored = root.appending(path: "restored")
        let native = source.appending(path: "FoundationEvals")
        let (store, job, records) = try await reviewFixture(root: native)
        let record = try #require(records.first)
        let draft = ProductionReviewDraft(reviewer: "Fixture", note: "Private synthetic evidence")
        store.updateReviewDraft(draft, jobID: job.id, requestID: record.response.requestID)
        let fixtureFiles = [
            "Intents/SiriStudio/Scenarios/fixture.json": "{\"bundleIdentifier\":\"example.fixture\"}",
            "Intents/SiriStudio/Runs/fixture/report.json": "{\"state\":\"blocked\"}",
            "Intents/MacIntentTesting/Runs/fixture/run.log": "Synthetic native diagnostic",
            "plugin/projects.json": "{\"projects\":[]}",
            "CLI/custom-store/fixture.json": "{\"synthetic\":true}",
            "preferences.plist": "Synthetic preference export"
        ]
        for (path, value) in fixtureFiles {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }
        await store.closeAndWait()
        try FileManager.default.copyItem(at: source, to: backup)
        try FileManager.default.copyItem(at: backup, to: restored)
        let originalFiles = try fileBytes(in: source)
        #expect(try fileBytes(in: backup) == originalFiles)
        #expect(try fileBytes(in: restored) == originalFiles)
        let reopened = ProductionWorkspaceStore(root: restored.appending(path: "FoundationEvals"))
        #expect(reopened.reviewDraft(jobID: job.id, requestID: record.response.requestID) == draft)
        let storage = try #require(reopened.storage)
        #expect(try storage.record(jobID: job.id, slot: record.slot) == record)
        #expect(try storage.report(jobID: job.id).completed == 2)
    }

    /// Uses enumerator-relative names so macOS /var aliases do not change backup inventory keys.
    private func fileBytes(in root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
        var result: [String: Data] = [:]
        for case let relativePath as String in enumerator {
            let file = root.appending(path: relativePath)
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[relativePath] = try Data(contentsOf: file)
            }
        }
        return result
    }

}
