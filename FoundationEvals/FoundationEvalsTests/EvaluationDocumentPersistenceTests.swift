import AppKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct EvaluationDocumentPersistenceTests {
    /// Verify that imported sources at published limits remain valid evidence.
    @Test func importedSourcesAtPublishedLimitsRemainValidEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "limits.txt")
        let quote = "Owners can export a workspace."
        for text in [(0..<512).map { quote + " Fact \($0)." }.joined(separator: "\n\n"),
                     quote + String(repeating: "x", count: 128_000 - quote.count)] {
            try Data(text.utf8).write(to: file)
            let source = try EvaluationDocumentImporter.importFile(at: file)
            #expect(source.validationIssue == nil)
            let passage = try #require(source.passages.first)
            let value = try #require(try EvaluationDocumentGenerator.validated(.init(name: "Boundary",
                question: "Who can export?", answer: "Owners can export a workspace.", quotes: [quote], supported: true),
                source: source, passage: passage, questionType: "Direct fact", existingQuestions: []))
            #expect(value.documentValidationIssue == nil)
        }
        try Data((0..<513).map { "Fact \($0)." }.joined(separator: "\n\n").utf8).write(to: file)
        #expect(throws: (any Error).self) { try EvaluationDocumentImporter.importFile(at: file) }
    }

    /// Verify that failed reviewer setup preserves retry history on disk.
    @Test func failedReviewerSetupPreservesRetryHistoryOnDisk() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _, _ in Issue.record("Unauthorized retry"); return nil }, availability: { nil })
        var draft = EvaluationDocumentDraft(projectID: projectID, name: "Retry", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.issues = ["page-6-1:0": "Saved failure"]
        draft.completedBatchIDs = ["page-6-1:0"]
        controller.draft = draft
        #expect(controller.persist())
        controller.generate(retryFailures: true)
        await controller.waitUntilIdle()
        #expect(controller.draft?.issues == draft.issues)
        #expect(controller.draft?.completedBatchIDs == draft.completedBatchIDs)
        let saved = try #require(EvaluationDocumentDraftStorage.load(from: directory.appending(path: "DocumentDrafts/\(projectID.uuidString).json")))
        #expect(saved.issues == draft.issues)
        #expect(saved.completedBatchIDs == draft.completedBatchIDs)
    }

    /// Verify that exported cases with different retained contexts can be reviewed after import.
    @Test func exportedCasesWithDifferentRetainedContextsCanBeReviewedAfterImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DocumentTestFixture.example()
        var second = first
        second.id = UUID(); second.prompt = "When are reports updated?"; second.expected = "Daily."
        second.criteriaOverride = ["States daily."]
        let passage = EvaluationDocumentPassage(id: "second", location: "Page 2", text: "Reports are updated daily.")
        second.documentEvidence?.passages.append(passage)
        second.documentEvidence?.citations = [.init(passageID: passage.id, quote: passage.text)]
        second.acceptDocumentReview()
        var suite = DocumentTestFixture.suite(); suite.cases = [first, second]
        let projectID = UUID()
        var imported = try EvaluationDocumentArchive.draft(from: EvaluationDocumentArchive.data(for: suite), projectID: projectID)
        let connection = DocumentTestFixture.semanticConnection
        imported.semanticJudgeID = connection.id
        imported.semanticApprovalDigest = connection.disclosureDigest
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            reviewerFactory: { _ in { value, source, questions in
                #expect(source.passages == value.documentEvidence?.passages)
                return try await DocumentTestFixture.semanticReviewer(value, source, questions)
            } }, availability: { nil })
        controller.draft = imported
        for item in imported.cases {
            controller.reviewAndAccept(caseID: item.id, judge: connection)
            await controller.waitUntilIdle()
            #expect(controller.error == nil)
        }
        let restored = try #require(controller.draft).makeSuite()
        #expect(restored.cases.map { $0.documentEvidence?.passages.count } == [1, 2])
    }

    /// Verify that text import normalizes unicode and refuses oversized selection.
    @Test func textImportNormalizesUnicodeAndRefusesOversizedSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "guide.md")
        try Data("# Permissions\r\n\r\nCafe\u{301} members cannot export.\r\n\r\nOwners may export.".utf8).write(to: file)
        let source = try EvaluationDocumentImporter.importFile(at: file)
        #expect(source.passages.count == 3)
        #expect(source.passages[1].text.contains("Café"))
        #expect(source.passages[1].location.contains("Permissions"))
        let selected = try EvaluationDocumentImporter.importFile(at: file, selection: 2...2)
        #expect(selected.passages.count == 1)
        #expect(selected.passages[0].id == source.passages[1].id)
        try Data(String(repeating: "x", count: 128_001).utf8).write(to: file)
        #expect(throws: (any Error).self) { try EvaluationDocumentImporter.importFile(at: file) }
        try Data([0xff, 0xfe]).write(to: file)
        #expect(throws: (any Error).self) { try EvaluationDocumentImporter.importFile(at: file) }
    }

    /// Verify that pdf extraction retains page anchor.
    @Test func pdfExtractionRetainsPageAnchor() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = DocumentTestFixture.passage.text
        let file = directory.appending(path: "guide.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: file)
        let source = try EvaluationDocumentImporter.importFile(at: file)
        #expect(source.passages.first?.location == "Page 1")
        #expect(source.passages.first?.text.contains("Owners") == true)
    }

    /// Verify that saved draft retains edits and acceptance after original file disappears.
    @Test func savedDraftRetainsEditsAndAcceptanceAfterOriginalFileDisappears() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "draft.json")
        var draft = EvaluationDocumentDraft(projectID: UUID(), name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.cases = [.init(evaluationCase: DocumentTestFixture.example())]
        draft.completedBatchIDs = ["page-6-1:0"]
        draft.issues = ["page-6-1:1": "A recoverable failure"]
        try EvaluationDocumentDraftStorage.save(draft, to: url)
        let loaded = try #require(try EvaluationDocumentDraftStorage.load(from: url))
        #expect(loaded.destinationSuiteID == draft.destinationSuiteID)
        #expect(loaded.acceptedCases == draft.acceptedCases)
        #expect(loaded.issues == draft.issues)
        #expect(loaded.acceptedCases[0].documentEvidence?.contextText.contains("Owners") == true)
    }

    /// Verify that creation retry is idempotent and failure does not publish partial suite.
    @Test(arguments: [false, true]) func creationRetryIsIdempotentAndFailureDoesNotPublishPartialSuite(incompleteDirectory: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fail = false
        let store = EvaluationStore(supportDirectory: directory, workspaceCatalogWriter: { catalog, destination in
            if fail { throw CocoaError(.fileWriteUnknown) }
            try EvaluationWorkspacePersistence.save(catalog, in: destination)
        })
        var draft = EvaluationDocumentDraft(projectID: store.selectedProjectID, name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.cases = [.init(evaluationCase: DocumentTestFixture.example())]
        let before = store.selectedProject.suites.count
        if incompleteDirectory {
            let target = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: directory,
                projectID: draft.projectID, suiteID: draft.destinationSuiteID)
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: target)
        }
        fail = true
        #expect(throws: (any Error).self) { try store.createSuite(name: draft.name, documentDraft: draft) }
        #expect(store.selectedProject.suites.count == before)
        fail = false
        let first = try store.createSuite(name: draft.name, documentDraft: draft)
        let second = try store.createSuite(name: draft.name, documentDraft: draft)
        #expect(first == second)
        #expect(store.selectedProject.suites.count == before + 1)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.suite.cases[0].hasReviewedDocument)
        #expect(reloaded.suite.cases[0].documentEvidence?.contextText == draft.cases[0].evaluationCase.documentEvidence?.contextText)
    }

    /// Verify that document conversion and whole suite mutation are explicitly gated.
    @Test func documentConversionAndWholeSuiteMutationAreExplicitlyGated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite = DocumentTestFixture.suite()
        #expect(throws: (any Error).self) { try store.productionSnapshot() }
        #expect(throws: (any Error).self) {
            try store.replaceSuite(EvaluationSuite(), expectedRevision: "unused", confirmDeletes: true)
        }
        #expect(EvaluationPromptImprovementRules.validationIssue(suite: store.draftSuite,
            heldOutCaseIDs: [store.draftSuite.cases[0].id]) != nil)
    }

    /// Verify that archive round trip retains evidence and requires fresh review.
    @Test func archiveRoundTripRetainsEvidenceAndRequiresFreshReview() throws {
        let original = DocumentTestFixture.suite()
        let bytes = try EvaluationDocumentArchive.data(for: original)
        var imported = try EvaluationDocumentArchive.draft(from: bytes, projectID: UUID())
        #expect(imported.acceptedCases.isEmpty)
        #expect(imported.cases[0].evaluationCase.documentEvidence?.passages == original.cases[0].documentEvidence?.passages)
        #expect(imported.cases[0].evaluationCase.criteriaOverride == original.cases[0].criteriaOverride)
        imported.cases[0].evaluationCase.acceptDocumentReview()
        let recreated = try imported.makeSuite()
        #expect(recreated.instructions == original.instructions)
        #expect(recreated.cases[0].documentEvidence?.contextText == original.cases[0].documentEvidence?.contextText)
        #expect(recreated.modelConfiguration.provider == .onDevice)
    }

    /// Verify that generation does not resurface identical facts with new questions.
    @Test func generationDoesNotResurfaceIdenticalFactsWithNewQuestions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let generator = DuplicateFactFixtureGenerator()
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _, _ in await generator.next() }, reviewerFactory: { _ in DocumentTestFixture.semanticReviewer }, availability: { nil })
        controller.draft = .init(projectID: projectID, name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id], requestedCount: 5)
        controller.generate()
        await controller.waitUntilIdle()
        #expect(controller.draft?.cases.count == 1)
        #expect(controller.draft?.issues.count == 9)
    }

    /// Verify that partial generation survives restart and retry preserves edits.
    @Test func partialGenerationSurvivesRestartAndRetryPreservesEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let generator = DraftFixtureGenerator()
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _, _ in try await generator.next() }, reviewerFactory: { _ in DocumentTestFixture.semanticReviewer }, availability: { nil })
        controller.draft = .init(projectID: projectID, name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id], requestedCount: 5)
        controller.generate()
        await controller.waitUntilIdle()
        #expect(controller.draft?.cases.count == 1)
        #expect(controller.draft?.issues.isEmpty == false)
        controller.draft?.cases[0].evaluationCase.expected = "A preserved edit"
        #expect(controller.persist())
        let resumed = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _, _ in try await generator.next() }, reviewerFactory: { _ in DocumentTestFixture.semanticReviewer }, availability: { nil })
        #expect(resumed.draft?.cases[0].evaluationCase.expected == "A preserved edit")
        let previousCalls = await generator.calls
        resumed.generate()
        await resumed.waitUntilIdle()
        #expect(await generator.calls == previousCalls)
        resumed.generate(retryFailures: true)
        await resumed.waitUntilIdle()
        #expect(await generator.calls > previousCalls)
        #expect(resumed.draft?.cases[0].evaluationCase.expected == "A preserved edit")
    }

    /// Verify that full source generation stops before the suite budget and remains publishable.
    @Test func fullSourceGenerationStopsBeforeTheSuiteBudgetAndRemainsPublishable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var source = DocumentTestFixture.source
        let facts = (0..<20).map { "Rule \($0)." }.joined(separator: " ")
        source.passages.append(.init(id: "background", location: "Page 2", text: facts + String(repeating: "Background. ", count: 1_100)))
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: id,
            generate: { source, passage, _, existing, _ in
                var value = DocumentTestFixture.example(reviewed: false)
                value.prompt = "Question \(existing.count)"
                value.expected = "Answer \(existing.count)"
                value.documentEvidence?.passages = source.passages
                value.documentEvidence?.citations = [.init(passageID: "background", quote: "Rule \(existing.count).")]
                return value
            }, reviewerFactory: { _ in DocumentTestFixture.semanticReviewer }, availability: { nil })
        controller.draft = .init(projectID: id, name: "Full source", source: source,
            selectedPassageIDs: [DocumentTestFixture.passage.id], requestedCount: 20)
        controller.generate()
        await controller.waitUntilIdle()
        var draft = try #require(controller.draft)
        #expect(!draft.cases.isEmpty && draft.cases.count < 20)
        #expect(draft.issues.values.contains { $0.contains("256,000") })
        for index in draft.cases.indices { draft.cases[index].evaluationCase.acceptDocumentReview() }
        #expect(try draft.makeSuite().cases.count == draft.cases.count)
    }

    /// Verify that corrupted draft is preserved instead of overwritten.
    @Test func corruptedDraftIsPreservedInsteadOfOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let url = directory.appending(path: "DocumentDrafts/\(id.uuidString).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{broken".utf8)
        try invalid.write(to: url)
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: id)
        #expect(controller.storageBlocked)
        #expect(!controller.persist())
        #expect(try Data(contentsOf: url) == invalid)
    }

    /// Create unique temporary storage so persistence tests cannot alter saved user evaluations.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "document-suite-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor DraftFixtureGenerator {
    var calls = 0
    /// Return the next scripted fixture response so retry tests can observe attempt order.
    func next() throws -> EvaluationCase? {
        calls += 1
        if calls == 1 { return DocumentTestFixture.example(reviewed: false) }
        throw CocoaError(.fileReadUnknown)
    }
}

private actor DuplicateFactFixtureGenerator {
    private var index = 0
    /// Return the next scripted fixture response so retry tests can observe attempt order.
    func next() -> EvaluationCase {
        index += 1
        var result = DocumentTestFixture.suite().cases[0]
        result.id = UUID()
        result.prompt = "Reworded question number \(index) about the same fact."
        return result
    }
}
