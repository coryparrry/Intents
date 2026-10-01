import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct WorkspacePresentationTests {
    @Test func savedResultsDistinguishPassingFailingAndUnassessedRuns() {
        for (status, expected) in [(EvaluationResultStatus.passed, SuiteCheckState.passed),
                                   (.failed, .failed), (.unscored, .collected), (.error, .incomplete)] {
            let run = fixture(status: status)
            #expect(SuiteCheckState.evaluate(run: run, currentRevision: "current", hasDraft: false) == expected)
        }
        #expect(SuiteCheckState.evaluate(run: nil, currentRevision: "current", hasDraft: false) == .notRun)
    }

    @Test func changedSuitesDoNotDisplayOldPassingChecksAsCurrent() {
        let run = fixture()
        #expect(SuiteCheckState.evaluate(run: run, currentRevision: "changed", hasDraft: false) == .changed)
        #expect(SuiteCheckState.evaluate(run: run, currentRevision: "current", hasDraft: true) == .changed)
    }

    @Test func missingAndCancelledSamplesCannotLookPassed() {
        var run = fixture()
        run.plannedSampleCount = 2
        #expect(SuiteCheckState.evaluate(run: run, currentRevision: "current", hasDraft: false) == .incomplete)
        run.plannedSampleCount = 1
        run.cancelled = true
        #expect(SuiteCheckState.evaluate(run: run, currentRevision: "current", hasDraft: false) == .incomplete)
        run.cancelled = false
        run.results = []
        run.plannedSampleCount = 0
        #expect(SuiteCheckState.evaluate(run: run, currentRevision: "current", hasDraft: false) == .incomplete)
    }

    @Test func overviewReadsOtherSuitesWithoutChangingSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let first = store.selectedSuiteID
        #expect(store.saveSuite())
        var run = fixture()
        run.suiteID = first
        run.suiteRevision = store.suiteRevision
        let root = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: first
        )
        try CanonicalJSON.data(for: run).write(to: root.appending(path: "Runs/\(run.id).json"))
        let second = try store.createSuite(name: "Second suite")
        let summaries = await WorkspaceOverviewLoader().load(project: store.selectedProject, directory: directory)
        #expect(summaries.first { $0.id == first }?.state == .passed)
        #expect(summaries.first { $0.id == first }?.latestRunID == run.id)
        #expect(summaries.first { $0.id == second }?.state == .notRun)
        #expect(store.selectedSuiteID == second)
        #expect(store.runs.isEmpty)

        try store.switchSuite(id: first)
        store.draftSuite.name = "Draft name"
        try store.switchSuite(id: second)
        let draftSummaries = await WorkspaceOverviewLoader().load(project: store.selectedProject, directory: directory)
        #expect(draftSummaries.first { $0.id == first }?.state == .changed)
        #expect(draftSummaries.first { $0.id == first }?.name == "Draft name")
    }

    @Test func foreignAndMismatchedRunFilesDoNotReplaceOwnedHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        var owned = fixture()
        owned.suiteID = store.suite.id
        owned.projectID = store.selectedProjectID
        owned.suiteRevision = store.suiteRevision
        owned.historySequence = 1
        var foreign = fixture()
        foreign.suiteID = UUID()
        foreign.projectID = store.selectedProjectID
        foreign.historySequence = 99
        var renamed = fixture()
        renamed.suiteID = store.suite.id
        renamed.projectID = store.selectedProjectID
        renamed.historySequence = 50
        let root = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ).appending(path: "Runs")
        try CanonicalJSON.data(for: owned).write(to: root.appending(path: "\(owned.id.uuidString).json"))
        try CanonicalJSON.data(for: foreign).write(to: root.appending(path: "\(foreign.id.uuidString).json"))
        try CanonicalJSON.data(for: renamed).write(to: root.appending(path: "mismatched-name.json"))

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.runs.map(\.id) == [owned.id])
        #expect(reloaded.notice?.contains("did not belong to this suite and was ignored") == true)
        #expect(reloaded.notice?.contains("could not be read") == false)

        let summaries = await WorkspaceOverviewLoader().load(
            project: reloaded.selectedProject,
            directory: directory
        )
        #expect(summaries.first?.latestRunID == owned.id)
        let releaseReport = try reloaded.projectReleaseCheckReport(projectID: reloaded.selectedProjectID)
        #expect(releaseReport.suites.first?.report.failures.contains {
            $0.contains("unreadable run record")
        } == false)
    }

    @Test func corruptSuiteHistoryDoesNotMasqueradeAsNeverRunOrHideOtherSuites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        let first = store.selectedSuiteID
        let root = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: first
        )
        try Data("invalid-json".utf8).write(to: root.appending(path: "Runs/broken.json"))
        let second = try store.createSuite(name: "Unaffected suite")
        let summaries = await WorkspaceOverviewLoader().load(project: store.selectedProject, directory: directory)
        #expect(summaries.first { $0.id == first }?.state == .unavailable)
        #expect(summaries.first { $0.id == first }?.loadError != nil)
        #expect(summaries.first { $0.id == second }?.state == .notRun)
        let releaseReport = try store.projectReleaseCheckReport(projectID: store.selectedProjectID)
        #expect(releaseReport.suites.first { $0.suiteID == first }?.report.failures.contains {
            $0.contains("unreadable run record")
        } == true)
    }

    @Test func approvedComparisonKeepsTheReviewedAssessmentWhenSelectionChanges() {
        var run = fixture()
        let approved = assessment(for: run, status: .passed)
        let later = assessment(for: run, status: .failed)
        run.assessments = [approved, later]
        run.selectedAssessmentID = later.id
        var approval = EvaluationBaselineApproval(
            id: UUID(), runID: run.id, assessmentID: approved.id, suiteRevision: "current",
            approvedAt: .now, note: nil, revokedAt: nil
        )
        let baseline = BaselinePresentation.approvedRun(approval: approval, runs: [run])
        #expect(baseline?.selectedAssessmentID == approved.id)
        #expect(baseline?.passedCount == 1)
        #expect(run.selectedAssessmentID == later.id)
        approval.assessmentID = UUID()
        #expect(BaselinePresentation.approvedRun(approval: approval, runs: [run]) == nil)
        approval.assessmentID = nil
        #expect(BaselinePresentation.approvedRun(approval: approval, runs: [run])?.passedCount == 1)
    }

    @Test func repositoryEditsInvalidatePassingOverviewWithoutSwitchingSuites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appending(path: "repository")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        let store = EvaluationStore(supportDirectory: directory.appending(path: "storage"))
        try store.linkSelectedProject(toRepository: repository.path)
        var run = fixture()
        run.suiteID = store.suite.id
        run.suiteRevision = store.suiteRevision
        let root = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: store.overviewStorageDirectory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
        try CanonicalJSON.data(for: run).write(to: root.appending(path: "Runs/\(run.id).json"))
        let loader = WorkspaceOverviewLoader()
        let initial = await loader.load(project: store.selectedProject, directory: store.overviewStorageDirectory)
        #expect(initial.first?.state == .passed)
        let definitionURL = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord
        ))
        var definition = EvaluationSuiteDefinition(suite: store.suite)
        definition.instructions = "Changed outside the app"
        try CanonicalJSON.data(for: definition).write(to: definitionURL)
        let refreshed = await loader.load(project: store.selectedProject, directory: store.overviewStorageDirectory)
        #expect(refreshed.first?.state == .changed)
        #expect(refreshed.first?.repositoryChanged == true)
        #expect(store.suite.instructions != definition.instructions)
    }

    @Test func overviewUsesDurableHistoryOrderWhenRunTimestampsDiffer() {
        let suite = EvaluationSuite()
        let record = EvaluationSuiteRecord(id: suite.id, name: suite.name, createdAt: .now, updatedAt: .now,
                                           archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil)
        var older = fixture(status: .failed)
        older.historySequence = 1
        older.startedAt = .distantFuture
        var latest = fixture()
        latest.historySequence = 2
        let summary = SuiteOverviewSummary(record: record, suite: suite, currentRevision: "current", draft: nil,
                                           runs: [older, latest], localState: .init())
        #expect(summary.latestRunID == latest.id)
        #expect(summary.state == .passed)
    }

    @Test func overviewHidesBaselineApprovalWhenItsRunOrAssessmentIsMissing() {
        let suite = EvaluationSuite()
        let record = EvaluationSuiteRecord(
            id: suite.id,
            name: suite.name,
            createdAt: .now,
            updatedAt: .now,
            archivedAt: nil,
            repositoryDefinitionPath: nil,
            lastRepositoryRevision: nil
        )
        var run = fixture()
        run.suiteID = suite.id
        let assessment = assessment(for: run, status: .passed)
        run.assessments = [assessment]

        var state = EvaluationSuiteLocalState()
        state.baselineApprovals = [
            .init(
                id: UUID(),
                runID: run.id,
                assessmentID: assessment.id,
                suiteRevision: "current",
                approvedAt: .now,
                note: nil,
                revokedAt: nil
            )
        ]

        let valid = SuiteOverviewSummary(
            record: record,
            suite: suite,
            currentRevision: "current",
            draft: nil,
            runs: [run],
            localState: state
        )
        #expect(valid.approvedRunID == run.id)

        state.baselineApprovals[0].assessmentID = UUID()
        let missingAssessment = SuiteOverviewSummary(
            record: record,
            suite: suite,
            currentRevision: "current",
            draft: nil,
            runs: [run],
            localState: state
        )
        #expect(missingAssessment.approvedRunID == nil)

        state.baselineApprovals[0].assessmentID = assessment.id
        let missingRun = SuiteOverviewSummary(
            record: record,
            suite: suite,
            currentRevision: "current",
            draft: nil,
            runs: [],
            localState: state
        )
        #expect(missingRun.approvedRunID == nil)
    }

    private func assessment(for run: EvaluationRun, status: EvaluationResultStatus) -> EvaluationAssessment {
        .init(
            id: UUID(), runID: run.id, createdAt: .now, origin: .reassessment,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Fixture",
                         endpointKind: nil, baseURL: nil, requestedModelID: "fixture", reportedModelID: nil,
                         provider: nil, providerOrder: []),
            promptVersion: "test", rubric: run.criteria, passingScore: 3,
            samples: [.init(id: UUID(), sampleID: run.results[0].id, status: status,
                            score: status == .passed ? 4 : 1, rationale: nil, trace: nil,
                            errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: nil)],
            totalUsage: nil, durationMilliseconds: 0,
            cost: .init(availability: .known, usd: 0, explanation: "Fixture"), supersedesAssessmentID: nil
        )
    }

    private func fixture(status: EvaluationResultStatus = .passed) -> EvaluationRun {
        let evaluationCase = EvaluationCase(name: "Fixture", prompt: "Say READY", expected: "READY")
        let result = EvaluationSampleResult(
            caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: 1,
            prompt: evaluationCase.prompt, expected: evaluationCase.expected, response: "READY",
            status: status, score: status == .passed ? 4 : nil, rationale: nil,
            durationMilliseconds: 10, usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil
        )
        let now = Date()
        return EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Fixture", suiteVersion: "v1",
            instructions: "", criteria: "Return READY", scoringMode: .modelJudge,
            repetitions: 1, judgePromptVersion: "test", judgePassingScore: 3,
            plannedSampleCount: 1, suiteRevision: "current", plannedCases: [evaluationCase],
            startedAt: now, completedAt: now.addingTimeInterval(1), cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test", locale: "en", model: "Fixture", modelContextSize: 1),
            attachments: [], results: [result]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WorkspacePresentation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
