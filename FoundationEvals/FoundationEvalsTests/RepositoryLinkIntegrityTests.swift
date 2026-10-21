import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct RepositoryLinkIntegrityTests {
    @Test func anotherRepositoryCannotRetargetExistingSuiteDefinitions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository(at: root.appending(path: "first"))
        let second = try repository(at: root.appending(path: "second"))
        let support = root.appending(path: "support")
        let store = EvaluationStore(supportDirectory: support)
        try store.linkSelectedProject(toRepository: first.path)
        let firstSuite = store.selectedSuiteRecord
        let firstDefinition = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: firstSuite))
        let firstBytes = try Data(contentsOf: firstDefinition)
        _ = try store.createSuite(name: "Second suite")
        // Linking an additional suite within the same repository remains valid.
        try store.linkSelectedProject(toRepository: first.path)
        let catalog = support.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let originalCatalog = try Data(contentsOf: catalog)
        let originalProject = store.selectedProject
        let originalPersistedProject = try #require(CanonicalJSON.decode(
            EvaluationWorkspaceCatalog.self, from: originalCatalog).projects.first { $0.id == originalProject.id })

        #expect(throws: EvaluationStoreError.self) {
            try store.linkSelectedProject(toRepository: second.path)
        }
        #expect(store.selectedProject == originalProject)
        #expect(try Data(contentsOf: catalog) == originalCatalog)
        #expect(try Data(contentsOf: firstDefinition) == firstBytes)
        #expect(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: firstSuite) == firstDefinition)
        #expect(!FileManager.default.fileExists(atPath: second.appending(path: ".foundation-evals").path))
        #expect(EvaluationStore(supportDirectory: support).selectedProject == originalPersistedProject)
    }

    @Test func sameRepositoryThroughCanonicalAliasRemainsLinkable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(at: root.appending(path: "repository"))
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let store = EvaluationStore(supportDirectory: root.appending(path: "support"))
        try store.linkSelectedProject(toRepository: repository.path)
        let definition = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord))
        let original = try Data(contentsOf: definition)
        try store.linkSelectedProject(toRepository: alias.path)
        let aliasedDefinition = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord))
        #expect(aliasedDefinition.resolvingSymlinksInPath() == definition.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: aliasedDefinition) == original)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RepositoryLinkIntegrity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repository(at url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return url
    }
}
