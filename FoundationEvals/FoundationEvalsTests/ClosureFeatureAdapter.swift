@testable import FoundationEvals

/// Test fixture for running evaluation workflows with a deterministic response.
struct ClosureFeatureAdapter: EvaluationFeatureAdapter {
    var displayName: String
    var operation: @Sendable (EvaluationFeatureInput) async throws -> String

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        EvaluationFeatureOutput(response: try await operation(input))
    }
}
