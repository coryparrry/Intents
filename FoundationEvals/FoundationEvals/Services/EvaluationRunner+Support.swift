import Foundation
import FoundationModels

extension EvaluationRunner {
    static let batchStoppingErrorCategories: Set<String> = [
        "rateLimited",
        "quotaLimitReached",
        "networkFailure",
        "serviceUnavailable",
        "modelUnavailable",
        "modelAssetsUnavailable",
        "timeout",
        "invalidConfiguration",
        "customProviderError",
    ]

    /// Reports whether an error category prevents dispatching further samples in the batch.
    static func stopsBatch(for category: String?) -> Bool {
        category.map(batchStoppingErrorCategories.contains) == true
    }

    enum EvaluationRunnerError: LocalizedError {
        case inputTooLarge(tokens: Int, budget: Int)
        case judgeInputTooLarge

        var errorDescription: String? {
            switch self {
            case .judgeInputTooLarge:
                "The judge input, including any correction evidence, exceeds the context budget. Shorten the rubric or reference."
            case .inputTooLarge(let tokens, let budget):
                "The composed input needs \(tokens) tokens, but this run reserves output space and allows \(budget). Shorten the prompt or remove reference files."
            }
        }
    }

    /// Copies model usage into persisted input, cached-input, output, and reasoning token counts.
    static func usage(from usage: LanguageModelSession.Usage) -> EvaluationUsage {
        EvaluationUsage(
            inputTokens: usage.input.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            outputTokens: usage.output.totalTokenCount,
            reasoningTokens: usage.output.reasoningTokenCount
        )
    }

    /// Joins nonblank text segments from reasoning entries, returning nil when none are present.
    static func reasoningText<S: Sequence>(from entries: S) -> String? where S.Element == Transcript.Entry {
        let text = entries.flatMap { entry -> [String] in
            guard case .reasoning(let reasoning) = entry else { return [] }
            return reasoning.segments.compactMap { segment in
                guard case .text(let text) = segment else { return nil }
                let content = text.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : content
            }
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Merges tool calls by identifier in first-seen order, replacing an entry only when new evidence supplies its missing output.
    static func mergingBuiltinToolCalls(
        _ existing: [EvaluationBuiltinToolTrace],
        with additions: [EvaluationBuiltinToolTrace]
    ) -> [EvaluationBuiltinToolTrace] {
        var merged = existing
        var indicesByID: [String: Int] = [:]
        for index in merged.indices {
            indicesByID[merged[index].id] = index
        }
        for addition in additions {
            if let index = indicesByID[addition.id] {
                if merged[index].output == nil, addition.output != nil {
                    merged[index] = addition
                }
            } else {
                indicesByID[addition.id] = merged.count
                merged.append(addition)
            }
        }
        return merged
    }

    /// Returns elapsed monotonic time in milliseconds for run and trace measurements.
    static func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        instant.evaluationMilliseconds(to: .now)
    }

    /// Returns an on-device availability explanation, or nil when requests can proceed.
    static func unavailableMessage(for availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading or otherwise not ready."
        case .unavailable:
            "The on-device model is unavailable for an unknown reason."
        }
    }

    /// Returns a Private Cloud Compute availability explanation, or nil when requests can proceed.
    static func unavailableMessage(
        for availability: PrivateCloudComputeLanguageModel.Availability
    ) -> String? {
        switch availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device is not eligible for Private Cloud Compute model requests."
        case .unavailable(.systemNotReady):
            "Private Cloud Compute is not ready. Check the network connection and try again."
        case .unavailable:
            "Private Cloud Compute is unavailable for an unknown reason."
        }
    }

    /// Maps runner, provider, tool, session, and model errors to stable persisted categories and messages.
    ///
    /// Task cancellation takes precedence. Known erased custom-provider messages retain a provider
    /// category, and unsupported generation guides include bounded schema and debug details.
    static func traceError(_ error: Error) -> (category: String, message: String) {
        if error is CancellationError || Task.isCancelled {
            return ("cancelled", "The evaluation was cancelled.")
        }
        if let runnerError = error as? EvaluationRunnerError {
            let category = switch runnerError {
            case .inputTooLarge: "inputTooLarge"
            case .judgeInputTooLarge: "judgeInputTooLarge"
            }
            return (category, runnerError.localizedDescription)
        }
        if let conversationError = error as? EvaluationConversationError {
            return ("invalidRestoredTranscript", conversationError.localizedDescription)
        }
        if let providerError = error as? EvaluationHTTPProviderError {
            let category = switch providerError {
            case .invalidConfiguration: "invalidConfiguration"
            case .httpStatus(408): "timeout"
            case .httpStatus(429): "rateLimited"
            case .httpStatus(let status) where [500, 502, 503, 504].contains(status):
                "serviceUnavailable"
            case .backend(let code, _): customProviderCategory(for: code)
            default: "customProviderError"
            }
            return (category, providerError.localizedDescription)
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled || Task.isCancelled {
                return ("cancelled", "The evaluation was cancelled.")
            }
            if urlError.code == .timedOut {
                return ("timeout", urlError.localizedDescription)
            }
            return ("networkFailure", urlError.localizedDescription)
        }
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return ("toolCallFailed", toolError.underlyingError.localizedDescription)
        }
        if let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            let category = switch cloudError {
            case .networkFailure: "networkFailure"
            case .quotaLimitReached: "quotaLimitReached"
            case .serviceUnavailable: "serviceUnavailable"
            @unknown default: "privateCloudComputeError"
            }
            return (category, cloudError.localizedDescription)
        }
        if let sessionError = error as? LanguageModelSession.Error {
            let category = switch sessionError {
            case .concurrentRequests: "concurrentRequests"
            case .transcriptMutationWhileResponding: "transcriptMutationWhileResponding"
            @unknown default: "sessionError"
            }
            return (category, sessionError.localizedDescription)
        }
        if error is SystemLanguageModel.Error {
            return ("modelAssetsUnavailable", error.localizedDescription)
        }

        guard let modelError = error as? LanguageModelError else {
            let message = error.localizedDescription
            if message == URLError(.timedOut).localizedDescription {
                return ("timeout", message)
            }
            if message.hasPrefix("The custom provider")
                || message.hasPrefix("A custom provider")
                || message.hasPrefix("Custom provider") {
                // Foundation Models currently erases custom executor error types.
                return ("customProviderError", message)
            }
            return ("generation", message)
        }

        let category: String
        switch modelError {
        case .contextSizeExceeded: category = "contextSizeExceeded"
        case .rateLimited: category = "rateLimited"
        case .guardrailViolation: category = "guardrailViolation"
        case .refusal: category = "refusal"
        case .unsupportedCapability: category = "unsupportedCapability"
        case .unsupportedTranscriptContent: category = "unsupportedTranscriptContent"
        case .unsupportedGenerationGuide(let context):
            return ("unsupportedGenerationGuide", unsupportedGenerationGuideMessage(
                localizedDescription: modelError.localizedDescription,
                context: context
            ))
        case .unsupportedLanguageOrLocale: category = "unsupportedLanguageOrLocale"
        case .timeout: category = "timeout"
        @unknown default: category = "languageModelError"
        }
        return (category, modelError.localizedDescription)
    }

    /// Normalizes backend error codes to shared categories used for batch termination, with unknown codes treated as provider errors.
    private static func customProviderCategory(for code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)
        return switch normalized {
        case "cancelled", "canceled": "cancelled"
        case "ratelimited": "rateLimited"
        case "quotalimitreached", "quotaexceeded": "quotaLimitReached"
        case "networkfailure", "networkerror", "connectionerror": "networkFailure"
        case "serviceunavailable": "serviceUnavailable"
        case "modelunavailable", "modelnotfound": "modelUnavailable"
        case "modelassetsunavailable": "modelAssetsUnavailable"
        case "timeout", "timedout": "timeout"
        case "contextsizeexceeded": "contextSizeExceeded"
        case "invalidconfiguration": "invalidConfiguration"
        default: "customProviderError"
        }
    }

    /// Appends bounded schema and debug context to an unsupported-guide message without duplicating the localized description.
    private static func unsupportedGenerationGuideMessage(
        localizedDescription: String,
        context: LanguageModelError.UnsupportedGenerationGuide
    ) -> String {
        var parts = [localizedDescription]
        if let schemaName = context.schemaName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !schemaName.isEmpty {
            parts.append("Schema: \(String(schemaName.prefix(256))).")
        }
        let debugDescription = context.debugDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !debugDescription.isEmpty, debugDescription != localizedDescription {
            parts.append("Details: \(String(debugDescription.prefix(2_048)))")
        }
        return parts.joined(separator: " ")
    }

    /// Creates a zero-duration admission error sample with no generated response, usage, or judge evidence.
    static func errorResult(
        evaluationCase: EvaluationCase,
        repetition: Int,
        category: String,
        message: String
    ) -> EvaluationSampleResult {
        EvaluationSampleResult(
            caseID: evaluationCase.id,
            caseName: evaluationCase.name,
            repetition: repetition,
            prompt: evaluationCase.prompt,
            effectivePrompt: nil,
            expected: evaluationCase.expected,
            response: "",
            status: .error,
            score: nil,
            rationale: nil,
            durationMilliseconds: 0,
            usage: EvaluationUsage(),
            judgeDurationMilliseconds: nil,
            judgeUsage: nil,
            errorCategory: category,
            errorMessage: message,
            judgeErrorCategory: nil,
            judgeErrorMessage: nil
        )
    }
}
