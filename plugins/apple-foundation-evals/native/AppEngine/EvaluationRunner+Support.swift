import Foundation
import FoundationModels

@available(macOS 27.0, *)
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

    /// Reports whether a failure category requires stopping subsequent samples in the batch.
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

    /// Projects SDK usage totals into saved input, cached-input, output, and reasoning token counts.
    static func usage(from usage: LanguageModelSession.Usage) -> EvaluationUsage {
        EvaluationUsage(
            inputTokens: usage.input.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            outputTokens: usage.output.totalTokenCount,
            reasoningTokens: usage.output.reasoningTokenCount
        )
    }

    /// Joins nonblank text from reasoning entries, returning nil when no reasoning text is present.
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

    /// Merges built-in tool traces by call ID, preserving order and replacing an existing trace only when a newly observed output fills a missing output.
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

    /// Returns a user-facing model readiness issue, or nil when the on-device model is available.
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

    /// Maps cancellation, admission, transcript, transport, tool, session, and model failures to saved error categories and explanatory messages.
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

    /// Appends bounded schema and debug details to an unsupported-generation-guide message when those details are available.
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

    /// Creates a zero-duration, empty-response error sample for a case rejected before generation.
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
