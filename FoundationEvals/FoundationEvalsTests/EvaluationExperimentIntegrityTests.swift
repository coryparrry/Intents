import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationExperimentIntegrityTests {
    @Test(arguments: ["suite", "scoringMode", "rubric", "judgePrompt", "passingScore", "prompt", "expected", "conversation", "assertions", "selectedRubric"])
    func incompatibleEvidenceCannotRecommendAWinningVariant(change: String) throws {
        let suite = Self.suite(caseCount: 5)
        let current = Self.run(suite: suite, status: .failed)
        var candidate = Self.run(suite: suite, status: .passed)
        switch change {
        case "suite": candidate.suiteID = UUID()
        case "scoringMode": candidate.scoringMode = .exactMatch
        case "rubric": candidate.criteria = "An easier requirement."
        case "judgePrompt": candidate.judgePromptVersion = "another-policy"
        case "passingScore": candidate.judgePassingScore = 1
        case "prompt": candidate.plannedCases?[0].prompt = "Another task"
        case "expected": candidate.plannedCases?[0].expected = "Another reference"
        case "conversation": candidate.plannedCases?[0].conversation.setupTurns = [.init(prompt: "Another setup")]
        case "assertions": candidate.plannedCases?[0].fieldAssertions = [.init(pointer: "/verified", operation: .exists)]
        default:
            var selected = Self.assessment(run: candidate, usage: nil)
            selected.rubric = "An easier reassessment rubric."
            candidate.assessments = [selected]
            candidate.selectedAssessmentID = selected.id
        }
        let comparison = EvaluationRunComparison(current: candidate, baseline: current)
        #expect(comparison.compatibility != .compatible)
        let summary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
        #expect(summary.suggestedDecision == .collectMoreEvidence)
        let comparableIDs = Set(comparison.caseComparisons.filter { $0.change != .notComparable }.map(\.caseID))
        #expect(Set(summary.improvedCaseIDs).isSubset(of: comparableIDs))
    }

    @Test func instructionOnlyExperimentRetainsItsWinningRecommendation() {
        let suite = Self.suite(caseCount: 5)
        let current = Self.run(suite: suite, status: .failed)
        var candidate = Self.run(suite: suite, status: .passed)
        candidate.instructions = "The candidate instruction variant."
        let summary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
        #expect(summary.suggestedDecision == .adoptCandidate)
        #expect(summary.improvedCaseIDs.count == 5)
        #expect(summary.distinctCaseCoverage == 5)
    }

    @Test(arguments: [0, 1, 2])
    func combinedAssessmentDoesNotReportPartialPartUsage(missingPart: Int) async throws {
        var suite = Self.suite(caseCount: 1)
        suite.repetitions = 2
        let current = EvaluationExperimentVariant(id: UUID(), name: "Current", instructions: "Current", suiteRevision: "current")
        let candidate = EvaluationExperimentVariant(id: UUID(), name: "Candidate", instructions: "Candidate", suiteRevision: "candidate")
        let experiment = EvaluationExperiment(id: UUID(), name: "Usage", createdAt: Date(), suiteRevision: "fixture",
            casesDigest: "cases", scoringDigest: "scoring", judgeDigest: "judge", current: current, candidate: candidate,
            executionOrder: [current.id, candidate.id, current.id, candidate.id], runIDs: [], decision: nil)
        let counter = ExperimentPartCounter()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            let position = await counter.next()
            let usage: EvaluationUsage? = position / 2 == missingPart ? nil : .init(inputTokens: 10, outputTokens: 5)
            var run = Self.run(suite: partSuite, status: .passed)
            run.results[0].judgeUsage = usage
            let assessment = Self.assessment(run: run, usage: usage)
            run.assessments = [assessment]
            run.selectedAssessmentID = assessment.id
            return run
        }
        let result = try await runner.run(suite: suite, experiment: experiment, images: [], externalJudge: nil,
            progress: { _, _, _ in })
        for run in [result.current, result.candidate] {
            let assessment = try #require(run.selectedAssessment)
            #expect(assessment.samples.count == 2)
            if missingPart < 2 {
                #expect(assessment.samples.compactMap(\.usage).count == 1)
                #expect(assessment.totalUsage == nil)
            } else {
                #expect(assessment.totalUsage?.inputTokens == 20)
                #expect(assessment.totalUsage?.outputTokens == 10)
            }
        }
    }

    private static func suite(caseCount: Int) -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.criteria = "The response follows the reference."
        suite.cases = (0..<caseCount).map { .init(name: "Case \($0)", prompt: "Prompt \($0)", expected: "Expected \($0)") }
        return suite
    }

    private static func run(suite: EvaluationSuite, status: EvaluationResultStatus) -> EvaluationRun {
        let results = suite.cases.flatMap { item in
            (1...suite.repetitions).map { repetition in
                EvaluationSampleResult(caseID: item.id, caseName: item.name, repetition: repetition,
                    prompt: item.prompt, expected: item.expected, response: "Observed output",
                    status: status, score: status == .passed ? 4 : 1, rationale: nil,
                    durationMilliseconds: 1, usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
                    errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil)
            }
        }
        return EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
            repetitions: suite.repetitions, judgePromptVersion: EvaluationRunner.judgePromptVersion,
            judgePassingScore: EvaluationSuite.judgePassingScore, plannedSampleCount: results.count,
            suiteRevision: "fixture", plannedCases: suite.cases, startedAt: Date(), completedAt: Date(),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 8192),
            attachments: [], results: results)
    }

    private static func assessment(run: EvaluationRun, usage: EvaluationUsage?) -> EvaluationAssessment {
        .init(id: UUID(), runID: run.id, createdAt: Date(), origin: .initialRun,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Judge", endpointKind: nil, baseURL: nil,
                requestedModelID: "judge", reportedModelID: "judge", provider: nil, providerOrder: []),
            promptVersion: EvaluationRunner.judgePromptVersion, rubric: run.criteria, passingScore: EvaluationSuite.judgePassingScore,
            samples: run.results.map { .init(id: UUID(), sampleID: $0.id, status: $0.status, score: $0.score, rationale: nil,
                trace: nil, errorCategory: nil, errorMessage: nil, usage: usage, durationMilliseconds: 1) },
            totalUsage: usage, durationMilliseconds: 1, cost: .init(availability: .known, usd: 0.1, explanation: "Fixture"),
            supersedesAssessmentID: nil)
    }
}

private actor ExperimentPartCounter {
    private var position = 0
    func next() -> Int { defer { position += 1 }; return position }
}
