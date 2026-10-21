import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct WorkspaceOverviewAdmissionTests {
    @Test(arguments: [false, true])
    func partiallySavedRunsCannotEnterOverviewHistory(unreadablePendingRecord: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var blockedRunID: UUID?
        let store = EvaluationStore(supportDirectory: directory, runWriter: { data, url in
            if url.deletingPathExtension().lastPathComponent == blockedRunID?.uuidString {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "Saved", prompt: "Answer", expected: "READY")]
        #expect(store.saveSuite())
        let prior = run(store: store, sequence: 1, status: .failed)
        try store.saveCompletedRuns([prior])
        let first = run(store: store, sequence: 2, status: .passed)
        let second = run(store: store, sequence: 3, status: .passed)
        blockedRunID = second.id
        #expect(throws: EvaluationStoreError.self) { try store.saveCompletedRuns([first, second]) }
        let root = suiteDirectory(store: store, directory: directory)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Runs/\(first.id.uuidString).json").path))
        #expect(store.runs.map(\.id) == [prior.id])
        if unreadablePendingRecord {
            try Data("{ unreadable recovery record".utf8).write(to: root.appending(path: "pending-completed-runs.json"))
        }
        let summaries = await WorkspaceOverviewLoader().load(project: store.selectedProject, directory: directory)
        let summary = try #require(summaries.first)
        if unreadablePendingRecord {
            #expect(summary.state == .unavailable)
            #expect(summary.latestRunID == nil)
            #expect(summary.history.isEmpty)
        } else {
            #expect(summary.state == .failed)
            #expect(summary.latestRunID == prior.id)
            #expect(summary.history.map(\.id) == [prior.id])
        }
    }

    @Test func foreignSuiteDefinitionCannotQualifyItsCatalogEntry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let root = suiteDirectory(store: store, directory: directory)
        var foreign = store.suite
        foreign.id = UUID()
        foreign.name = "Foreign suite"
        try CanonicalJSON.data(for: foreign).write(to: root.appending(path: "suite.json"))
        let summaries = await WorkspaceOverviewLoader().load(project: store.selectedProject, directory: directory)
        let summary = try #require(summaries.first)
        #expect(summary.id == store.selectedSuiteID)
        #expect(summary.state == .unavailable)
        #expect(summary.loadError != nil)
        #expect(summary.name == store.selectedSuiteRecord.name)
        #expect(summary.latestRunID == nil)
    }

    private func run(store: EvaluationStore, sequence: UInt64, status: EvaluationResultStatus) -> EvaluationRun {
        let item = store.suite.cases[0]
        let result = EvaluationSampleResult(caseID: item.id, caseName: item.name, repetition: 1,
            prompt: item.prompt, expected: item.expected, response: status == .passed ? "READY" : "WRONG",
            status: status, score: nil, rationale: nil, durationMilliseconds: 10,
            usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil)
        return EvaluationRun(id: UUID(), suiteID: store.suite.id, suiteName: store.suite.name, suiteVersion: store.suite.version,
            instructions: store.suite.instructions, criteria: store.suite.criteria, scoringMode: .exactMatch,
            repetitions: 1, judgePromptVersion: nil, judgePassingScore: nil, plannedSampleCount: 1,
            suiteRevision: store.suiteRevision, plannedCases: store.suite.cases, historySequence: sequence,
            startedAt: Date(), completedAt: Date(),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 4096),
            attachments: [], results: [result], projectID: store.selectedProjectID)
    }

    private func suiteDirectory(store: EvaluationStore, directory: URL) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: directory,
            projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WorkspaceOverviewAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
