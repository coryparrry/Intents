import Foundation
import Testing
@testable import FoundationEvals

struct ScoringAttributionTests {
    @Test func namesAnIndependentJudgeModel() {
        var result = sample(status: .unscored)
        result.judgeIdentity = EvaluationJudgeIdentity(
            mode: .connection,
            connectionID: UUID(),
            connectionName: "Custom judge",
            endpointKind: .customCompatible,
            baseURL: "https://api.deepseek.com",
            requestedModelID: "deepseek-flash",
            reportedModelID: nil,
            provider: nil,
            providerOrder: []
        )
        #expect(result.scorerSummary(scoringMode: .modelJudge) == "Custom judge · deepseek-flash")
    }

    @Test func prefersTheReportedJudgeModelAndKeepsTheRequestedID() {
        var result = sample(status: .passed, score: 4)
        result.judgeIdentity = EvaluationJudgeIdentity(
            mode: .connection,
            connectionID: UUID(),
            connectionName: "Custom judge",
            endpointKind: .customCompatible,
            baseURL: "https://api.deepseek.com",
            requestedModelID: "deepseek-flash",
            reportedModelID: "deepseek-flash-reported",
            provider: "deepseek",
            providerOrder: []
        )
        #expect(
            result.scorerSummary(scoringMode: .modelJudge)
                == "Custom judge · deepseek-flash-reported (requested deepseek-flash) · deepseek"
        )
    }

    @Test func namesLocalFieldAssertionsInCollectOnlyMode() {
        var result = sample(status: .passed)
        result.fieldAssertionResults = [
            EvaluationFieldAssertionResult(
                assertion: EvaluationFieldAssertion(pointer: "/total"),
                passed: true,
                actualJSON: "1",
                explanation: "Matched"
            )
        ]
        #expect(result.scorerSummary(scoringMode: .review) == "JSON field assertions (local)")
    }

    @Test func namesDeterministicExactChecksWithoutAModelID() {
        var result = sample(status: .passed, score: 4)
        result.judgeIdentity = EvaluationJudgeIdentity(
            mode: .sameModel,
            connectionID: nil,
            connectionName: "Deterministic checks",
            endpointKind: nil,
            baseURL: nil,
            requestedModelID: "none",
            reportedModelID: "none",
            provider: "local",
            providerOrder: []
        )
        #expect(result.scorerSummary(scoringMode: .modelJudge) == "Deterministic checks")
    }

    private func sample(status: EvaluationResultStatus, score: Int? = nil) -> EvaluationSampleResult {
        EvaluationSampleResult(
            caseID: UUID(), caseName: "Example", repetition: 1,
            prompt: "Prompt", expected: "Expected", response: "Response",
            status: status, score: score, rationale: nil, durationMilliseconds: 10,
            usage: EvaluationUsage(), errorCategory: nil, errorMessage: nil
        )
    }
}
