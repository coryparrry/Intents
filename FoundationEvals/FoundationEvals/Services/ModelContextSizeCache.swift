import FoundationModels

/// Context size can synchronously wait on the model service. Read it once per model,
/// rather than from every validation pass while a text editor is handling input.
@MainActor
final class ModelContextSizeCache {
    private struct Key: Hashable {
        var useCase: EvaluationSystemUseCase
        var guardrails: EvaluationGuardrails
    }

    private var values: [Key: Int] = [:]
    private let read: (EvaluationModelConfiguration) -> Int

    init(read: @escaping (EvaluationModelConfiguration) -> Int = { $0.systemModel.contextSize }) {
        self.read = read
    }

    func value(for configuration: EvaluationModelConfiguration) -> Int {
        let key = Key(
            useCase: configuration.customizationSettings.useCase,
            guardrails: configuration.customizationSettings.guardrails
        )
        if let value = values[key] { return value }
        let value = read(configuration)
        values[key] = value
        return value
    }

    func invalidate() {
        values.removeAll()
    }
}
