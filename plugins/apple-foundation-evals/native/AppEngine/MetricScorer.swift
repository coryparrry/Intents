import Foundation

@available(macOS 27.0, *)
struct MetricScore: Equatable, Sendable {
    var status: EvaluationResultStatus
    var rationale: String?
}

@available(macOS 27.0, *)
enum MetricScorer {
    static func evaluate(mode: ScoringMode, expected: String, response: String) -> MetricScore {
        switch mode {
        case .review, .modelJudge:
            return MetricScore(status: .unscored, rationale: nil)
        case .exactMatch:
            guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MetricScore(status: .failed, rationale: "Exact text scoring needs a non-empty expected response.")
            }
            let matches = response.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
            return MetricScore(
                status: matches ? .passed : .failed,
                rationale: matches ? "Exact match after trimming whitespace." : "Response did not exactly match the expected text."
            )
        case .containsExpected:
            guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MetricScore(status: .failed, rationale: "Contains text scoring needs non-empty required text.")
            }
            let matches = response.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            return MetricScore(
                status: matches ? .passed : .failed,
                rationale: matches ? "Response contains the expected text." : "Response does not contain the expected text."
            )
        }
    }
}
