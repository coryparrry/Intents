import Foundation

@available(macOS 27.0, *)
struct EvaluationJudgeTrace: Codable, Sendable {
    var instructions: String
    var prompt: String
    var rawResponse: String? = nil
    var checks: [EvaluationJudgeCriterionTrace]? = nil
    var validationError: String? = nil
    var attempts: [EvaluationJudgeAttemptTrace]? = nil
    var judgedCriterionIndexes: [Int]? = nil
    var refusal: EvaluationRefusalTrace? = nil
}

@available(macOS 27.0, *)
struct EvaluationJudgeAttemptTrace: Codable, Sendable {
    var prompt: String
    var rawResponse: String? = nil
    var validationError: String? = nil
    /// Older traces remain readable; no policy is invented for historical data.
    var requestConfiguration: EvaluationJudgeRequestConfiguration? = nil
}

/// The same immutable value drives the wire request and the saved audit trail.
/// Credentials, headers and image bytes deliberately do not belong here.
@available(macOS 27.0, *)
struct EvaluationJudgeRequestConfiguration: Codable, Equatable, Sendable {
    var promptVersion: String
    var instructions: String
    var modelID: String
    var criteriaCount: Int
    var responseFormat: String
    var maximumResponseTokens: Int
    var timeoutSeconds: Double
    var stream: Bool
    var thinking: Bool
}
