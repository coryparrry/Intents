import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationReassessmentProvenanceTests {
    @Test(arguments: [false, true])
    func reassessmentUsesSavedCasesForAssertionsAndContract(hasSubjectSnapshot: Bool) async throws {
        var (suite, run) = fixture()
        let savedSuite = suite
        let digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: suite.instructions, cases: suite.cases, attachments: []
        )
        let changedAssertion = EvaluationFieldAssertion(pointer: "/verified", operation: .equals, expectedValue: "true")
        if hasSubjectSnapshot {
            run.subjectEvidence = .init(instructions: suite.instructions, cases: suite.cases, attachments: [], digest: digest)
            run.plannedCases?[0].fieldAssertions = [changedAssertion]
        } else {
            run.plannedCases = nil
            suite.cases[0].fieldAssertions = [changedAssertion]
        }
        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [], resolved: nil,
            subjectEvidenceDigest: hasSubjectSnapshot ? digest : nil
        )
        #expect(assessment.samples.first?.status == .passed)
        #expect(assessment.scoringContract == (try EvaluationScoringContract(suite: savedSuite)))
        if hasSubjectSnapshot { #expect(assessment.subjectEvidenceDigest == digest) }
    }

    @Test func deterministicReassessmentDoesNotClaimAnUnusedExternalJudge() async throws {
        let (suite, run) = fixture()
        let client = EvaluationCompatibleJudgeClient(transport: { _ in
            Issue.record("Deterministic checks must not invoke the external judge.")
            throw CancellationError()
        })
        let assessment = try await EvaluationReassessmentService(client: client).reassess(
            run: run, suite: suite, images: [], resolved: .init(connection: connection(), apiKey: nil)
        )
        #expect(assessment.samples.first?.status == .passed)
        #expect(assessment.judge.mode == .sameModel)
        #expect(assessment.judge.connectionID == nil)
        #expect(assessment.judge.requestedModelID == "none")
        #expect(assessment.observedJudgeIdentities == [assessment.judge])
        #expect(assessment.cost.usd == 0)
    }

    @Test(arguments: [false, true])
    func cancelledInitialJudgeRequestHasUnknownCost(urlCancellation: Bool) async throws {
        var (suite, run) = fixture()
        suite.criteria = "The response is supported by the reference."
        let connection = connection()
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        )
        let client = EvaluationCompatibleJudgeClient(transport: { _ in
            if urlCancellation { throw URLError(.cancelled) }
            throw CancellationError()
        })
        let assessment = try await EvaluationReassessmentService(client: client).reassess(
            run: run, suite: suite, images: [], resolved: .init(connection: connection, apiKey: nil), origin: .initialRun
        )
        #expect(assessment.samples.first?.errorCategory == "cancelled")
        #expect(assessment.samples.first?.status == .unscored)
        #expect(assessment.cost.availability == .unavailable)
        #expect(assessment.cost.usd == nil)
        #expect(assessment.judge.connectionID == connection.id)
    }

    @Test func cancellationBeforeAnyJudgeRequestKeepsZeroCost() async throws {
        let (suite, run) = fixture()
        let assessment = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EvaluationReassessmentService().reassess(
                run: run, suite: suite, images: [], resolved: nil, origin: .initialRun
            )
        }.value
        #expect(assessment.samples.first?.errorCategory == "cancelled")
        #expect(assessment.cost.availability == .known)
        #expect(assessment.cost.usd == 0)
    }

    private func connection() -> EvaluationJudgeConnection {
        .init(id: UUID(), name: "Unused judge", kind: .localCompatible,
              baseURL: "http://127.0.0.1:11434/v1", modelID: "fixture")
    }

    private func fixture() -> (EvaluationSuite, EvaluationRun) {
        var suite = EvaluationSuite()
        suite.criteria = "The response is exactly READY."
        suite.cases = [.init(name: "Saved", prompt: "Reply READY", expected: "READY")]
        let evaluationCase = suite.cases[0]
        let sample = EvaluationSampleResult(
            caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: 1,
            prompt: evaluationCase.prompt, expected: evaluationCase.expected, response: "READY",
            status: .passed, score: 4, rationale: nil, durationMilliseconds: 1, usage: .init(),
            errorCategory: nil, errorMessage: nil
        )
        var run = EvaluationRun(
            id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: .modelJudge,
            repetitions: 1, judgePromptVersion: EvaluationRunner.judgePromptVersion, judgePassingScore: 3,
            plannedSampleCount: 1, suiteRevision: "fixture", plannedCases: suite.cases,
            startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test", locale: "en", model: "Fixture", modelContextSize: 100),
            attachments: [], results: [sample]
        )
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        return (suite, run)
    }
}
