import AppKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct EvaluationDocumentPersistenceTests {
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

    @Test func partialGenerationSurvivesRestartAndRetryPreservesEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let generator = DraftFixtureGenerator()
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _ in try await generator.next() }, availability: { nil })
        controller.draft = .init(projectID: projectID, name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id], requestedCount: 5)
        controller.generate()
        await controller.waitUntilIdle()
        #expect(controller.draft?.cases.count == 1)
        #expect(controller.draft?.issues.isEmpty == false)
        controller.draft?.cases[0].evaluationCase.expected = "A preserved edit"
        #expect(controller.persist())
        let resumed = EvaluationDocumentDraftController(directory: directory, projectID: projectID,
            generate: { _, _, _, _ in try await generator.next() }, availability: { nil })
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "document-suite-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor DraftFixtureGenerator {
    var calls = 0
    func next() throws -> EvaluationCase? {
        calls += 1
        if calls == 1 { return DocumentTestFixture.example(reviewed: false) }
        throw CocoaError(.fileReadUnknown)
    }
}
