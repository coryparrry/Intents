import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationStorePersistenceRecoveryTests {
    @Test(arguments: [false, true])
    func experimentDecisionSurvivesRepositoryFailureRelaunchAndSwitch(repositoryConflict: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appending(path: "storage")
        let store = EvaluationStore(supportDirectory: storage)
        let projectID = store.selectedProjectID
        let suiteID = store.selectedSuiteID
        try linkRepository(store, in: directory)
        let definitionURL = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord
        ))
        let definitionData = try Data(contentsOf: definitionURL)
        let experimentID = try store.createInstructionExperiment(
            name: "Keep the original", candidateInstructions: "Answer with a short sentence."
        )
        try store.decideExperiment(id: experimentID, decision: .keepCurrent)
        let stateURL = suiteDirectory(store, in: storage).appending(path: "state.json")
        let stateData = try Data(contentsOf: stateURL)
        let otherProjectID = try store.createProject(name: "Other project")
        try store.switchWorkspace(projectID: projectID, suiteID: suiteID)
        let repositoryFailureData: Data
        if repositoryConflict {
            var localSuite = store.suite
            localSuite.name = "Independent local edit"
            try CanonicalJSON.data(for: localSuite).write(
                to: suiteDirectory(store, in: storage).appending(path: "suite.json"), options: .atomic
            )
            var repositorySuite = store.suite
            repositorySuite.instructions = "Independent repository edit."
            repositoryFailureData = try CanonicalJSON.data(for: EvaluationSuiteDefinition(suite: repositorySuite))
        } else {
            repositoryFailureData = Data("{ malformed repository definition".utf8)
        }
        try repositoryFailureData.write(to: definitionURL, options: .atomic)

        let reloaded = EvaluationStore(supportDirectory: storage)
        #expect(reloaded.notice != nil)
        #expect(reloaded.suiteLocalState.experiments.first?.id == experimentID)
        #expect(reloaded.suiteLocalState.experiments.first?.decision == .keepCurrent)
        try reloaded.switchProject(id: otherProjectID)
        #expect(try Data(contentsOf: stateURL) == stateData)

        // A failed destination load must restore the complete previous selection
        // and must not expose that destination's local decisions in memory.
        #expect(throws: (any Error).self) {
            try reloaded.switchWorkspace(projectID: projectID, suiteID: suiteID)
        }
        #expect(reloaded.selectedProjectID == otherProjectID)
        #expect(reloaded.suiteLocalState.experiments.isEmpty)
        #expect(try Data(contentsOf: stateURL) == stateData)
        #expect(try Data(contentsOf: definitionURL) == repositoryFailureData)

        try definitionData.write(to: definitionURL, options: .atomic)
        try reloaded.switchWorkspace(projectID: projectID, suiteID: suiteID)
        #expect(reloaded.suiteLocalState.experiments.first?.id == experimentID)
        #expect(reloaded.suiteLocalState.experiments.first?.decision == .keepCurrent)
        let finalReload = EvaluationStore(supportDirectory: storage)
        #expect(finalReload.suiteLocalState.experiments.first?.id == experimentID)
        #expect(finalReload.suiteLocalState.experiments.first?.decision == .keepCurrent)
    }

    @Test(arguments: [false, true])
    func fallbackSuiteIdentitySurvivesSaveRelaunchAndNewRun(corruptCatalog: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = EvaluationStore(supportDirectory: directory)
        if corruptCatalog {
            try Data("{ corrupt catalog".utf8).write(
                to: directory.appending(path: EvaluationWorkspacePersistence.catalogFilename), options: .atomic
            )
        } else {
            try FileManager.default.removeItem(at: suiteDirectory(initial, in: directory).appending(path: "suite.json"))
        }

        let recovered = EvaluationStore(supportDirectory: directory)
        #expect(recovered.suite.id == recovered.selectedSuiteID)
        #expect(recovered.draftSuite.id == recovered.selectedSuiteID)
        #expect(recovered.saveSuite())
        let run = completedRun(for: recovered)
        try recovered.saveCompletedRuns([run])

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.selectedProjectID == recovered.selectedProjectID)
        #expect(reloaded.selectedSuiteID == recovered.selectedSuiteID)
        #expect(reloaded.suite.id == reloaded.selectedSuiteID)
        #expect(reloaded.draftSuite.id == reloaded.selectedSuiteID)
        #expect(reloaded.notice == nil)
        #expect(reloaded.run(with: run.id)?.suiteID == reloaded.selectedSuiteID)
        #expect(reloaded.runs.count == 1)
    }

    @Test func repositoryRefreshCatalogFailureRestoresCanonicalBytesAndRetries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appending(path: "storage")
        let store = EvaluationStore(supportDirectory: storage)
        try linkRepository(store, in: directory)
        let suiteURL = suiteDirectory(store, in: storage).appending(path: "suite.json")
        let catalogURL = storage.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let originalSuiteData = try Data(contentsOf: suiteURL)
        let originalCatalogData = try Data(contentsOf: catalogURL)
        let originalCatalog = try CanonicalJSON.decode(EvaluationWorkspaceCatalog.self, from: originalCatalogData)
        let definitionURL = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord
        ))
        var changedSuite = store.suite
        changedSuite.name = "Repository update"
        changedSuite.instructions = "Return the repository-authored answer."
        let changedDefinition = EvaluationSuiteDefinition(suite: changedSuite)
        let changedRevision = try EvaluationWorkspacePersistence.definitionRevision(changedDefinition)
        let repositoryData = try CanonicalJSON.data(for: changedDefinition)
        try repositoryData.write(to: definitionURL, options: .atomic)
        var failCatalogWrite = true
        var observedRefreshedCanonical = false
        let writer: (EvaluationWorkspaceCatalog, URL) throws -> Void = { catalog, destination in
            if failCatalogWrite,
               catalog.projects.contains(where: { project in
                   project.suites.contains { $0.id == changedSuite.id && $0.lastRepositoryRevision == changedRevision }
               }) {
                let written = try CanonicalJSON.decode(EvaluationSuite.self, from: Data(contentsOf: suiteURL))
                observedRefreshedCanonical = written == changedSuite
                throw CatalogWriteFailure.injected
            }
            try EvaluationWorkspacePersistence.save(catalog, in: destination)
        }

        let failed = EvaluationStore(supportDirectory: storage, workspaceCatalogWriter: writer)
        #expect(observedRefreshedCanonical)
        #expect(failed.notice?.contains("Injected catalog write failure") == true)
        #expect(failed.suite == store.suite)
        #expect(failed.workspace == originalCatalog)
        #expect(try Data(contentsOf: suiteURL) == originalSuiteData)
        #expect(try Data(contentsOf: catalogURL) == originalCatalogData)
        #expect(try Data(contentsOf: definitionURL) == repositoryData)

        failCatalogWrite = false
        let retried = EvaluationStore(supportDirectory: storage, workspaceCatalogWriter: writer)
        #expect(retried.notice == nil)
        #expect(retried.suite == changedSuite)
        #expect(retried.selectedSuiteRecord.lastRepositoryRevision == changedRevision)
        let finalReload = EvaluationStore(supportDirectory: storage)
        #expect(finalReload.suite == changedSuite)
        #expect(finalReload.selectedSuiteRecord.lastRepositoryRevision == changedRevision)
        #expect(finalReload.notice == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func linkRepository(_ store: EvaluationStore, in directory: URL) throws {
        let repository = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try store.linkSelectedProject(toRepository: repository.path)
    }

    private func suiteDirectory(_ store: EvaluationStore, in storage: URL) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: storage, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
    }

    private func completedRun(for store: EvaluationStore) -> EvaluationRun {
        EvaluationRun(
            id: UUID(), suiteID: store.suite.id, suiteName: store.suite.name,
            suiteVersion: store.suite.version, instructions: store.suite.instructions,
            criteria: store.suite.criteria, scoringMode: .review, repetitions: 1,
            judgePromptVersion: nil, judgePassingScore: nil, plannedSampleCount: 1,
            startedAt: .now, completedAt: .now, cancelled: true, terminationReason: "cancelled",
            environment: EvaluationEnvironment(
                operatingSystem: "Test", locale: "en_GB", model: "Test model", modelContextSize: 4096
            ),
            attachments: [], results: [], projectID: store.selectedProjectID
        )
    }

    private enum CatalogWriteFailure: LocalizedError {
        case injected
        var errorDescription: String? { "Injected catalog write failure" }
    }
}
