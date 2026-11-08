import Foundation
import Testing
@testable import FoundationEvals

/// Exercises archive recovery against isolated on-disk catalogs and saved evidence.
@MainActor
struct EvaluationWorkspaceArchiveTests {
    /// Restore retains stable IDs, duplicate names, suite definitions, attachments and runs across reopening.
    @Test func restoredSuiteRetainsEvidenceAndSelection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let projectID = store.selectedProjectID, suiteID = store.selectedSuiteID
        let directory = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: root, projectID: projectID, suiteID: suiteID)
        let canonical = try Data(contentsOf: directory.appending(path: "suite.json"))
        let run = savedRun(suite: store.suite)
        let runFile = directory.appending(path: "Runs/\(run.id.uuidString).json")
        try CanonicalJSON.data(for: run).write(to: runFile)
        let attachment = directory.appending(path: "Attachments/fixture.txt")
        try Data("Synthetic attachment".utf8).write(to: attachment)
        let replacement = try store.createSuite(name: store.suite.name)
        try store.archiveSuite(id: suiteID)
        try store.restoreSuite(id: suiteID, projectID: projectID)
        #expect(store.selectedSuiteID == replacement)
        #expect(store.suiteRecords.count == 2)
        #expect(store.suiteRecords.allSatisfy { !$0.isArchived })
        #expect(try Data(contentsOf: directory.appending(path: "suite.json")) == canonical)
        #expect(try Data(contentsOf: attachment) == Data("Synthetic attachment".utf8))
        let reopened = EvaluationStore(supportDirectory: root)
        try reopened.switchSuite(id: suiteID)
        #expect(reopened.runs.contains { $0.id == run.id })
        #expect(try Data(contentsOf: runFile) == CanonicalJSON.data(for: run))
    }

    /// Project restore preserves selection and each child suite's independent archive flag, including duplicate names.
    @Test func restoredProjectKeepsChildArchives() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let projectID = store.selectedProjectID, childID = store.selectedSuiteID
        let activeID = try store.createSuite(name: "Active child")
        try store.archiveSuite(id: childID)
        let selectedProject = try store.createProject(name: store.selectedProject.name)
        try store.archiveProject(id: projectID)
        try store.restoreProject(id: projectID)
        #expect(store.selectedProjectID == selectedProject)
        let project = try #require(store.projects.first { $0.id == projectID })
        #expect(!project.isArchived)
        #expect(project.suites.first { $0.id == childID }?.isArchived == true)
        #expect(project.suites.first { $0.id == activeID }?.isArchived == false)
        let reopened = EvaluationStore(supportDirectory: root)
        try reopened.switchProject(id: projectID)
        #expect(reopened.selectedSuiteID == activeID)
        #expect(reopened.suiteRecords.first { $0.id == childID }?.isArchived == true)
    }

    /// Rejected catalog writes leave both archive flags and the visible selection unchanged; retry can restore them.
    @Test func failedRestorationRollsBackAndAllowsRetry() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reject = false
        let store = EvaluationStore(supportDirectory: root, workspaceCatalogWriter: { catalog, directory in
            if reject { throw CocoaError(.fileWriteNoPermission) }
            try EvaluationWorkspacePersistence.save(catalog, in: directory)
        })
        let projectID = store.selectedProjectID, suiteID = store.selectedSuiteID
        _ = try store.createSuite(name: "Other suite")
        try store.archiveSuite(id: suiteID)
        _ = try store.createProject(name: "Other project")
        try store.archiveProject(id: projectID)
        let selection = (store.selectedProjectID, store.selectedSuiteID)
        let catalog = try Data(contentsOf: root.appending(path: EvaluationWorkspacePersistence.catalogFilename))
        reject = true
        #expect(throws: EvaluationStoreError.self) { try store.restoreProject(id: projectID) }
        #expect(throws: EvaluationStoreError.self) { try store.restoreSuite(id: suiteID, projectID: projectID) }
        #expect(store.projects.first { $0.id == projectID }?.isArchived == true)
        #expect(store.projects.first { $0.id == projectID }?.suites.first { $0.id == suiteID }?.isArchived == true)
        #expect(store.selectedProjectID == selection.0 && store.selectedSuiteID == selection.1)
        #expect(try Data(contentsOf: root.appending(path: EvaluationWorkspacePersistence.catalogFilename)) == catalog)
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.projects.first { $0.id == projectID }?.isArchived == true)
        reject = false
        try store.restoreSuite(id: suiteID, projectID: projectID)
        #expect(store.projects.first { $0.id == projectID }?.isArchived == true)
        try store.restoreProject(id: projectID)
        #expect(store.projects.first { $0.id == projectID }?.isArchived == false)
    }

    /// Missing identities and active execution cannot mutate archived catalog entries.
    @Test func missingAndBusyRestorationFailSafely() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        #expect(throws: EvaluationWorkspaceError.self) { try store.restoreProject(id: UUID()) }
        #expect(throws: EvaluationWorkspaceError.self) { try store.restoreSuite(id: UUID(), projectID: store.selectedProjectID) }
        #expect(throws: EvaluationWorkspaceError.self) { try store.restoreSuite(id: store.selectedSuiteID, projectID: UUID()) }
        let before = store.workspace
        store.isRunning = true
        #expect(throws: EvaluationStoreError.self) { try store.restoreProject(id: store.selectedProjectID) }
        #expect(throws: EvaluationStoreError.self) { try store.restoreSuite(id: store.selectedSuiteID, projectID: store.selectedProjectID) }
        store.isRunning = false
        #expect(store.workspace == before)
    }

    /// Constructs a small saved run without loading model resources.
    private func savedRun(suite: EvaluationSuite) -> EvaluationRun {
        EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            judgePromptVersion: nil, judgePassingScore: nil, plannedSampleCount: suite.cases.count,
            suiteRevision: "fixture", plannedCases: suite.cases, startedAt: Date(), completedAt: Date(),
            cancelled: true, terminationReason: nil,
            environment: .init(operatingSystem: "fixture", locale: "en", model: "fixture", modelContextSize: 4096),
            attachments: [], results: [])
    }
}
