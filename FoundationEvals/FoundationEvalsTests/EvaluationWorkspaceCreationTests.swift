import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceCreationTests {
    /// Blank-suite renaming saves metadata while retaining unfinished edits and the requirement to add cases before running.
    @Test func blankSuiteRenamePreservesDraftAcrossReopening() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let id = try store.createSuite(name: "Blank")
        let canonicalInstructions = store.suite.instructions
        store.draftSuite.instructions = "Unfinished authoring retained separately"
        #expect(!store.saveSuite())
        try store.renameSuite(id: id, name: "  Renamed blank  ")
        #expect(store.suite.name == "Renamed blank" && store.selectedSuiteRecord.name == "Renamed blank")
        #expect(store.suite.instructions == canonicalInstructions)
        #expect(store.draftSuite.instructions == "Unfinished authoring retained separately")
        #expect(store.suite.cases.isEmpty && store.draftSuite.cases.isEmpty)
        #expect(!store.saveSuite(), "A metadata rename cannot make an empty suite runnable")
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.selectedSuiteID == id)
        #expect(reopened.suite.name == "Renamed blank" && reopened.draftSuite.name == "Renamed blank")
        #expect(reopened.suite.instructions == canonicalInstructions)
        #expect(reopened.draftSuite.instructions == "Unfinished authoring retained separately")
        #expect(reopened.suite.cases.isEmpty)
    }

    /// A failed blank-suite rename restores both persisted metadata and the prior unfinished draft before a retry.
    @Test func failedBlankSuiteRenameRollsBackMetadataAndDraft() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reject = false
        let store = EvaluationStore(supportDirectory: root, workspaceCatalogWriter: { catalog, directory in
            if reject { throw CocoaError(.fileWriteNoPermission) }
            try EvaluationWorkspacePersistence.save(catalog, in: directory)
        })
        let id = try store.createSuite(name: "Blank")
        store.draftSuite.instructions = "Retained incomplete draft"
        #expect(!store.saveSuite())
        let directory = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: root,
            projectID: store.selectedProjectID, suiteID: id)
        let canonical = try Data(contentsOf: directory.appending(path: "suite.json"))
        let draft = try Data(contentsOf: directory.appending(path: "suite-draft.json"))
        let catalog = try Data(contentsOf: root.appending(path: EvaluationWorkspacePersistence.catalogFilename))
        reject = true
        #expect(throws: EvaluationStoreError.self) { try store.renameSuite(id: id, name: "Rejected") }
        #expect(store.suite.name == "Blank" && store.draftSuite.name == "Blank")
        #expect(store.draftSuite.instructions == "Retained incomplete draft")
        #expect(try Data(contentsOf: directory.appending(path: "suite.json")) == canonical)
        #expect(try Data(contentsOf: directory.appending(path: "suite-draft.json")) == draft)
        #expect(try Data(contentsOf: root.appending(path: EvaluationWorkspacePersistence.catalogFilename)) == catalog)
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.suite.name == "Blank")
        #expect(reopened.draftSuite.instructions == "Retained incomplete draft")
        reject = false
        try store.renameSuite(id: id, name: "Retried")
        #expect(store.suite.name == "Retried" && store.draftSuite.name == "Retried")
    }

    /// Blank creation preserves an empty case list after reopening, while a selected starter keeps its examples.
    @Test func blankProjectsAndSuitesRemainEmptyWithoutChangingStarters() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        #expect(!store.suite.cases.isEmpty, "Initial onboarding keeps its example")
        _ = try store.createProject(name: "Blank project")
        #expect(store.suite.cases.isEmpty && store.draftSuite.cases.isEmpty)
        let projectSuiteID = store.selectedSuiteID
        let blankID = try store.createSuite(name: "Blank suite")
        #expect(store.suite.cases.isEmpty && store.draftSuite.cases.isEmpty)
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.selectedSuiteID == blankID && reopened.suite.cases.isEmpty)
        try reopened.switchSuite(id: projectSuiteID)
        #expect(reopened.suite.cases.isEmpty)
        let starter = try #require(EvaluationStarterPack.allCases.first)
        _ = try reopened.createSuite(name: "Starter", starter: starter)
        #expect(!reopened.suite.cases.isEmpty)
        #expect(reopened.suite.cases.map(\.prompt) == starter.makeSuite().cases.map(\.prompt))
    }

    @Test func failedSuiteCatalogCommitRemovesUnpublishedDirectoryAndAllowsRetry() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var rejectNewSuite = false
        var blockedWrites = 0
        let store = EvaluationStore(supportDirectory: root, workspaceCatalogWriter: { catalog, directory in
            if rejectNewSuite && catalog.projects.flatMap(\.suites).count > 1 {
                blockedWrites += 1
                throw CocoaError(.fileWriteNoPermission)
            }
            try EvaluationWorkspacePersistence.save(catalog, in: directory)
        })
        let projectID = store.selectedProjectID
        let suiteID = store.selectedSuiteID
        let sourceDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: projectID, suiteID: suiteID
        )
        let suitesDirectory = sourceDirectory.deletingLastPathComponent()
        let originalDirectories = try directoryNames(in: suitesDirectory)
        let originalSuite = try Data(contentsOf: sourceDirectory.appending(path: "suite.json"))
        rejectNewSuite = true

        #expect(throws: (any Error).self) { try store.createSuite(name: "Unpublished") }

        #expect(blockedWrites == 1)
        #expect(store.selectedProjectID == projectID)
        #expect(store.selectedSuiteID == suiteID)
        #expect(store.selectedProject.suites.map(\.id) == [suiteID])
        let reloaded = EvaluationStore(supportDirectory: root)
        #expect(reloaded.selectedProject.suites.map(\.id) == [suiteID])
        #expect(reloaded.selectedSuiteID == suiteID)
        #expect(try directoryNames(in: suitesDirectory) == originalDirectories)
        #expect(try Data(contentsOf: sourceDirectory.appending(path: "suite.json")) == originalSuite)

        rejectNewSuite = false
        let createdID = try store.createSuite(name: "Saved on retry")
        #expect(store.selectedSuiteID == createdID)
        #expect(store.selectedProject.suites.map(\.id) == [suiteID, createdID])
        let saved = EvaluationStore(supportDirectory: root)
        #expect(saved.selectedSuiteID == createdID)
        #expect(saved.suite.id == createdID)
        #expect(saved.suite.name == "Saved on retry")
        #expect(try directoryNames(in: suitesDirectory).count == originalDirectories.count + 1)
        #expect(try Data(contentsOf: sourceDirectory.appending(path: "suite.json")) == originalSuite)
    }

    @Test func failedSelectionAfterCatalogCommitKeepsPublishedSuite() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var publishedNewSuite = false
        var rejectedPostPublicationWrites = 0
        let store = EvaluationStore(supportDirectory: root, workspaceCatalogWriter: { catalog, directory in
            let containsNewSuite = catalog.projects.flatMap(\.suites).count > 1
            if containsNewSuite && publishedNewSuite {
                rejectedPostPublicationWrites += 1
                throw CocoaError(.fileWriteNoPermission)
            }
            try EvaluationWorkspacePersistence.save(catalog, in: directory)
            if containsNewSuite { publishedNewSuite = true }
        })
        let originalID = store.selectedSuiteID
        #expect(throws: (any Error).self) { try store.createSuite(name: "Published") }

        #expect(publishedNewSuite)
        #expect(rejectedPostPublicationWrites > 0)
        #expect(store.selectedSuiteID == originalID)
        let published = try #require(store.selectedProject.suites.first { $0.id != originalID })
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: published.id
        )
        let suite = try CanonicalJSON.decode(EvaluationSuite.self, from: Data(contentsOf: directory.appending(path: "suite.json")))
        #expect(suite.id == published.id)
        #expect(suite.name == "Published")
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.selectedSuiteID == published.id)
        #expect(reopened.suite == suite)
    }

    private func directoryNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
