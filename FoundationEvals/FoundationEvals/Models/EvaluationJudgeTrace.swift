import Foundation

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

struct EvaluationJudgeAttemptTrace: Codable, Sendable {
    var prompt: String
    var rawResponse: String? = nil
    var validationError: String? = nil
}
