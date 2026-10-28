import Foundation
import FoundationModels

@available(macOS 27.0, *)
extension EvaluationModelConfiguration {
    var transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy? {
        switch customizationSettings.errorPolicy {
        case .automatic: nil
        case .preserve: .preserveTranscript
        case .revert: .revertTranscript
        }
    }
    var systemModel: SystemLanguageModel {
        SystemLanguageModel(
            useCase: customizationSettings.useCase == .general ? .general : .contentTagging,
            guardrails: customizationSettings.guardrails == .standard ? .default : .permissiveContentTransformations
        )
    }

    /// Resolves the requested tool-calling mode, allowing tools in automatic mode only when tools are configured.
    func toolCallingMode(hasTools: Bool) -> GenerationOptions.ToolCallingMode {
        switch customizationSettings.toolCalling {
        case .automatic: hasTools ? .allowed : .disallowed
        case .allowed: .allowed
        case .required: .required
        case .disallowed: .disallowed
        }
    }
    static let judgeResponseTokenReserve = 1_024
    private static let judgeFixedTokenReserve = 1_024

    var generationOptions: GenerationOptions {
        GenerationOptions(
            samplingMode: resolvedSamplingMode,
            temperature: temperatureEnabled ? temperature : nil,
            maximumResponseTokens: maximumResponseTokens,
            toolCallingMode: referenceMode == .lookupTool ? .allowed : .disallowed
        )
    }

    var contextOptions: ContextOptions {
        ContextOptions(includeSchemaInPrompt: customizationSettings.schemaPrompt.value, reasoningLevel: resolvedReasoningLevel)
    }

    var samplingSummary: String {
        switch samplingMode {
        case .automatic:
            return "Automatic"
        case .greedy:
            return "Greedy"
        case .topK:
            return "Random top \(topK)" + (seedEnabled ? " · seed \(seed)" : "")
        case .probability:
            return "Random p≤\(probabilityThreshold.formatted(.number.precision(.fractionLength(2))))"
                + (seedEnabled ? " · seed \(seed)" : "")
        }
    }

    /// Allocates the input ceiling after reserving response, tool-output, and optional same-model judge capacity.
    /// Explicit shared-tool and reachable-profile response reserves replace their defaults; the configured input cap can further reduce the returned limit.
    func contextAllocation(
        contextSize: Int,
        includesModelJudge: Bool,
        customToolOutputReserve: Int = 0,
        sharedToolOutputReserve: Int? = nil,
        maximumSubjectResponseTokens: Int? = nil
    ) -> (effectiveInputLimit: Int, toolOutputReserve: Int, judgeOverheadReserve: Int) {
        let toolOutputReserve = sharedToolOutputReserve ?? ((referenceMode == .lookupTool
            ? maximumToolCalls * ReferenceLookupTool.contextTokenReservePerCall
            : 0) + customToolOutputReserve)
        let responseReserve = maximumSubjectResponseTokens ?? maximumResponseTokens
        let subjectAvailableInput = contextSize - responseReserve - toolOutputReserve
        let judgeOverheadReserve = includesModelJudge
            ? Self.judgeResponseTokenReserve + Self.judgeFixedTokenReserve + responseReserve + toolOutputReserve
            : 0
        let judgeAvailableInput = includesModelJudge ? contextSize - judgeOverheadReserve : contextSize
        let availableInput = max(1, min(subjectAvailableInput, judgeAvailableInput))
        let effectiveInputLimit = maximumInputTokens.map { min($0, availableInput) } ?? availableInput
        return (effectiveInputLimit, toolOutputReserve, judgeOverheadReserve)
    }

    private var resolvedSamplingMode: GenerationOptions.SamplingMode? {
        let resolvedSeed = seedEnabled ? seed : nil
        switch samplingMode {
        case .automatic:
            return nil
        case .greedy:
            return .greedy
        case .topK:
            return .random(top: topK, seed: resolvedSeed)
        case .probability:
            return .random(probabilityThreshold: probabilityThreshold, seed: resolvedSeed)
        }
    }

    private var resolvedReasoningLevel: ContextOptions.ReasoningLevel? {
        switch reasoningLevel {
        case .automatic:
            return nil
        case .light:
            return .light
        case .moderate:
            return .moderate
        case .deep:
            return .deep
        case .custom:
            return .custom(customizationSettings.reasoningName)
        }
    }
}

@available(macOS 27.0, *)
extension EvaluationSuite {
    /// Reserves the largest response limit reachable before or after a tool, including restored tool history.
    /// Callers that already know the active session state can avoid decoding restored history again.
    func responseTokenReserve(afterToolProfileIsReachable: Bool? = nil) -> Int {
        guard features.profile.enabled, let afterToolLimit = features.profile.afterToolMaximumResponseTokens else {
            return modelConfiguration.maximumResponseTokens
        }
        let reachable = afterToolProfileIsReachable ?? (hasConfiguredTools || cases.contains { evaluationCase in
            (try? EvaluationConversationRuntime.restoredHistory(from: evaluationCase.conversation))?.contains { entry in
                if case .toolOutput = entry { true } else { false }
            } == true
        })
        return reachable ? max(modelConfiguration.maximumResponseTokens, afterToolLimit)
            : modelConfiguration.maximumResponseTokens
    }

    var hasConfiguredTools: Bool {
        modelConfiguration.referenceMode == .lookupTool || !features.tools.isEmpty
            || !modelConfiguration.customizationSettings.visionSettings.isEmpty || features.spotlightSearch.enabled
    }

    var sharedToolOutputReserve: Int {
        let perCall = max(
            modelConfiguration.referenceMode == .lookupTool ? ReferenceLookupTool.contextTokenReservePerCall : 0,
            hasConfiguredTools ? EvaluationCustomTool.contextTokenReservePerCall : 0
        )
        return modelConfiguration.maximumToolCalls * perCall
    }
}

@available(macOS 27.0, *)
extension LanguageModelCapabilities {
    var evaluationNames: [String] {
        [
            contains(.reasoning) ? "reasoning" : nil,
            contains(.toolCalling) ? "tool calling" : nil,
            contains(.guidedGeneration) ? "guided generation" : nil,
            contains(.vision) ? "vision" : nil
        ].compactMap { $0 }
    }
}
