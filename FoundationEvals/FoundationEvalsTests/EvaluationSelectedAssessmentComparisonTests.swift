import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationSelectedAssessmentComparisonTests {
    @Test(arguments: ["foreignRun", "duplicateSample", "duplicateAssessment"], [true, false])
    func invalidSelectedAssessmentDoesNotSupplyScores(kind: String, explicitSelection: Bool) throws {
        var run = makeRun()
        run.results[0].judgeReasoningText = "Original reasoning"
        var selected = assessment(for: run)
        switch kind {
        case "foreignRun": selected.runID = UUID()
        case "duplicateSample":
            var duplicate = selected.samples[0]
            duplicate.id = UUID()
            duplicate.status = .failed
            duplicate.score = 1
            selected.samples.append(duplicate)
        default: break
        }
        run.assessments = kind == "duplicateAssessment" ? [selected, selected] : [selected]
        run.selectedAssessmentID = explicitSelection ? selected.id : nil

        let result = try #require(run.effectiveResults.first)
        #expect(result.status == .unscored)
        #expect(result.score == nil)
        #expect(result.judgeErrorCategory == "assessmentInvalid")
        #expect(result.judgeErrorMessage != nil)
        #expect(result.judgeIdentity == nil)
        #expect(result.judgeReasoningText == nil)
        #expect(result.judgeCost == nil)
        #expect(result.response == run.results[0].response)
        #expect(result.usage.inputTokens == run.results[0].usage.inputTokens)
        #expect(result.usage.outputTokens == run.results[0].usage.outputTokens)
        #expect(run.results[0].status == .passed)
        #expect(run.results[0].score == 4)
        #expect(run.passedCount == 0)
        #expect(run.passRate == nil)
        #expect(run.errorCount == 1)
    }

    @Test func validPartialAssessmentPreservesItsScoresAndLeavesMissingSamplesUnscored() {
        var run = makeRun()
        var missing = run.results[0]
        missing.id = UUID()
        var selected = assessment(for: run)
        selected.samples[0].status = .failed
        selected.samples[0].score = 1
        run.results.append(missing)
        run.assessments = [selected]
        run.selectedAssessmentID = selected.id
        #expect(run.effectiveResults.map(\.status) == [.failed, .unscored])
        #expect(run.effectiveResults[0].score == 1)
        #expect(run.effectiveResults[1].judgeErrorCategory == "assessmentNotAttempted")
        #expect(run.results.allSatisfy { $0.status == .passed })
    }

    @Test func missingAssessmentFailsClosedWhileLegacyResultsRemainAvailable() {
        var run = makeRun()
        #expect(run.effectiveResults[0].status == .passed)
        run.selectedAssessmentID = UUID()
        #expect(run.effectiveResults[0].status == .unscored)
        #expect(run.effectiveResults[0].judgeErrorCategory == "assessmentUnavailable")
        #expect(run.results[0].status == .passed)
    }

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

    @Test(arguments: ["sampleID", "coordinate", "outOfRange", "plannedCount"])
    func malformedSampleStructureCannotSupplyComparisonDeltas(kind: String) {
        var baseline = makeRun()
        baseline.repetitions = 2
        baseline.plannedSampleCount = 2
        var second = baseline.results[0]
        second.id = UUID()
        second.repetition = 2
        baseline.results.append(second)
        var current = baseline
        current.id = UUID()
        current.results[0].status = .failed
        switch kind {
        case "sampleID": current.results[1].id = current.results[0].id
        case "coordinate": current.results[1].repetition = 1
        case "outOfRange": current.results[1].repetition = 3
        default: current.plannedSampleCount = 3
        }
        for pair in [(current, baseline), (baseline, current)] {
            let comparison = EvaluationRunComparison(current: pair.0, baseline: pair.1)
            #expect(comparison.compatibility == .incompatible)
            #expect(comparison.caseComparisons.isEmpty)
            #expect(comparison.meanComparableCasePassRateDelta == nil)
        }
    }

    @Test(arguments: [Int.min, -1, 0])
    func invalidPersistedPlannedCountsDoNotOverflowAnalysis(count: Int) {
        var run = makeRun()
        run.plannedSampleCount = count
        run.repetitions = count
        let analysis = EvaluationRunAnalysis(run: run)
        #expect(analysis.plannedSampleCount == 0)
        #expect(analysis.missingSampleCount == 0)
        #expect(analysis.cases[0].plannedSampleCount == 0)
        #expect(analysis.cases[0].missingSampleCount == 0)
        #expect(EvaluationRunComparison(current: run, baseline: run).compatibility == .incompatible)
    }

    @Test func capturedSuiteCasesSupplyComparisonDefinitionsWhenPlannedCasesAreAbsent() {
        var baseline = makeRun()
        var suite = EvaluationSuite()
        suite.cases = baseline.plannedCases ?? []
        baseline.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        baseline.plannedCases = nil
        var current = baseline
        current.id = UUID()
        suite.cases[0].expected = "Changed saved expectation"
        current.suiteDefinition = EvaluationSuiteDefinition(suite: suite)

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.caseComparisons.first?.issue == .caseDefinitionChanged)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
        #expect(EvaluationRunAnalysis(run: current).cases.first?.expected == "Changed saved expectation")
    }

    @Test func validPartialComparisonKeepsAvailableCaseEvidence() {
        var baseline = makeRun()
        baseline.repetitions = 2
        baseline.plannedSampleCount = 2
        var second = baseline.results[0]
        second.id = UUID()
        second.repetition = 2
        baseline.results.append(second)
        var current = baseline
        current.id = UUID()
        current.results.removeLast()
        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.caseComparisons.first?.issue == .incompleteScoredCoverage)
        #expect(comparison.caseComparisons.first?.current?.scoredSampleCount == 1)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
    }

    @Test(arguments: [false, true])
    func legacyMissingRunCoverageRemainsPartialWhileAvailableCasesCompare(missingBaseline: Bool) {
        let complete = makeRun()
        var incomplete = complete
        incomplete.id = UUID()
        incomplete.plannedCases = nil
        incomplete.suiteDefinition = nil
        incomplete.plannedSampleCount = 2
        incomplete.results[0].status = .failed
        let comparison = EvaluationRunComparison(
            current: missingBaseline ? complete : incomplete,
            baseline: missingBaseline ? incomplete : complete
        )
        #expect(EvaluationRunAnalysis(run: incomplete).missingSampleCount == 1)
        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.caseComparisons.count == 1)
        #expect(comparison.caseComparisons[0].issue == nil)
        #expect(comparison.meanComparableCasePassRateDelta == (missingBaseline ? 1 : -1))
    }

    @Test func emptyRunsDoNotClaimComparableCoverage() {
        var run = makeRun()
        run.plannedCases = []
        run.results = []
        run.plannedSampleCount = 0
        let comparison = EvaluationRunComparison(current: run, baseline: run)
        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.caseComparisons.isEmpty)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
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
