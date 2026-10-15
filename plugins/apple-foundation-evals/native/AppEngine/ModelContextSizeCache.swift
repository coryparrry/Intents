import FoundationModels

/// Context size can synchronously wait on the model service. Read it once per model,
/// rather than from every validation pass while a text editor is handling input.
@available(macOS 27.0, *)
@MainActor
@available(macOS 27.0, *)
final class ModelContextSizeCache {
    /// Apple's on-device model has a documented 4,096-token context window.
    /// Some model-service builds temporarily report zero even while the model is
    /// available, so use the documented window instead of turning every prompt
    /// into a one-token input budget.
    nonisolated static let onDeviceFallback = 4_096

    private struct Key: Hashable {
        var useCase: EvaluationSystemUseCase
        var guardrails: EvaluationGuardrails
    }

    private struct CachedValue {
        var size: Int
        var usedFallback: Bool
    }

    private var values: [Key: CachedValue] = [:]
    private let read: (EvaluationModelConfiguration) -> Int

    init(read: @escaping (EvaluationModelConfiguration) -> Int = { $0.systemModel.contextSize }) {
        self.read = read
    }

    func value(for configuration: EvaluationModelConfiguration) -> Int {
        cachedValue(for: configuration).size
    }

    func usedFallback(for configuration: EvaluationModelConfiguration) -> Bool {
        cachedValue(for: configuration).usedFallback
    }

    private func cachedValue(for configuration: EvaluationModelConfiguration) -> CachedValue {
        let key = Key(
            useCase: configuration.customizationSettings.useCase,
            guardrails: configuration.customizationSettings.guardrails
        )
        if let value = values[key] { return value }
        let reportedValue = read(configuration)
        let value = CachedValue(
            size: Self.resolvedOnDeviceContextSize(reportedValue),
            usedFallback: reportedValue <= 0
        )
        values[key] = value
        return value
    }

    nonisolated static func resolvedOnDeviceContextSize(_ reportedValue: Int) -> Int {
        reportedValue > 0 ? reportedValue : onDeviceFallback
    }

    func invalidate() {
        values.removeAll()
    }
}
