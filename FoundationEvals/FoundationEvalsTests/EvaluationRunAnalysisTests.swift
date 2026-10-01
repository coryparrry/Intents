import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationRunAnalysisTests {
    @Test func analysisPartitionsResultsAndSeparatesOperationalMetrics() {
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let run = makeRun(
            cases: [evaluationCase],
            repetitions: 8,
            results: [
                sample(evaluationCase, repetition: 1, status: .passed, duration: 100, usage: usage(10, 2)),
                sample(evaluationCase, repetition: 2, status: .failed, duration: 200, usage: usage(20, 3)),
                sample(evaluationCase, repetition: 3, status: .unscored, duration: 300, usage: usage(30, 4)),
                sample(
                    evaluationCase,
                    repetition: 4,
                    status: .unscored,
                    duration: 400,
                    usage: usage(40, 5),
                    judgeUsage: usage(8, 2),
                    judgeError: true
                ),
                sample(
                    evaluationCase,
                    repetition: 5,
                    status: .unscored,
                    duration: 450,
                    usage: usage(50, 6),
                    judgeError: true
                ),
                sample(
                    evaluationCase,
                    repetition: 6,
                    status: .error,
                    duration: 500,
                    usage: usage(7, 1),
                    subjectError: true
                ),
                sample(
                    evaluationCase,
                    repetition: 7,
                    status: .error,
                    duration: 600,
                    subjectError: true
                )
            ]
        )

        let analysis = EvaluationRunAnalysis(run: run)

        #expect(analysis.plannedSampleCount == 8)
        #expect(analysis.completedSampleCount == 7)
        #expect(analysis.missingSampleCount == 1)
        #expect(analysis.scoredSampleCount == 2)
        #expect(analysis.passedSampleCount == 1)
        #expect(analysis.failedSampleCount == 1)
        #expect(analysis.unscoredSampleCount == 1)
        #expect(analysis.errorSampleCount == 4)
        #expect(analysis.subjectLatency.sampleCount == 5)
        #expect(analysis.subjectLatency.p50Milliseconds == 300)
        #expect(analysis.subjectLatency.p95Milliseconds == 440)
        #expect(analysis.subjectUsage.requestCount == 6)
        #expect(analysis.subjectUsage.usageUnavailableSampleCount == 1)
        #expect(analysis.subjectUsage.inputTokens == 157)
        #expect(analysis.subjectUsage.outputTokens == 21)
        #expect(analysis.judgeUsage.requestCount == 1)
        #expect(analysis.judgeUsage.usageUnavailableSampleCount == 1)
        #expect(analysis.judgeUsage.totalTokens == 10)
    }

    @Test func repeatedPassAndFailOutcomesAreReportedAsVariation() {
        let evaluationCase = EvaluationCase(name: "Variable", prompt: "Prompt", expected: "Expected")
        let run = makeRun(
            cases: [evaluationCase],
            repetitions: 3,
            results: [
                sample(evaluationCase, repetition: 1, status: .passed),
                sample(evaluationCase, repetition: 2, status: .failed),
                sample(evaluationCase, repetition: 3, status: .passed)
            ]
        )

        let item = EvaluationRunAnalysis(run: run).cases[0]

        #expect(item.repetitionVariation == .mixedPassAndFail)
        #expect(item.passedSampleCount == 2)
        #expect(item.scoredSampleCount == 3)
        #expect(item.scoredPassRate == 2.0 / 3.0)
    }

    @Test func scoringAndJudgePolicyMismatchesAreIncompatible() {
        let suiteID = UUID()
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        var baseline = makeRun(suiteID: suiteID, cases: [evaluationCase], scoringMode: .modelJudge)
        baseline.criteria = "Old rubric"
        baseline.judgePromptVersion = "judge-v1"
        var current = makeRun(suiteID: suiteID, cases: [evaluationCase], scoringMode: .modelJudge)
        current.criteria = "New rubric"
        current.judgePromptVersion = "judge-v2"
        current.judgePassingScore = 4

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)

        #expect(comparison.compatibility == .incompatible)
        #expect(comparison.incompatibilityReasons.count == 3)
        #expect(comparison.caseComparisons.isEmpty)
    }

    @Test func deterministicScoringIgnoresUnusedRubricChanges() {
        let suiteID = UUID()
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        var baseline = makeRun(suiteID: suiteID, cases: [evaluationCase], scoringMode: .exactMatch)
        baseline.criteria = "Old unused rubric"
        var current = baseline
        current.id = UUID()
        current.criteria = "New unused rubric"

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)

        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.incompatibilityReasons.isEmpty)
        #expect(comparison.caseComparisons[0].issue == .incompleteScoredCoverage)
    }

    @Test func missingAndChangedCasesProduceExplicitPartialCoverage() {
        let suiteID = UUID()
        let sharedID = UUID()
        let sharedBaseline = EvaluationCase(id: sharedID, name: "Shared", prompt: "Old prompt", expected: "Expected")
        let sharedCurrent = EvaluationCase(id: sharedID, name: "Shared", prompt: "New prompt", expected: "Expected")
        let baselineOnly = EvaluationCase(name: "Removed", prompt: "B", expected: "B")
        let currentOnly = EvaluationCase(name: "Added", prompt: "C", expected: "C")
        let baseline = makeRun(suiteID: suiteID, cases: [sharedBaseline, baselineOnly])
        let current = makeRun(suiteID: suiteID, cases: [sharedCurrent, currentOnly])

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)

        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.coverage.changedCaseCount == 1)
        #expect(comparison.coverage.currentOnlyCaseCount == 1)
        #expect(comparison.coverage.baselineOnlyCaseCount == 1)
        #expect(comparison.caseComparisons.count == 3)
        #expect(comparison.caseComparisons.allSatisfy { $0.change == .notComparable })
    }

    @Test func changedFieldAssertionsAreNotComparable() {
        var evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        evaluationCase.fieldAssertions = [.init(pointer: "/score", operation: .minimum, expectedValue: "5")]
        let baseline = makeRun(cases: [evaluationCase], results: [sample(evaluationCase, repetition: 1, status: .passed)])
        var current = baseline
        current.id = UUID()
        current.plannedCases?[0].fieldAssertions?[0].expectedValue = "10"

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        #expect(comparison.compatibility == .partialCoverage)
        #expect(comparison.caseComparisons.first?.issue == .caseDefinitionChanged)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
    }

    @Test func changedConversationSetupOrHistoryIsNotComparable() {
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let baseline = makeRun(cases: [evaluationCase], results: [sample(evaluationCase, repetition: 1, status: .passed)])
        var current = baseline
        current.id = UUID()
        current.plannedCases?[0].conversation.setupTurns = [.init(prompt: "Remember Paris")]
        #expect(EvaluationRunComparison(current: current, baseline: baseline).caseComparisons.first?.issue == .caseDefinitionChanged)
        current.plannedCases?[0].conversation.setupTurns = []
        current.plannedCases?[0].conversation.historyPolicy = .resetBeforeFinal
        #expect(EvaluationRunComparison(current: current, baseline: baseline).caseComparisons.first?.issue == .caseDefinitionChanged)
    }

    @Test func comparisonIgnoresEditorIDsAndNormalizesAbsentOptionalChecks() throws {
        var evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        evaluationCase.fieldAssertions = [.init(pointer: "/score", operation: .exists)]
        evaluationCase.conversation.setupTurns = [.init(prompt: "Remember Paris")]
        let baseline = makeRun(cases: [evaluationCase], results: [sample(evaluationCase, repetition: 1, status: .passed)])
        var current = baseline
        current.id = UUID()
        current.plannedCases?[0].fieldAssertions?[0].id = UUID()
        current.plannedCases?[0].conversation.setupTurns[0].id = UUID()
        #expect(EvaluationRunComparison(current: current, baseline: baseline).compatibility == .compatible)

        var analysis = EvaluationRunAnalysis(run: baseline)
        analysis.cases[0].conversation = nil
        analysis.cases[0].fieldAssertions = nil
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(EvaluationRunAnalysis.self, from: data)
        #expect(decoded.cases[0].conversation == nil)
        #expect(decoded.cases[0].fieldAssertions == nil)
    }

    @Test func incompleteScoredCoverageCannotAppearImproved() {
        let suiteID = UUID()
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let baseline = makeRun(
            suiteID: suiteID,
            cases: [evaluationCase],
            repetitions: 2,
            results: [
                sample(evaluationCase, repetition: 1, status: .failed),
                sample(evaluationCase, repetition: 2, status: .failed)
            ]
        )
        let current = makeRun(
            suiteID: suiteID,
            cases: [evaluationCase],
            repetitions: 2,
            results: [sample(evaluationCase, repetition: 1, status: .passed)]
        )

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        let item = comparison.caseComparisons[0]

        #expect(comparison.compatibility == .partialCoverage)
        #expect(item.current?.passedSampleCount == 1)
        #expect(item.current?.scoredSampleCount == 1)
        #expect(item.current?.plannedSampleCount == 2)
        #expect(item.change == .notComparable)
        #expect(item.issue == .incompleteScoredCoverage)
        #expect(comparison.improvedCaseCount == 0)
        #expect(comparison.meanComparableCasePassRateDelta == nil)
    }

    @Test func completeRepeatedCasesCompareAggregatePassRatesAndRoundTrip() throws {
        let suiteID = UUID()
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let baseline = makeRun(
            suiteID: suiteID,
            cases: [evaluationCase],
            repetitions: 3,
            results: [
                sample(evaluationCase, repetition: 1, status: .passed),
                sample(evaluationCase, repetition: 2, status: .failed),
                sample(evaluationCase, repetition: 3, status: .failed)
            ]
        )
        var current = makeRun(
            suiteID: suiteID,
            cases: [evaluationCase],
            repetitions: 3,
            results: [
                sample(evaluationCase, repetition: 1, status: .failed),
                sample(evaluationCase, repetition: 2, status: .passed),
                sample(evaluationCase, repetition: 3, status: .passed)
            ]
        )
        current.environment.model = "A different subject model"

        let comparison = EvaluationRunComparison(current: current, baseline: baseline)
        let item = comparison.caseComparisons[0]

        #expect(comparison.compatibility == .compatible)
        #expect(comparison.warnings.contains(.subjectModelChanged))
        #expect(comparison.warnings.contains(.executionContractUnavailable))
        #expect(item.change == .improved)
        #expect(item.current?.passedSampleCount == 2)
        #expect(item.current?.scoredSampleCount == 3)
        #expect(item.baseline?.passedSampleCount == 1)
        #expect(item.baseline?.scoredSampleCount == 3)
        #expect(abs((item.passRateDelta ?? 0) - (1.0 / 3.0)) < 0.000_001)

        let data = try JSONEncoder().encode(comparison)
        let decoded = try JSONDecoder().decode(EvaluationRunComparison.self, from: data)
        #expect(decoded == comparison)
    }
}

private func makeRun(
    suiteID: UUID = UUID(),
    cases: [EvaluationCase],
    repetitions: Int = 1,
    scoringMode: ScoringMode = .exactMatch,
    results: [EvaluationSampleResult] = []
) -> EvaluationRun {
    EvaluationRun(
        id: UUID(),
        suiteID: suiteID,
        suiteName: "Suite",
        suiteVersion: "v1",
        instructions: "Instructions",
        criteria: "Rubric",
        scoringMode: scoringMode,
        repetitions: repetitions,
        judgePromptVersion: scoringMode == .modelJudge ? "judge-v1" : nil,
        judgePassingScore: scoringMode == .modelJudge ? 3 : nil,
        plannedSampleCount: cases.count * repetitions,
        suiteRevision: "revision",
        plannedCases: cases,
        startedAt: Date(timeIntervalSince1970: 1_000),
        completedAt: Date(timeIntervalSince1970: 1_001),
        cancelled: false,
        terminationReason: nil,
        environment: EvaluationEnvironment(
            operatingSystem: "Test OS",
            locale: "en_GB",
            model: "Test model",
            modelContextSize: 4_096
        ),
        attachments: [],
        results: results,
        execution: nil
    )
}

private func sample(
    _ evaluationCase: EvaluationCase,
    repetition: Int,
    status: EvaluationResultStatus,
    duration: Double = 100,
    usage: EvaluationUsage = EvaluationUsage(),
    judgeUsage: EvaluationUsage? = nil,
    subjectError: Bool = false,
    judgeError: Bool = false
) -> EvaluationSampleResult {
    EvaluationSampleResult(
        caseID: evaluationCase.id,
        caseName: evaluationCase.name,
        repetition: repetition,
        prompt: evaluationCase.prompt,
        expected: evaluationCase.expected,
        response: status == .error ? "" : "Response",
        status: status,
        score: nil,
        rationale: nil,
        durationMilliseconds: duration,
        usage: usage,
        judgeDurationMilliseconds: judgeUsage == nil ? nil : 50,
        judgeUsage: judgeUsage,
        errorCategory: subjectError ? "subjectError" : nil,
        errorMessage: subjectError ? "Subject failed" : nil,
        judgeErrorCategory: judgeError ? "judgeError" : nil,
        judgeErrorMessage: judgeError ? "Judge failed" : nil
    )
}

private func usage(_ input: Int, _ output: Int) -> EvaluationUsage {
    EvaluationUsage(
        inputTokens: input,
        cachedInputTokens: 0,
        outputTokens: output,
        reasoningTokens: output / 2
    )
}
