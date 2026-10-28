import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct TelemetryWorkflowTests {
    /// Exercises the real generation controller with reviewed synthetic cases and a failing generator.
    @Test(arguments: [false, true]) func documentGenerationRecordsDurableSuccessAndFailure(fails: Bool) async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let controller = fixture.documentController(generate: { source, passage, _, existing, _ in
            if fails { throw URLError(.cannotConnectToHost) }
            return Self.documentCase(source: source, passage: passage, index: existing.count)
        })
        controller.generate()
        await controller.waitUntilIdle()
        #expect(fixture.features("document_generated").count == (fails ? 0 : 1))
        #expect(fixture.finishes("document_generate").last?.properties["outcome"] as? String == (fails ? "failed" : "succeeded"))
        if !fails {
            #expect(controller.draft?.cases.count == 5)
            let restored = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID)
            #expect(restored.draft?.cases.count == 5)
            // Repeating an already-completed request performs no generation and must not count another use.
            controller.generate()
            await controller.waitUntilIdle()
            #expect(fixture.features("document_generated").count == 1)
            #expect(fixture.finishes("document_generate").last?.properties["outcome"] as? String == "succeeded")
        }
        fixture.assertPrivateContentAbsent()
    }

    /// Resumes an exhausted persisted draft as incomplete until explicitly retried failures produce the requested saved cases.
    @Test(arguments: [false, true])
    func exhaustedSavedGenerationRequiresSuccessfulRetry(retryFailures: Bool) async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let saved = fixture.documentController(generate: { _, _, _, _, _ in
            Issue.record("Preparing the saved draft must not generate a case")
            return nil
        })
        let initial = try #require(saved.draft)
        let passage = try #require(initial.source.passages.first)
        saved.draft?.cases = [.init(evaluationCase: Self.documentCase(source: initial.source, passage: passage, index: 0))]
        for slot in 0..<(initial.requestedCount * 2) {
            let batchID = "\(passage.id):\(slot)"
            saved.draft?.completedBatchIDs.insert(batchID)
            if slot > 0 { saved.draft?.issues[batchID] = "Private workflow saved generation failure" }
        }
        try #require(saved.persist())
        let controller = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID,
            telemetry: fixture.recorder, generate: { source, passage, _, existing, _ in
                #expect(retryFailures)
                return Self.documentCase(source: source, passage: passage, index: existing.count)
            }, reviewerFactory: { _ in DocumentTestFixture.semanticReviewer }, availability: { nil })
        #expect(controller.draft?.cases.count == 1)
        controller.generate(retryFailures: retryFailures)
        await controller.waitUntilIdle()
        let expectedCount = retryFailures ? 5 : 1
        #expect(controller.draft?.cases.count == expectedCount)
        let restored = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID)
        #expect(restored.draft?.cases.count == expectedCount)
        #expect(fixture.features("document_generated").count == (retryFailures ? 1 : 0))
        #expect(fixture.finishes("document_generate").count == 1)
        #expect(fixture.finishes("document_generate").last?.properties["outcome"] as? String == (retryFailures ? "succeeded" : "failed"))
        #expect(fixture.finishes("document_generate").last?.properties["error_code"] as? String == (retryFailures ? nil : "generation"))
        fixture.assertPrivateContentAbsent()
    }

    /// Imports real synthetic source files and requires extraction plus durable draft storage for adoption.
    @Test(arguments: ["success", "invalid", "storage"])
    func documentSourceImportUsesTheActualExtractionOutcome(outcome: String) async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appending(path: "private-workflow-source.md")
        try (outcome == "invalid" ? Data([0xff]) : Data("Synthetic source paragraph.".utf8)).write(to: source)
        let controller = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID, telemetry: fixture.recorder)
        if outcome == "storage" { try Data("blocked".utf8).write(to: fixture.directory.appending(path: "DocumentDrafts")) }
        controller.importFile(source, selection: nil)
        await controller.waitUntilIdle()
        #expect(fixture.features("document_imported").count == (outcome == "success" ? 1 : 0))
        #expect(fixture.finishes("document_import").last?.properties["outcome"] as? String == (outcome == "success" ? "succeeded" : "failed"))
        if outcome == "success" {
            let restored = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID)
            #expect(restored.draft?.source.passages.first?.text == "Synthetic source paragraph.")
        }
        fixture.assertPrivateContentAbsent()
    }

    /// Exercises selected-file and direct reference imports, excluding duplicate retries and failed reads from adoption.
    @Test func referenceImportsCountNewPersistedAttachmentsOnly() async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let store = EvaluationStore(supportDirectory: fixture.directory, telemetry: fixture.recorder)
        let source = fixture.directory.appending(path: "private-workflow-reference.txt")
        let data = Data("Synthetic reference.".utf8)
        try data.write(to: source)
        await store.importFiles([source])?.value
        #expect(fixture.features("references_imported").count == 1)
        let imported = try #require(store.suite.attachments.first)
        let duplicate = try await store.importAttachment(id: imported.id, name: source.lastPathComponent,
            mediaType: "text/plain", data: data, expectedRevision: "stale")
        #expect(duplicate.duplicate)
        #expect(fixture.features("references_imported").count == 1)
        let direct = try await store.importAttachment(id: UUID(), name: "second.txt", mediaType: "text/plain",
            data: data, expectedRevision: store.suiteRevision)
        #expect(!direct.duplicate)
        #expect(fixture.features("references_imported").count == 2)
        await store.importFiles([fixture.directory.appending(path: "missing.txt")])?.value
        #expect(fixture.features("references_imported").count == 2)
        #expect(fixture.finishes("reference_import").last?.properties["outcome"] as? String == "failed")
        await #expect(throws: (any Error).self) {
            try await store.importAttachment(id: UUID(), name: "../invalid.txt", mediaType: "text/plain",
                data: data, expectedRevision: store.suiteRevision)
        }
        #expect(fixture.features("references_imported").count == 2)
        fixture.assertPrivateContentAbsent()
    }

    /// Recovers from an exhausted semantic rejection or transient request failure and records the completed saved batch.
    @Test(arguments: ["rejected", "transient"])
    func recoveredGenerationAttemptsDoNotFailTheCompletedBatch(initialFailure: String) async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let generationAttempts = WorkflowAttemptCounter()
        let reviewAttempts = WorkflowAttemptCounter()
        let controller = fixture.documentController(generate: { source, passage, _, existing, _ in
            let attempt = await generationAttempts.next()
            if initialFailure == "transient", attempt == 1 { throw URLError(.cannotConnectToHost) }
            return Self.documentCase(source: source, passage: passage, index: existing.count)
        }, reviewer: { candidate, source, questions in
            let attempt = await reviewAttempts.next()
            var review = try await DocumentTestFixture.semanticReviewer(candidate, source, questions)
            if initialFailure == "rejected", attempt <= EvaluationDocumentDraftPipeline.maximumAttempts {
                review.checks[0].score = 1
            }
            return review
        })
        controller.generate()
        await controller.waitUntilIdle()
        #expect(controller.draft?.cases.count == 5)
        let restored = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID)
        #expect(restored.draft?.cases.count == 5)
        #expect(fixture.features("document_generated").count == 1)
        #expect(fixture.finishes("document_generate").count == 1)
        #expect(fixture.finishes("document_generate").last?.properties["outcome"] as? String == "succeeded")
        let issues = fixture.client.events.filter { $0.name == "foundation_evals_diagnostic_issue" }
        #expect(issues.count == 1)
        #expect(issues.first?.properties["error_code"] as? String == (initialFailure == "rejected" ? "generation" : "network"))
        fixture.assertPrivateContentAbsent()
    }

    /// Cancels real suspended generation and ensures its late completion cannot report adoption twice.
    @Test func documentCancellationEndsOnceWithoutAdoption() async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let entered = AsyncStream<Void>.makeStream()
        let controller = fixture.documentController(generate: { _, _, _, _, _ in
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            return nil
        })
        controller.generate()
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        controller.cancel()
        // A second cancellation must not finish the already-ended span again.
        controller.cancel()
        #expect(fixture.finishes("document_generate").count == 1)
        #expect(fixture.finishes("document_generate").first?.properties["outcome"] as? String == "cancelled")
        #expect(fixture.features("document_generated").isEmpty)
        entered.continuation.finish()
    }

    /// Refuses adoption when generation cannot persist its draft, before any model request is made.
    @Test func documentWriteFailureIsNotSuccessfulGeneration() async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let controller = fixture.documentController(generate: { _, _, _, _, _ in
            Issue.record("Generation must not start after persistence fails")
            return nil
        })
        try Data("blocked".utf8).write(to: fixture.directory.appending(path: "DocumentDrafts"))
        controller.generate()
        await controller.waitUntilIdle()
        #expect(fixture.features("document_generated").isEmpty)
        #expect(fixture.finishes("document_generate").last?.properties["error_code"] as? String == "storage")
    }

    /// Imports cases through the store, recording capacity failures and excluding empty requests from adoption.
    @Test func caseImportRecordsStoreCompletionAndValidationFailure() throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let store = EvaluationStore(supportDirectory: fixture.directory, telemetry: fixture.recorder)
        let count = store.draftSuite.cases.count
        try store.appendImportedCases([.init(name: "Synthetic case", prompt: "Private workflow prompt", expected: "Synthetic answer")])
        #expect(store.suite.cases.count == count + 1)
        #expect(fixture.features("suite_imported").count == 1)
        try store.appendImportedCases([])
        let overflow = (0...store.remainingCaseImportCapacity).map { EvaluationCase(name: "Case \($0)", prompt: "Prompt", expected: "Answer") }
        #expect(throws: EvaluationCaseImportError.self) { try store.appendImportedCases(overflow) }
        #expect(fixture.features("suite_imported").count == 1)
        #expect(fixture.finishes("suite_import").last?.properties["error_code"] as? String == "validation")
        fixture.assertPrivateContentAbsent()
    }

    /// Requires an imported archive to persist its draft before recording successful suite import.
    @Test(arguments: [false, true]) func archiveImportRecordsPersistenceOutcome(blockWrites: Bool) throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let file = fixture.directory.appending(path: "private-workflow-archive.json")
        try EvaluationDocumentArchive.data(for: DocumentTestFixture.suite()).write(to: file)
        let controller = EvaluationDocumentDraftController(directory: fixture.directory, projectID: fixture.projectID, telemetry: fixture.recorder)
        if blockWrites { try Data("blocked".utf8).write(to: fixture.directory.appending(path: "DocumentDrafts")) }
        controller.importArchive(file)
        #expect(fixture.features("suite_imported").count == (blockWrites ? 0 : 1))
        #expect(fixture.finishes("suite_import").last?.properties["outcome"] as? String == (blockWrites ? "failed" : "succeeded"))
        fixture.assertPrivateContentAbsent()
    }

    /// Distinguishes serialization, actual disk-write success, disk failure, and user cancellation.
    @Test(arguments: ["success", "failure", "cancel", "consent"], [TelemetryOperation.suiteExport, .resultExport])
    func exportWaitsForFileCompletion(outcome: String, operation: TelemetryOperation) throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let controller = TelemetryFileExportController()
        let data = try controller.prepare(operation, telemetry: fixture.recorder) { try EvaluationDocumentArchive.data(for: DocumentTestFixture.suite()) }
        let feature = operation == .suiteExport ? "suite_exported" : "results_exported"
        #expect(fixture.features(feature).isEmpty)
        #expect(fixture.finishes(operation.rawValue).isEmpty)
        if outcome == "consent" {
            fixture.recorder.setEnabled(false)
            fixture.recorder.setEnabled(true)
        }
        if outcome == "cancel" { controller.cancel() }
        else {
            let destination = fixture.directory.appending(path: "private-workflow-export.json")
            if outcome == "failure" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
            let result = Result<URL, any Error> {
                try data.write(to: destination, options: .atomic)
                return destination
            }
            controller.complete(result)
            controller.complete(result)
        }
        #expect(fixture.features(feature).count == (outcome == "success" ? 1 : 0))
        if outcome != "consent" { #expect(fixture.finishes(operation.rawValue).count == 1) }
        if outcome == "cancel" { #expect(fixture.finishes(operation.rawValue).last?.properties["outcome"] as? String == "cancelled") }
        if outcome == "failure" { #expect(fixture.finishes(operation.rawValue).last?.properties["outcome"] as? String == "failed") }
        fixture.assertPrivateContentAbsent()
    }

    /// Serialization failures end the export operation without ever opening or completing a destination.
    @Test func invalidArchiveDoesNotCountAsExport() throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let controller = TelemetryFileExportController()
        #expect(throws: EvaluationStoreError.self) { try controller.prepare(.suiteExport, telemetry: fixture.recorder) { try EvaluationDocumentArchive.data(for: EvaluationSuite()) } }
        #expect(fixture.features("suite_exported").isEmpty)
        #expect(fixture.finishes("suite_export").last?.properties["outcome"] as? String == "failed")
    }

    /// Ignores a replaced asynchronous preparation's late bytes, failure, and completion while preserving the newer export.
    @Test(arguments: ["success", "failure"])
    func lateFeedbackPreparationCannotReplaceOrFinishANewerExport(outcome: String) async throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        let controller = TelemetryFileExportController()
        let older = controller.begin(.resultExport, telemetry: fixture.recorder)
        let release = AsyncStream<Void>.makeStream()
        var publishedDocument = Data()
        let latePreparation = Task {
            for await _ in release.stream { break }
            if outcome == "success" {
                controller.publish(ifCurrent: older) { publishedDocument = Data("Old feedback".utf8) }
                controller.complete(.success(fixture.directory.appending(path: "old.json")), for: older)
            } else {
                controller.fail(URLError(.cannotConnectToHost), for: older)
            }
            controller.cancel(ifCurrent: older)
        }
        let newer = controller.begin(.resultExport, telemetry: fixture.recorder)
        controller.publish(ifCurrent: newer) { publishedDocument = Data("New transcript".utf8) }
        release.continuation.yield(())
        release.continuation.finish()
        await latePreparation.value
        #expect(publishedDocument == Data("New transcript".utf8))
        #expect(fixture.finishes("results_export").count == 1)
        #expect(fixture.finishes("results_export").first?.properties["outcome"] as? String == "cancelled")
        #expect(fixture.features("results_exported").isEmpty)
        let destination = fixture.directory.appending(path: "new.json")
        try publishedDocument.write(to: destination)
        controller.complete(.success(destination), for: newer)
        #expect(fixture.finishes("results_export").count == 2)
        #expect(fixture.finishes("results_export").last?.properties["outcome"] as? String == "succeeded")
        #expect(fixture.features("results_exported").count == 1)
    }

    /// Exercises actual review validation and rollback instead of directly asking the recorder to emit a feature.
    @Test func reviewSaveRecordsOnlyPersistedChanges() throws {
        let fixture = try WorkflowTelemetryFixture()
        defer { fixture.remove() }
        var failWrites = false
        let store = EvaluationStore(supportDirectory: fixture.directory, telemetry: fixture.recorder, suiteLocalStateWriter: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let annotation = try installReviewSample(in: store)
        try store.saveReview(annotation)
        #expect(fixture.features("review_saved").count == 1)
        failWrites = true
        var replacement = annotation
        replacement.note = "Private workflow note"
        #expect(throws: EvaluationStoreError.self) { try store.saveReview(replacement) }
        #expect(store.suiteLocalState.review.annotations.first?.note == annotation.note)
        #expect(fixture.finishes("review_save").last?.properties["error_code"] as? String == "storage")
        failWrites = false
        replacement.sampleID = UUID()
        #expect(throws: EvaluationReviewError.self) { try store.saveReview(replacement) }
        #expect(fixture.finishes("review_save").last?.properties["error_code"] as? String == "validation")
        #expect(fixture.features("review_saved").count == 1)
        let proposal = EvaluationReviewProposal(id: UUID(), annotation: annotation)
        try store.proposeReview(proposal)
        try store.decideReviewProposal(id: proposal.id, accept: true)
        #expect(fixture.features("review_saved").count == 3)
        fixture.assertPrivateContentAbsent()
    }

    /// Produces distinct supported synthetic facts so document generation can complete its requested five cases.
    nonisolated private static func documentCase(source: EvaluationDocumentSource, passage: EvaluationDocumentPassage, index: Int) -> EvaluationCase {
        var value = DocumentTestFixture.example(reviewed: false)
        value.prompt = "What does rule \(index) permit?"
        value.expected = "Rule \(index) permits reading report \(index)."
        value.documentEvidence?.passages = source.passages
        value.documentEvidence?.citations = [.init(passageID: passage.id, quote: value.expected)]
        return value
    }

    /// Installs an isolated synthetic saved response and returns a current human annotation for it.
    private func installReviewSample(in store: EvaluationStore) throws -> EvaluationReviewAnnotation {
        let suite = store.suite
        let source = try #require(suite.cases.first)
        let result = EvaluationSampleResult(caseID: source.id, caseName: source.name, repetition: 1,
            prompt: source.prompt, expected: source.expected, response: "Synthetic response", status: .unscored,
            score: nil, rationale: nil, durationMilliseconds: 1, usage: .init())
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
            repetitions: suite.repetitions, startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2),
            cancelled: false, environment: .init(operatingSystem: "macOS 27", locale: "en_GB", model: "Synthetic", modelContextSize: 4096),
            attachments: [], results: [result])
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        run.plannedCases = suite.cases
        run.subjectEvidence = .init(instructions: suite.instructions, cases: suite.cases, attachments: [],
            digest: try EvaluationSubjectEvidenceSnapshot.digest(instructions: suite.instructions, cases: suite.cases, attachments: []))
        store.runs = [run]
        let sample = try #require(store.reviewSamples.first)
        return .init(id: UUID(), runID: run.id, sampleID: result.id, sourceDigest: sample.sourceDigest,
            verdict: .failed, note: "Synthetic review", tags: [], updatedAt: Date())
    }
}

@MainActor private final class WorkflowTelemetryFixture {
    let directory: URL
    let projectID = UUID()
    let defaults: UserDefaults
    let defaultsName = "TelemetryWorkflow.\(UUID())"
    let client = WorkflowRecordingClient()
    let recorder: TelemetryController

    /// Creates isolated storage and an injected network-free recorder with usage and diagnostics enabled.
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "TelemetryWorkflow.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(true, forKey: TelemetryController.consentKey)
        defaults.set(true, forKey: TelemetryController.diagnosticsConsentKey)
        let client = self.client
        recorder = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"), makeClient: { _ in client })
    }

    /// Removes only this test's temporary storage and preferences.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    /// Injects deterministic generation and configurable semantic review while retaining real draft persistence.
    func documentController(generate: @escaping EvaluationDocumentDraftPipeline.Generator,
                            reviewer: @escaping EvaluationDocumentSemanticReviewer.Reviewer = DocumentTestFixture.semanticReviewer) -> EvaluationDocumentDraftController {
        var source = DocumentTestFixture.source
        source.passages[0].text = (0..<5).map { "Rule \($0) permits reading report \($0)." }.joined(separator: " ")
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID, telemetry: recorder,
            generate: generate, reviewerFactory: { _ in reviewer }, availability: { nil })
        controller.draft = .init(projectID: projectID, name: "Private workflow document", source: source,
            selectedPassageIDs: Set(source.passages.map(\.id)), requestedCount: 5)
        return controller
    }

    /// Selects feature events by fixed category, without depending on session-open bookkeeping.
    func features(_ name: String) -> [TelemetryEvent] {
        client.events.filter { $0.name == "intents_feature_used" && $0.properties["feature"] as? String == name }
    }

    /// Selects completed diagnostics for one fixed workflow operation.
    func finishes(_ operation: String) -> [TelemetryEvent] {
        client.events.filter { $0.name == "foundation_evals_operation_finished" && $0.properties["operation"] as? String == operation }
    }

    /// Ensures real workflow payloads do not carry synthetic names, paths, prompts, notes, or answers.
    func assertPrivateContentAbsent() {
        let payload = String(describing: client.events.map(\.properties))
        for privateValue in ["Private workflow", "private-workflow", directory.path, "Synthetic answer", "Synthetic review"] {
            #expect(!payload.contains(privateValue))
        }
    }
}

private actor WorkflowAttemptCounter {
    private var count = 0
    /// Advances deterministic injected request/review attempts without shared mutable capture races.
    func next() -> Int {
        count += 1
        return count
    }
}

@MainActor private final class WorkflowRecordingClient: TelemetryClient {
    var analyticsSessionID: String? = UUID().uuidString
    var events: [TelemetryEvent] = []
    /// Retains safe typed events in memory without creating an SDK or network destination.
    func capture(_ event: TelemetryEvent) { events.append(event) }
    /// Keeps captured evidence available when consent rotates the injected test client.
    func stopAndDiscard() {}
}
