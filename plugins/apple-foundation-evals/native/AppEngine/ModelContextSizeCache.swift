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

    /// Creates an empty context-size cache with an injectable synchronous model-size reader.
    init(read: @escaping (EvaluationModelConfiguration) -> Int = { $0.systemModel.contextSize }) {
        self.read = read
    }

    /// Returns the cached context size for the configured use case and guardrails, reading the model once on a cache miss.
    func value(for configuration: EvaluationModelConfiguration) -> Int {
        cachedValue(for: configuration).size
    }

    /// Reports whether the cached model-size reading required the on-device fallback window.
    func usedFallback(for configuration: EvaluationModelConfiguration) -> Bool {
        cachedValue(for: configuration).usedFallback
    }

    /// Reads and caches one context-size result per use-case and guardrail pair, tracking whether a nonpositive report required fallback.
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

    /// Uses the reported context size when positive, otherwise the 4,096-token on-device fallback.
    nonisolated static func resolvedOnDeviceContextSize(_ reportedValue: Int) -> Int {
        reportedValue > 0 ? reportedValue : onDeviceFallback
    }

    /// Clears cached model-size readings so subsequent lookups query the reader again.
    func invalidate() {
        values.removeAll()
    }
}
