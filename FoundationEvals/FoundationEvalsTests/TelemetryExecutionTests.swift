import Foundation
import MacIntentTesting
import Testing
@testable import FoundationEvals

/// Exercises content-free telemetry at the real batch and local App Intent store boundaries.
@MainActor struct TelemetryExecutionTests {
    /// Counts persisted batch completion even when assertions fail, while runtime/uncertain evidence fails diagnostics.
    @Test(arguments: [ProductionOutcome.passed, .failed, .error, .needsEvidence])
    func batchOutcomesFollowDurableEvidence(outcome: ProductionOutcome) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, capturedExecutor: { request in
            .init(requestID: request.requestID, outcome: outcome, output: "Private fixture output", cost: 0)
        })
        let job = try makeBatch(model: model, root: fixture.root)
        try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
        await model.waitForRun()
        let failed = outcome == .error || outcome == .needsEvidence
        let finish = try #require(fixture.finished(.batchRun).first)
        #expect(fixture.started(.batchRun).count == 1)
        #expect(fixture.finished(.batchRun).count == 1)
        #expect(finish.properties["outcome"] as? String == (failed ? "failed" : "succeeded"))
        #expect(finish.properties["error_code"] as? String == (outcome == .error ? "generation" : outcome == .needsEvidence ? "evidence" : nil))
        #expect(fixture.features(.batchRun).count == (failed ? 0 : 1))
        #expect(try model.storage?.records(jobID: job.id).count == 1)
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Reopening completed work has a balanced diagnostic span without counting the same completed batch twice.
    @Test func completedBatchRetryDoesNotRepeatAdoption() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root)
        let job = try makeBatch(model: model, root: fixture.root)
        for _ in 0..<2 {
            try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
            await model.waitForRun()
        }
        #expect(fixture.started(.batchRun).count == 2)
        #expect(fixture.finished(.batchRun).count == 2)
        #expect(fixture.features(.batchRun).count == 1)
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Terminal telemetry is published while execution is still owned, before UI refresh can release waiters.
    @Test func batchPublishesTerminalEventBeforeReleasingOwnership() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root)
        let job = try makeBatch(model: model, root: fixture.root)
        var ownedAtFinish = false
        fixture.client.onCapture = { event in
            if event.name == "foundation_evals_operation_finished",
               event.properties["operation"] as? String == "batch_run" {
                ownedAtFinish = model.runningJobID == job.id
            }
        }
        try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
        await model.waitForRun()
        #expect(ownedAtFinish)
        #expect(fixture.finished(.batchRun).count == 1)
        #expect(model.runningJobID == nil)
        fixture.client.onCapture = nil
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Work for another target can remain pending after this worker exits without falsely completing the whole batch.
    @Test func partialBatchDoesNotCountCompletedAdoption() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root)
        let template = try makeBatch(model: model, root: fixture.root)
        let storage = try #require(model.storage)
        var configuration = template.configuration
        configuration.targets.append(.init(platform: "other-fixture-platform"))
        let job = try storage.createJob(name: "Two-target fixture", datasetRevision: template.datasetRevision,
                                        configuration: configuration)
        try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
        await model.waitForRun()
        #expect(fixture.finished(.batchRun).count == 1)
        #expect(fixture.features(.batchRun).isEmpty)
        let report = try storage.report(jobID: job.id)
        #expect(report.completed == 1 && report.planned == 2)
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Cancellation records one terminal cancellation even though the batch runner journals an interrupted response.
    @Test(.timeLimit(.minutes(1))) func cancellingBatchDoesNotCountCompletion() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        let model = ProductionWorkspaceStore(root: fixture.root, capturedExecutor: { _ in
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(300))
            throw CancellationError()
        })
        let job = try makeBatch(model: model, root: fixture.root)
        try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        model.interrupt(jobID: job.id)
        await model.waitForRun()
        await model.closeAndWait()
        #expect(fixture.finished(.batchRun).count == 1)
        #expect(fixture.finished(.batchRun).first?.properties["outcome"] as? String == "cancelled")
        #expect(fixture.features(.batchRun).isEmpty)
        await fixture.store.closeAndWait()
    }

    /// A response that cannot be committed to storage is a failed operation rather than successful batch adoption.
    @Test func batchPersistenceFailurePreventsAdoption() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let storage = try ProductionStorage(root: fixture.root.appendingPathComponent("ProductionEvals"))
        let model = ProductionWorkspaceStore(root: fixture.root, capturedExecutor: { request in
            let chunk = storage.jobDirectory(request.jobID).appendingPathComponent("Chunks/0.json")
            try FileManager.default.removeItem(at: chunk)
            try FileManager.default.createDirectory(at: chunk, withIntermediateDirectories: false)
            return .init(requestID: request.requestID, outcome: .passed, cost: 0)
        })
        let job = try makeBatch(model: model, root: fixture.root)
        try model.start(job: job, store: fixture.store, externalDisclosureApproved: false)
        await model.waitForRun()
        #expect(fixture.finished(.batchRun).count == 1)
        #expect(fixture.finished(.batchRun).first?.properties["error_code"] as? String == "storage")
        #expect(fixture.features(.batchRun).isEmpty)
        #expect(model.executionErrors[job.id] != nil)
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Local intent outcomes use fixed categories and never include the authored inputs, result summary or evidence paths.
    @Test(arguments: ["success", "failed", "network", "cancelled", "validation"])
    func localIntentExecutionBalancesOutcomes(mode: String) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let store = MacIntentTestingStore(telemetry: fixture.controller, runOverride: { catalog, _, _ in
            if mode == "network" { throw URLError(.cannotConnectToHost) }
            if mode == "cancelled" { throw CancellationError() }
            return .init(succeeded: mode == "success", resultBundleURL: catalog.appURL,
                         logURL: catalog.appURL, summary: "Private fixture response")
        }, catalogLoader: { app in
            .init(bundleIdentifier: "private.fixture", appURL: app,
                  actions: [.init(id: "Private action", title: "Private fixture title", parameters: [], outputType: "String")])
        })
        store.signingIdentity = "Private fixture signing identity"
        store.teamIdentifier = "Private fixture team"
        store.inputsJSON = mode == "validation" ? "[]" : "{\"private\":\"fixture input\"}"
        store.load(appURL: fixture.root.appendingPathComponent("Private fixture.app"))
        await store.waitForLoad()
        store.start()
        await store.waitForRun()
        await store.closeAndWait()
        #expect(fixture.started(.appIntentRun).count == 1)
        #expect(fixture.finished(.appIntentRun).count == 1)
        let finish = try #require(fixture.finished(.appIntentRun).first)
        let expectedCode: String? = switch mode {
        case "success": nil
        case "failed": "test_failure"
        case "cancelled": "cancelled"
        default: mode
        }
        #expect(finish.properties["error_code"] as? String == expectedCode)
        #expect(fixture.features(.appIntentRun).count == (mode == "success" ? 1 : 0))
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await fixture.store.closeAndWait()
    }

    /// Cancellation remains cancellation when a local native runner returns a failed verdict instead of throwing.
    @Test(.timeLimit(.minutes(1))) func cancelledLocalVerdictIsNotReportedAsTestFailure() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        let store = MacIntentTestingStore(telemetry: fixture.controller, runOverride: { catalog, _, _ in
            entered.continuation.yield(())
            try? await Task.sleep(for: .seconds(300))
            return .init(succeeded: false, resultBundleURL: nil, logURL: catalog.appURL, summary: "Cancelled")
        }, catalogLoader: { app in
            .init(bundleIdentifier: "fixture", appURL: app,
                  actions: [.init(id: "Echo", title: "Echo", parameters: [], outputType: "String")])
        })
        store.signingIdentity = "fixture"; store.teamIdentifier = "fixture"
        store.load(appURL: fixture.root)
        await store.waitForLoad()
        store.start()
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        await store.closeAndWait()
        #expect(fixture.finished(.appIntentRun).count == 1)
        #expect(fixture.finished(.appIntentRun).first?.properties["outcome"] as? String == "cancelled")
        #expect(fixture.features(.appIntentRun).isEmpty)
        await fixture.store.closeAndWait()
    }

    /// File imports and draft snapshots report durable publication even while shutdown drains their work; failed writes never count use.
    @Test(arguments: ["file", "snapshot"], [false, true])
    func datasetImportTelemetryFollowsDurableStorageDuringClose(source: String, failWrite: Bool) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, telemetry: fixture.controller)
        let storage = try #require(model.storage)
        let datasets = storage.root.appendingPathComponent("Datasets")
        if failWrite { try replaceEmptyDirectoryWithFile(datasets) }
        var persistedAtFinish = false
        fixture.client.onCapture = { event in
            if event.name == "foundation_evals_operation_finished",
               event.properties["operation"] as? String == "dataset_import" {
                persistedAtFinish = (try? storage.datasets().count) == 1
            }
        }
        if source == "file" {
            let file = fixture.root.appendingPathComponent("Private fixture import.jsonl")
            var data = try ProductionCodec.encode(ProductionExample(id: "fixture", prompt: "Private fixture prompt", capturedOutput: "Private fixture output"))
            data.append(10)
            try data.write(to: file)
            model.importDataset(file: file, name: "Private fixture dataset", version: "1", sampling: .curated,
                                productionData: false, confirmed: false)
        } else {
            fixture.store.draftSuite.cases = [.init(name: "Private fixture case", prompt: "Private fixture prompt", expected: "Private fixture expectation")]
            model.snapshotDataset(store: fixture.store)
        }
        await model.closeAndWait()
        fixture.client.onCapture = nil
        #expect(persistedAtFinish == !failWrite)
        #expect(fixture.started(.datasetImport).count == 1)
        #expect(fixture.finished(.datasetImport).count == 1)
        #expect(fixture.finished(.datasetImport).first?.properties["outcome"] as? String == (failWrite ? "failed" : "succeeded"))
        #expect(fixture.finished(.datasetImport).first?.properties["error_code"] as? String == (failWrite ? "storage" : nil))
        #expect(fixture.features(.datasetImported).count == (failWrite ? 0 : 1))
        if failWrite { try restoreEmptyDirectory(datasets) }
        #expect(try storage.datasets().count == (failWrite ? 0 : 1))
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await fixture.store.closeAndWait()
    }

    /// Reimporting identical file bytes or the same draft balances both operations but counts only the first durable dataset publication.
    @Test(arguments: ["file", "snapshot"])
    func repeatedDatasetImportDoesNotRepeatAdoption(source: String) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, telemetry: fixture.controller)
        let storage = try #require(model.storage)
        let file = fixture.root.appendingPathComponent("Private fixture repeated import.jsonl")
        var data = try ProductionCodec.encode(ProductionExample(id: "fixture", prompt: "Private fixture prompt", capturedOutput: "Private fixture output"))
        data.append(10)
        try data.write(to: file)
        fixture.store.draftSuite.cases = [.init(name: "Private fixture case", prompt: "Private fixture prompt", expected: "Private fixture expectation")]
        for _ in 0..<2 {
            let task: Task<Void, Never>?
            if source == "file" {
                task = model.importDataset(file: file, name: "Private fixture dataset", version: "1", sampling: .curated,
                                           productionData: false, confirmed: false)
            } else {
                task = model.snapshotDataset(store: fixture.store)
            }
            await (try #require(task)).value
        }
        let starts = fixture.started(.datasetImport)
        let finishes = fixture.finished(.datasetImport)
        #expect(starts.count == 2 && finishes.count == 2)
        #expect(Set(starts.compactMap { $0.properties["operation_id"] as? String }) == Set(finishes.compactMap { $0.properties["operation_id"] as? String }))
        #expect(finishes.allSatisfy { $0.properties["outcome"] as? String == "succeeded" && $0.properties["error_code"] == nil })
        #expect(fixture.features(.datasetImported).count == 1)
        #expect(try storage.datasets().count == 1)
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await model.closeAndWait()
        await fixture.store.closeAndWait()
    }

    /// Review adoption requires the actual append-only audit write, including storage failures after valid review admission.
    @Test(arguments: [false, true])
    func reviewTelemetryRequiresPersistedAudit(failWrite: Bool) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, telemetry: fixture.controller)
        let job = try makeBatch(model: model, root: fixture.root)
        let storage = try #require(model.storage)
        let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "fixture",
                                      hardware: "fixture", locale: "en_GB", model: "fixture")
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, execute: ProductionStorage.capturedResponse)
        let record = try storage.record(jobID: job.id, slot: 0)
        model.jobs = [job]; model.selectedJobID = job.id; model.selectedRecord = record
        let reviews = storage.root.appendingPathComponent("Reviews")
        if failWrite { try replaceEmptyDirectoryWithFile(reviews) }
        model.appendReview(action: .label, reviewer: "Private fixture reviewer", assignee: "", outcome: .passed,
                           note: "Private fixture note", tags: "Private fixture tag", verifiedOutput: "", verifiedCost: nil)
        await model.closeAndWait()
        #expect(fixture.started(.reviewSave).count == 1)
        #expect(fixture.finished(.reviewSave).count == 1)
        #expect(fixture.finished(.reviewSave).first?.properties["outcome"] as? String == (failWrite ? "failed" : "succeeded"))
        #expect(fixture.finished(.reviewSave).first?.properties["error_code"] as? String == (failWrite ? "storage" : nil))
        #expect(fixture.features(.reviewSaved).count == (failWrite ? 0 : 1))
        if failWrite { try restoreEmptyDirectory(reviews) }
        let saved = try storage.review(jobID: job.id, requestID: record.response.requestID)
        #expect(saved.events.count == (failWrite ? 0 : 1))
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await fixture.store.closeAndWait()
    }

    /// Export completion follows the published evidence directory; destination write failure produces no adoption or partial bundle.
    @Test(arguments: [false, true])
    func resultExportTelemetryRequiresPublishedBundle(failWrite: Bool) async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, telemetry: fixture.controller)
        let job = try makeBatch(model: model, root: fixture.root)
        let exportParent = fixture.root.appendingPathComponent("Private fixture exports")
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: false)
        if failWrite { try replaceEmptyDirectoryWithFile(exportParent) }
        let destination = exportParent.appendingPathComponent("Private fixture evidence")
        let task = try #require(model.export(jobID: job.id, to: destination))
        await task.value
        await model.closeAndWait()
        #expect(fixture.started(.resultExport).count == 1)
        #expect(fixture.finished(.resultExport).count == 1)
        #expect(fixture.finished(.resultExport).first?.properties["outcome"] as? String == (failWrite ? "failed" : "succeeded"))
        #expect(fixture.finished(.resultExport).first?.properties["error_code"] as? String == (failWrite ? "storage" : nil))
        #expect(fixture.features(.resultsExported).count == (failWrite ? 0 : 1))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report.json").path) == !failWrite)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Dataset/manifest.json").path) == !failWrite)
        #expect(!fixture.controller.diagnosticReport().contains("Private fixture"))
        await fixture.store.closeAndWait()
    }

    /// Unclassified storage maintenance remains silent instead of borrowing an unrelated feature category.
    @Test func untaggedStorageWorkDoesNotCreateOperationOrFeatureEvents() async throws {
        let fixture = try ExecutionTelemetryFixture()
        defer { fixture.remove() }
        let model = ProductionWorkspaceStore(root: fixture.root, telemetry: fixture.controller)
        let before = fixture.client.events.count
        let task = try #require(model.perform { storage in try storage.datasets().count })
        await task.value
        await model.closeAndWait()
        #expect(fixture.client.events.count == before)
        await fixture.store.closeAndWait()
    }

    /// Replaces an empty fixture directory with a regular file so child writes fail deterministically without permission changes.
    private func replaceEmptyDirectoryWithFile(_ url: URL) throws {
        #expect(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).isEmpty)
        try FileManager.default.removeItem(at: url)
        try Data("fixture storage blocker".utf8).write(to: url)
    }

    /// Restores an empty fixture directory after a deterministic blocked-child-write check.
    private func restoreEmptyDirectory(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Creates a one-slot captured-output batch in isolated durable storage.
    private func makeBatch(model: ProductionWorkspaceStore, root: URL) throws -> ProductionJob {
        let storage = try #require(model.storage)
        let input = root.appendingPathComponent("input.jsonl")
        var data = try ProductionCodec.encode(ProductionExample(id: "fixture", prompt: "Private fixture prompt", capturedOutput: "Original"))
        data.append(10)
        try data.write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Private fixture dataset", version: "1")
        return try storage.createCapturedJob(name: "Private fixture batch", datasetRevision: dataset.revision)
    }
}

/// Isolates real store persistence and consent preferences while capturing telemetry without a network destination.
@MainActor private final class ExecutionTelemetryFixture {
    let root: URL
    let controller: TelemetryController
    let client: ExecutionTelemetryClient
    let store: EvaluationStore
    private let defaults: UserDefaults
    private let defaultsName: String

    /// Enables both independent telemetry permissions against an in-memory client and a temporary workspace.
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryExecution-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsName = "TelemetryExecution.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: TelemetryController.consentKey)
        defaults.set(true, forKey: TelemetryController.diagnosticsConsentKey)
        let client = ExecutionTelemetryClient()
        self.client = client
        controller = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_fixture", host: "https://telemetry.invalid"),
            makeClient: { _ in client }, discardPendingCrashes: {})
        store = EvaluationStore(supportDirectory: root, telemetry: controller)
    }

    /// Removes only this fixture's temporary workspace and named preference domain.
    func remove() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    /// Selects recorded operation starts without including unrelated workspace initialization telemetry.
    func started(_ operation: TelemetryOperation) -> [TelemetryEvent] {
        client.events.filter { $0.name == "foundation_evals_operation_started" && $0.properties["operation"] as? String == operation.rawValue }
    }

    /// Selects recorded terminal operation events for the operation under test.
    func finished(_ operation: TelemetryOperation) -> [TelemetryEvent] {
        client.events.filter { $0.name == "foundation_evals_operation_finished" && $0.properties["operation"] as? String == operation.rawValue }
    }

    /// Selects successful usage events for the fixed feature category under test.
    func features(_ feature: TelemetryFeature) -> [TelemetryEvent] {
        client.events.filter { $0.name == "intents_feature_used" && $0.properties["feature"] as? String == feature.rawValue }
    }
}

/// Retains typed events in memory and never initializes a production SDK or opens a connection.
@MainActor private final class ExecutionTelemetryClient: TelemetryClient {
    var events: [TelemetryEvent] = []
    var onCapture: ((TelemetryEvent) -> Void)?
    /// Records the typed event and lets fixtures observe ownership synchronously at the publication boundary.
    func capture(_ event: TelemetryEvent) {
        events.append(event)
        onCapture?(event)
    }
    /// Has no pending transport work to discard.
    func stopAndDiscard() {}
}
