import Foundation
import Testing
@testable import FoundationEvals

struct RunBaselineSelectionTests {
    @Test func skipsIncompatibleNewestRunAndChoosesNewestCompatibleRun() {
        let current = makeRun()
        var oldest = current
        oldest.id = UUID()
        oldest.startedAt = current.startedAt.addingTimeInterval(-30)
        var compatible = oldest
        compatible.id = UUID()
        compatible.startedAt = current.startedAt.addingTimeInterval(-20)
        var incompatible = oldest
        incompatible.id = UUID()
        incompatible.startedAt = current.startedAt.addingTimeInterval(-10)
        incompatible.criteria = "Different rubric"

        #expect(RunBaselineSelection.defaultID(
            for: current, candidates: [oldest, incompatible, compatible]
        ) == compatible.id)
    }

    @Test func leavesBaselineUnselectedWhenNoCompatibleRunExists() {
        let current = makeRun()
        var incompatible = current
        incompatible.id = UUID()
        incompatible.startedAt = current.startedAt.addingTimeInterval(-10)
        incompatible.criteria = "Different rubric"

        #expect(RunBaselineSelection.defaultID(for: current, candidates: [incompatible]) == nil)
        #expect(RunBaselineSelection.defaultID(for: current, candidates: []) == nil)
    }

    @Test func excludesSelfDifferentSuitesAndRunsThatAreNotEarlier() {
        let current = makeRun()
        var otherSuite = current
        otherSuite.id = UUID()
        otherSuite.suiteID = UUID()
        otherSuite.startedAt = current.startedAt.addingTimeInterval(-10)
        var later = current
        later.id = UUID()
        later.startedAt = current.startedAt.addingTimeInterval(10)
        var simultaneous = current
        simultaneous.id = UUID()

        #expect(RunBaselineSelection.defaultID(
            for: current, candidates: [current, otherSuite, later, simultaneous]
        ) == nil)
    }

    @Test func excludesBaselineWhoseSelectedAssessmentChangedTheRubric() {
        let current = makeRun()
        var baseline = current
        baseline.id = UUID()
        baseline.startedAt = current.startedAt.addingTimeInterval(-10)
        let selected = EvaluationAssessment(
            id: UUID(), runID: baseline.id, createdAt: baseline.completedAt, origin: .reassessment,
            judge: .init(mode: .sameModel, connectionID: nil, connectionName: "Judge",
                         endpointKind: nil, baseURL: nil, requestedModelID: "judge",
                         reportedModelID: nil, provider: nil, providerOrder: []),
            promptVersion: "judge-v1", rubric: "A different selected rubric", passingScore: 3,
            samples: baseline.results.map {
                .init(id: UUID(), sampleID: $0.id, status: .passed, score: 4, rationale: "Passed",
                      trace: nil, errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: nil)
            }, totalUsage: nil, durationMilliseconds: 0,
            cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
            supersedesAssessmentID: nil
        )
        baseline.assessments = [selected]
        baseline.selectedAssessmentID = selected.id

        #expect(RunBaselineSelection.defaultID(for: current, candidates: [baseline]) == nil)
    }

    private func makeRun() -> EvaluationRun {
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "Expected")
        let sample = EvaluationSampleResult(
            caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: 1,
            prompt: evaluationCase.prompt, expected: evaluationCase.expected, response: "Expected",
            status: .passed, score: 4, rationale: "Meets rubric", durationMilliseconds: 100,
            usage: EvaluationUsage(), errorCategory: nil, errorMessage: nil
        )
        return EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Suite", suiteVersion: "v1",
            instructions: "Instructions", criteria: "Rubric", scoringMode: .modelJudge,
            repetitions: 1, judgePromptVersion: "judge-v1", judgePassingScore: 3,
            plannedSampleCount: 1, suiteRevision: "revision", plannedCases: [evaluationCase],
            startedAt: Date(timeIntervalSince1970: 1_000), completedAt: Date(timeIntervalSince1970: 1_001),
            cancelled: false, terminationReason: nil,
            environment: EvaluationEnvironment(
                operatingSystem: "Test OS", locale: "en_GB", model: "Test model", modelContextSize: 4_096
            ),
            attachments: [], results: [sample], execution: nil
        )
    }
}
