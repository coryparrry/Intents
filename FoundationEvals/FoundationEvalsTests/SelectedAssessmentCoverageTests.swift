import Foundation
import Testing
@testable import FoundationEvals

@Suite(.timeLimit(.minutes(1)))
struct SelectedAssessmentCoverageTests {
    @Test func fatalReassessmentCannotBorrowOldPassingScoresAfterRelaunch() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .status(503))
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(id: UUID(), name: "New judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture")
        var suite = suite()
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        let original = run(suite: suite)
        let originalResults = try CanonicalJSON.data(for: original.results)
        let reassessment = try await EvaluationReassessmentService().reassess(
            run: original, suite: suite, images: [], resolved: .init(connection: connection, apiKey: nil))
        // Persist only actual attempts; omitted coordinates are explicitly unscored
        // when this score set is projected, including already-saved sparse history.
        #expect(reassessment.samples.count == 1)
        #expect(fixture.completionRequestCount == 1)
        var selected = original
        selected.assessments = [reassessment]
        selected.selectedAssessmentID = reassessment.id
        let saved = try CanonicalJSON.data(for: selected)
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: saved)

        for candidate in [selected, restored] {
            #expect(candidate.passedCount == 0)
            #expect(candidate.failedCount == 0)
            #expect(candidate.scoredCount == 0)
            #expect(candidate.passRate == nil)
            #expect(candidate.averageScore == nil)
            #expect(candidate.effectiveResults.count == 3)
            #expect(candidate.effectiveResults.allSatisfy { $0.status == .unscored && $0.score == nil })
            #expect(candidate.effectiveResults[0].judgeErrorCategory == "serviceUnavailable")
            for skipped in candidate.effectiveResults.dropFirst() {
                #expect(skipped.judgeErrorCategory == "assessmentNotAttempted")
                #expect(skipped.judgeDurationMilliseconds == nil)
                #expect(skipped.judgeUsage == nil)
                #expect(skipped.judgeTrace == nil)
                #expect(skipped.judgeCost == nil)
                #expect(skipped.judgeReasoningText == nil)
            }
            #expect(try CanonicalJSON.data(for: candidate.results) == originalResults)
            let comparison = EvaluationExperimentAnalyzer.summarize(current: original, candidate: candidate)
            #expect(comparison.unchangedCaseIDs.isEmpty)
            #expect(comparison.improvedCaseIDs.isEmpty)
            #expect(comparison.suggestedDecision == .collectMoreEvidence)
            let report = EvaluationReleaseCheckEvaluator.report(projectID: UUID(), suite: suite,
                currentSuiteRevision: "current", run: candidate, baseline: nil, approvedBaseline: nil)
            // A failed HTTP attempt takes precedence over incomplete coverage.
            // Preserve the release gate's existing execution-error classification.
            #expect(report.outcome == .executionError)
            #expect(report.failures.contains { $0.contains("selected judge assessment") })
        }
        #expect(original.passedCount == 3)
    }

    @Test func presentSelectedScoresAreUsedWithoutBorrowingUnassessedScoresOrTelemetry() {
        let suite = suite()
        var run = run(suite: suite)
        let selected = assessment(run: run, origin: .reassessment)
        run.assessments = [selected]
        run.selectedAssessmentID = selected.id
        #expect(run.effectiveResults[0].status == .failed)
        #expect(run.effectiveResults[0].score == 2)
        #expect(run.effectiveResults[0].rationale == "Current assessment")
        #expect(run.effectiveResults[0].judgeCost == nil)
        #expect(run.effectiveResults[0].judgeReasoningText == nil)
        #expect(run.effectiveResults.dropFirst().allSatisfy { $0.status == .unscored })
        #expect(run.passedCount == 0)
        #expect(run.failedCount == 1)
        #expect(run.results.allSatisfy { $0.status == .passed && $0.score == 4 })
    }

    @Test func initialScoreSetRetainsItsOwnCostAndReasoningButNotMissingScores() {
        let suite = suite()
        var run = run(suite: suite)
        let selected = assessment(run: run, origin: .initialRun)
        run.assessments = [selected]
        run.selectedAssessmentID = selected.id
        #expect(run.effectiveResults[0].judgeCost?.usd == 0.1)
        #expect(run.effectiveResults[0].judgeReasoningText == "Original judge reasoning")
        #expect(run.effectiveResults.dropFirst().allSatisfy { $0.status == .unscored && $0.judgeCost == nil })
    }

    @Test func unresolvedExplicitSelectionFailsClosedWhileUnselectedLegacyRunsStayIntact() throws {
        let suite = suite()
        var run = run(suite: suite)
        let raw = try CanonicalJSON.data(for: run.results)
        #expect(run.passedCount == 3)
        run.selectedAssessmentID = UUID()
        #expect(run.passedCount == 0)
        #expect(run.effectiveResults.allSatisfy { $0.status == .unscored && $0.judgeErrorCategory == "assessmentUnavailable" })
        #expect(try CanonicalJSON.data(for: run.results) == raw)
        run.selectedAssessmentID = nil
        #expect(run.passedCount == 3)
    }

    private func suite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported."
        suite.repetitions = 1
        suite.releasePolicy.requireApprovedBaseline = false
        suite.cases = (1...3).map { .init(name: "Case \($0)", prompt: "Question \($0)", expected: "Answer \($0)") }
        return suite
    }

    private func run(suite: EvaluationSuite) -> EvaluationRun {
        let results = suite.cases.map { item in
            var sample = EvaluationSampleResult(caseID: item.id, caseName: item.name, repetition: 1,
                prompt: item.prompt, expected: item.expected, response: item.expected,
                status: .passed, score: 4, rationale: "Original judgment", durationMilliseconds: 50,
                usage: .init(inputTokens: 10, outputTokens: 5), judgeDurationMilliseconds: 20,
                judgeUsage: .init(inputTokens: 7, outputTokens: 3), errorCategory: nil, errorMessage: nil,
                judgeErrorCategory: nil, judgeErrorMessage: nil)
            sample.judgeReasoningText = "Original judge reasoning"
            sample.judgeCost = .init(availability: .known, usd: 0.1, explanation: "Original cost")
            sample.judgeTrace = .init(instructions: "Original instructions", prompt: "Original request")
            return sample
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: .modelJudge, repetitions: 1,
            judgePromptVersion: EvaluationRunner.judgePromptVersion, judgePassingScore: EvaluationSuite.judgePassingScore,
            plannedSampleCount: results.count, suiteRevision: "current", plannedCases: suite.cases,
            startedAt: date, completedAt: date, cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Subject", modelContextSize: 4096),
            attachments: [], results: results, suiteDefinition: .init(suite: suite))
    }

    private func assessment(run: EvaluationRun, origin: EvaluationAssessmentOrigin) -> EvaluationAssessment {
        .init(id: UUID(), runID: run.id, createdAt: run.completedAt, origin: origin,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Selected judge",
                endpointKind: nil, baseURL: nil, requestedModelID: "judge", reportedModelID: nil,
                provider: nil, providerOrder: []),
            promptVersion: EvaluationRunner.judgePromptVersion, rubric: run.criteria,
            passingScore: EvaluationSuite.judgePassingScore,
            samples: [.init(id: UUID(), sampleID: run.results[0].id, status: .failed, score: 2,
                rationale: "Current assessment", trace: nil, errorCategory: nil, errorMessage: nil,
                usage: nil, durationMilliseconds: 5)],
            totalUsage: nil, durationMilliseconds: 5,
            cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"), supersedesAssessmentID: nil)
    }
}
