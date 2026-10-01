import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct WorkspaceResetTests {
    @Test func blankSuiteReplacesCanonicalAndIncompleteDraftAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalID = store.suite.id
        store.draftSuite.name = "Old draft"
        store.draftSuite.cases[0].prompt = ""
        #expect(!store.saveSuite())
        try store.resetSuite()
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.suite == store.suite)
        #expect(reloaded.draftSuite == store.draftSuite)
        #expect(reloaded.suite.id != originalID)
        #expect(reloaded.draftSuite.name == "Untitled Suite")
        #expect(reloaded.draftSuite.cases.count == 1)
        #expect(reloaded.draftSuite.cases[0].prompt.isEmpty)
        #expect(reloaded.draftSuite.instructions.isEmpty)
        #expect(reloaded.draftSuite.criteria.isEmpty)
        #expect(reloaded.runBlocker != nil)
        #expect(reloaded.notice == nil)
    }

    @Test func clearingHistoryRemovesTracesAndRecoveryMarkerButKeepsDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let run = EvaluationRun(
            id: UUID(),
            suiteID: store.suite.id,
            suiteName: store.suite.name,
            suiteVersion: store.suite.version,
            instructions: store.suite.instructions,
            criteria: store.suite.criteria,
            scoringMode: .review,
            repetitions: 1,
            judgePromptVersion: nil,
            judgePassingScore: nil,
            plannedSampleCount: 5,
            startedAt: .now,
            completedAt: .now,
            cancelled: true,
            terminationReason: "cancelled",
            environment: EvaluationEnvironment(
                operatingSystem: "Test",
                locale: "en_GB",
                model: "Test model",
                modelContextSize: 4096
            ),
            attachments: [],
            results: []
        )
        try CanonicalJSON.data(for: run).write(to: directory.appending(path: "Runs/\(run.id).json"))
        store.runs = [run]
        store.selection = .run(run.id)
        store.draftSuite.cases[0].prompt = ""
        _ = store.saveSuite()
        let draft = store.draftSuite
        try Data("unreadable".utf8).write(to: directory.appending(path: "Runs/broken.json"))
        try Data("obsolete".utf8).write(to: directory.appending(path: "active-run.json"))
        try store.clearRunHistory()
        #expect(store.runs.isEmpty)
        #expect(store.selection == .suite)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.runs.isEmpty)
        #expect(reloaded.draftSuite == draft)
        #expect(reloaded.notice == nil)
    }

    @Test func resetRejectsRunningAndFileOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = store.draftSuite
        store.isRunning = true
        #expect(!store.canResetWorkspace)
        #expect(throws: (any Error).self) { try store.resetSuite() }
        #expect(throws: (any Error).self) { try store.clearRunHistory() }
        store.isRunning = false
        store.isProcessingFiles = true
        #expect(throws: (any Error).self) { try store.resetSuite() }
        store.isProcessingFiles = false
        store.isImportingFiles = true
        #expect(throws: (any Error).self) { try store.clearRunHistory() }
        #expect(store.draftSuite == original)
    }

    @Test func failedResetWritePreservesCurrentSuite() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = store.draftSuite
        try FileManager.default.removeItem(at: directory.appending(path: "suite.json"))
        try FileManager.default.createDirectory(at: directory.appending(path: "suite.json"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.resetSuite() }
        #expect(store.draftSuite == original)
        #expect(store.suite == original)
    }
}
