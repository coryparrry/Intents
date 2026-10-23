import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceWriteGuardTests {
    @Test(arguments: [false, true])
    func assessmentSelectionRespectsFailedRollback(blockRollback: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = StateWriteFault(blockRollback: blockRollback)
        let store = EvaluationStore(supportDirectory: directory, suiteLocalStateWriter: fault.write)
        var run = try await savedRun(in: store)
        let first = try assessment(for: run, suite: store.suite)
        let second = try assessment(for: run, suite: store.suite)
        run.assessments = [first, second]
        run.selectedAssessmentID = first.id
        store.runs[0] = run
        try store.selectAssessment(runID: run.id, assessmentID: first.id)
        let runURL = runURL(for: run, store: store, directory: directory)
        let before = try Data(contentsOf: runURL)

        try failAdoption(in: store, fault: fault)
        if blockRollback {
            #expect(throws: EvaluationStoreError.self) {
                try store.selectAssessment(runID: run.id, assessmentID: second.id)
            }
            #expect(store.run(with: run.id)?.selectedAssessmentID == first.id)
            let after = try Data(contentsOf: runURL)
            #expect(after == before)
            #expect(SHA256.hash(data: after) == SHA256.hash(data: before))
        } else {
            try store.selectAssessment(runID: run.id, assessmentID: second.id)
            #expect(store.run(with: run.id)?.selectedAssessmentID == second.id)
            let persisted = try CanonicalJSON.decode(EvaluationRun.self, from: Data(contentsOf: runURL))
            #expect(persisted.selectedAssessmentID == second.id)
        }
        await store.closeAndWait()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func reassessmentAdmissionRespectsFailedRollback(blockRollback: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = StateWriteFault(blockRollback: blockRollback)
        let requests = JudgeRequests()
        let client = EvaluationCompatibleJudgeClient(transport: { _ in
            await requests.record()
            throw URLError(.cannotConnectToHost)
        })
        let store = EvaluationStore(
            supportDirectory: directory,
            reassessmentService: EvaluationReassessmentService(client: client),
            suiteLocalStateWriter: fault.write
        )
        let run = try await savedRun(in: store)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Admission fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "fixture"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.criteria = "The response accurately answers the request."
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()
        try #require(store.saveSuite())
        let runURL = runURL(for: run, store: store, directory: directory)
        let before = try Data(contentsOf: runURL)
        let previousAssessments = store.run(with: run.id)?.assessments?.map(\.id)
        let previousSelection = store.run(with: run.id)?.selectedAssessmentID
        try failAdoption(in: store, fault: fault)

        store.reassessRun(id: run.id, connectionID: connection.id)
        if blockRollback { #expect(!store.isReassessing) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isReassessing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isReassessing)
        let requestCount = await requests.count
        if blockRollback {
            #expect(requestCount == 0)
            #expect(store.notice?.contains("Rollback also failed") == true)
            #expect(store.run(with: run.id)?.assessments?.map(\.id) == previousAssessments)
            #expect(store.run(with: run.id)?.selectedAssessmentID == previousSelection)
            #expect(try Data(contentsOf: runURL) == before)
        } else {
            // The injected transport failure proves admission without using a network or model.
            #expect(requestCount == 1)
            #expect(store.run(with: run.id)?.assessments?.count == (previousAssessments?.count ?? 0) + 1)
            let persisted = try CanonicalJSON.decode(EvaluationRun.self, from: Data(contentsOf: runURL))
            #expect(persisted.selectedAssessmentID == store.run(with: run.id)?.selectedAssessmentID)
            #expect(persisted.subjectEvidence == run.subjectEvidence)
        }
        await store.closeAndWait()
    }

    private func savedRun(in store: EvaluationStore) async throws -> EvaluationRun {
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "Saved output", prompt: "request", expected: "RESULT")]
        try #require(store.saveSuite())
        return try await store.runFeatureAdapter(
            expectedRevision: store.currentSuiteRevision(),
            adapter: ClosureFeatureAdapter(displayName: "Saved subject") { _ in "RESULT" }
        )
    }

    private func failAdoption(in store: EvaluationStore, fault: StateWriteFault) throws {
        let id = try store.createInstructionExperiment(name: "Candidate", candidateInstructions: "Return RESULT only.")
        fault.armed = true
        #expect(throws: EvaluationStoreError.self) {
            try store.decideExperiment(id: id, decision: .adoptCandidate)
        }
        fault.armed = false
        #expect(store.suiteLocalState.experiments.first { $0.id == id }?.decision == nil)
        if fault.blockRollback {
            #expect(store.notice?.contains("Rollback also failed") == true)
            #expect(!store.saveSuite())
        } else {
            #expect(store.saveSuite())
        }
    }

    private func runURL(for run: EvaluationRun, store: EvaluationStore, directory: URL) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ).appending(path: "Runs/\(run.id.uuidString).json")
    }

    private func assessment(for run: EvaluationRun, suite: EvaluationSuite) throws -> EvaluationAssessment {
        EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: .now, origin: .reassessment,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Fixture",
                         endpointKind: nil, baseURL: nil, requestedModelID: "fixture",
                         reportedModelID: nil, provider: nil, providerOrder: []),
            promptVersion: EvaluationRunner.judgePromptVersion,
            rubric: suite.criteria, passingScore: EvaluationSuite.judgePassingScore,
            samples: [], totalUsage: nil, durationMilliseconds: 1,
            cost: .init(availability: .known, usd: 0, explanation: "Fixture"),
            supersedesAssessmentID: nil, scoringContract: try EvaluationScoringContract(suite: suite),
            subjectEvidenceDigest: run.subjectEvidence?.digest
        )
    }

    @MainActor
    private final class StateWriteFault {
        let blockRollback: Bool
        var armed = false
        init(blockRollback: Bool) { self.blockRollback = blockRollback }

        func write(_ data: Data, _ url: URL) throws {
            guard armed else { try data.write(to: url, options: .atomic); return }
            if blockRollback {
                let suiteURL = url.deletingLastPathComponent().appending(path: "suite.json")
                try FileManager.default.removeItem(at: suiteURL)
                try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: false)
                try Data("conflict".utf8).write(to: suiteURL.appending(path: "keep"))
            }
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private actor JudgeRequests {
        var count = 0
        func record() { count += 1 }
    }
}
