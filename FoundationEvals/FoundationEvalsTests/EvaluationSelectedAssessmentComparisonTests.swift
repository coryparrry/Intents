import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationSelectedAssessmentComparisonTests {
    @Test(arguments: ["rubric", "prompt", "passingScore"])
    func selectedAssessmentPolicyChangesPreventScoreComparison(_ field: String) {
        let baseline = makeRun()
        var current = baseline
        current.id = UUID()
        var selected = assessment(for: current)
        switch field {
        case "rubric": selected.rubric = "A different requirement"
        case "prompt": selected.promptVersion = "judge-v2"
        default: selected.passingScore = 5
        }
        current.assessments = [selected]
        current.selectedAssessmentID = selected.id

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)

        #expect(comparison.compatibility == .incompatible)
        #expect(comparison.incompatibilityReasons.count == 1)
        #expect(comparison.caseComparisons.isEmpty)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
    }

    @Test func matchingReassessmentsCompareTheirScoresDespiteDifferentOriginalPolicies() {
        var baseline = makeRun()
        var current = baseline
        current.id = UUID()
        current.criteria = "Different original rubric"
        current.judgePromptVersion = "different-original-prompt"
        current.judgePassingScore = 5
        var selectedBaseline = assessment(for: baseline)
        selectedBaseline.rubric = "New shared rubric"
        selectedBaseline.promptVersion = "new-shared-prompt"
        var selectedCurrent = assessment(for: current)
        selectedCurrent.rubric = selectedBaseline.rubric
        selectedCurrent.promptVersion = selectedBaseline.promptVersion
        selectedCurrent.passingScore = selectedBaseline.passingScore
        selectedCurrent.samples[0].status = .failed
        selectedCurrent.samples[0].score = 1
        baseline.assessments = [selectedBaseline]
        baseline.selectedAssessmentID = selectedBaseline.id
        current.assessments = [selectedCurrent]
        current.selectedAssessmentID = selectedCurrent.id

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)

        #expect(comparison.compatibility == .compatible)
        #expect(comparison.regressedCaseCount == 1)
        #expect(comparison.meanComparableCasePassRateDelta == -1)
        #expect(current.results[0].status == .passed)
        #expect(current.criteria == "Different original rubric")
    }

    @Test func explicitOlderAssessmentSelectionControlsCompatibility() {
        let baseline = makeRun()
        var current = baseline
        current.id = UUID()
        let originalPolicy = assessment(for: current)
        var newerPolicy = assessment(for: current)
        newerPolicy.rubric = "An incompatible newer rubric"
        current.assessments = [originalPolicy, newerPolicy]
        current.selectedAssessmentID = originalPolicy.id
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .compatible)
        current.selectedAssessmentID = newerPolicy.id
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .incompatible)
    }

    @Test func missingOrUnboundAssessmentDoesNotFallBackToOriginalPolicy() {
        let baseline = makeRun()
        var current = baseline
        current.id = UUID()
        current.selectedAssessmentID = UUID()
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .incompatible)
        let anotherRunsAssessment = assessment(for: baseline)
        current.assessments = [anotherRunsAssessment]
        current.selectedAssessmentID = anotherRunsAssessment.id
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .incompatible)
    }

    @Test func capturedContractMustMatchSelectedAssessmentMetadata() throws {
        let baseline = makeRun()
        var current = baseline
        current.id = UUID()
        var selected = assessment(for: current)
        selected.scoringContract = try EvaluationScoringContract(run: current)
        current.assessments = [selected]
        current.selectedAssessmentID = selected.id
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .compatible)
        current.assessments?[0].rubric = "Changed without updating the captured contract"
        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        #expect(comparison.compatibility == .incompatible)
        #expect(comparison.incompatibilityReasons.contains { $0.contains("inconsistent") })
    }

    private func assessment(for run: EvaluationRun) -> EvaluationAssessment {
        EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: run.completedAt, origin: .reassessment,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Judge",
                         endpointKind: nil, baseURL: nil, requestedModelID: "judge",
                         reportedModelID: nil, provider: nil, providerOrder: []),
            promptVersion: run.judgePromptVersion ?? "judge-v1", rubric: run.criteria,
            passingScore: run.judgePassingScore ?? EvaluationSuite.judgePassingScore,
            samples: run.results.map {
                .init(id: UUID(), sampleID: $0.id, status: $0.status, score: $0.score,
                      rationale: "Selected assessment", trace: nil, errorCategory: nil,
                      errorMessage: nil, usage: nil, durationMilliseconds: nil)
            }, totalUsage: nil, durationMilliseconds: 0,
            cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
            supersedesAssessmentID: nil
        )
    }

    private func makeRun() -> EvaluationRun {
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let sample = EvaluationSampleResult(
            caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: 1,
            prompt: evaluationCase.prompt, expected: evaluationCase.expected, response: "Expected",
            status: .passed, score: 4, rationale: "Meets rubric", durationMilliseconds: 100,
            usage: .init(), errorCategory: nil, errorMessage: nil
        )
        return EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Suite", suiteVersion: "v1",
            instructions: "Instructions", criteria: "Rubric", scoringMode: .modelJudge,
            repetitions: 1, judgePromptVersion: "judge-v1", judgePassingScore: 3,
            plannedSampleCount: 1, suiteRevision: "revision", plannedCases: [evaluationCase],
            startedAt: Date(timeIntervalSince1970: 1_000), completedAt: Date(timeIntervalSince1970: 1_001),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test OS", locale: "en_GB", model: "Subject", modelContextSize: 4_096),
            attachments: [], results: [sample]
        )
    }
}
