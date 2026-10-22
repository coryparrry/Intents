import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceCreationTests {
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

    private func directoryNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
