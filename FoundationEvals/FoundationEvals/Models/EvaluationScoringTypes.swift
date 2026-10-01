import Foundation

enum ScoringMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case review
    case exactMatch
    case containsExpected
    case modelJudge

    var id: Self { self }

    var title: String {
        switch self {
        case .review: "Collect only"
        case .exactMatch: "Exact text"
        case .containsExpected: "Contains text"
        case .modelJudge: "AI rubric"
        }
    }

    var explanation: String {
        switch self {
        case .review:
            "Collect responses for external review. The app records traces but does not assign pass or fail."
        case .exactMatch:
            "Pass only when the complete response equals the expected response after trimming outer whitespace."
        case .containsExpected:
            "Pass when the response contains the required literal text, ignoring case and accents."
        case .modelJudge:
            "Use AI for free-form requirements and exact: \"text\" for deterministic exact-output requirements. Scores are 1–4; every requirement must score at least 3 to pass."
        }
    }

    var expectedLabel: String {
        switch self {
        case .exactMatch: "Expected response (required)"
        case .containsExpected: "Required text (required)"
        case .modelJudge: "Reference answer (recommended for factual tasks)"
        case .review: ""
        }
    }

    var expectedHelp: String {
        switch self {
        case .exactMatch: "Example: Paris — the generated response must be exactly this text."
        case .containsExpected: "Example: Paris — this is literal text, not a regular expression."
        case .modelJudge: "Give the judge a known-good answer when correctness can be verified. Use Exact text scoring for deterministic equality checks. The AI rubric checks every requirement, including when the response matches this reference."
        case .review: ""
        }
    }

    var needsExpected: Bool {
        self == .exactMatch || self == .containsExpected
    }
}

enum EvaluationResultStatus: String, Codable, Sendable {
    case passed
    case failed
    case unscored
    case error
}
