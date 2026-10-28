import FoundationModels

@available(macOS 27.0, *)
extension SessionPropertyValues {
    @SessionPropertyEntry
    var evaluationProfileReceivedToolOutput = false
}

@available(macOS 27.0, *)
actor EvaluationProfileRecorder {
    private var events: [String] = []
    private(set) var transitioned = false

    /// Appends an activation event to the actor-isolated profile history.
    func recordActivation(_ profileName: String) {
        events.append("Activated profile: \(profileName)")
    }

    /// Appends a deactivation event for the named profile to the recorded history.
    func recordDeactivation(_ profileName: String) {
        events.append("Deactivated profile: \(profileName)")
    }

    /// Records which profile received a prompt for later feature-trace inspection.
    func recordPrompt(_ profileName: String) {
        events.append("Prompt received: \(profileName)")
    }

    /// Records the profile that received reasoning without capturing reasoning content.
    func recordReasoning(_ profileName: String) {
        events.append("Reasoning received: \(profileName)")
    }

    /// Records a requested tool's name without persisting its arguments.
    func recordToolCall(toolName: String) {
        events.append("Tool call requested: \(toolName)")
    }

    /// Records receipt of a tool output by tool name without persisting its content.
    func recordToolOutput(toolName: String) {
        events.append("Tool output received: \(toolName)")
    }

    /// Records which profile received a model response.
    func recordResponse(_ profileName: String) {
        events.append("Response received: \(profileName)")
    }

    /// Marks the after-tool transition as reached and records activation of the derived after-tool profile.
    func recordTransition(_ profileName: String) {
        transitioned = true
        recordActivation("\(profileName) · after tool")
    }

    /// Returns the currently recorded profile events in arrival order.
    func snapshot() -> [String] {
        events
    }
}

@available(macOS 27.0, *)
struct EvaluationDynamicProfile: LanguageModelSession.DynamicProfile {
    private let model: any LanguageModel
    private let instructions: String
    private let tools: [any Tool]
    private let configuration: EvaluationProfileConfiguration
    private let modelConfiguration: EvaluationModelConfiguration
    private let recorder: EvaluationProfileRecorder
    private let initiallyAfterTool: Bool

    @LanguageModelSession.SessionProperty(\.evaluationProfileReceivedToolOutput)
    private var receivedToolOutput

    private var afterToolInstructions: String {
        [instructions, configuration.afterToolInstructions]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private var initialProfileName: String { configuration.name }
    private var afterToolProfileName: String { "\(configuration.name) · after tool" }

    var body: some LanguageModelSession.DynamicProfile {
        if initiallyAfterTool || receivedToolOutput {
            LanguageModelSession.Profile {
                Instructions(afterToolInstructions)
            }
            .model(model)
            .samplingMode(configuration.resolvedAfterToolSamplingMode ?? modelConfiguration.generationOptions.samplingMode)
            .temperature(configuration.resolvedAfterToolTemperature ?? modelConfiguration.generationOptions.temperature)
            .maximumResponseTokens(configuration.afterToolMaximumResponseTokens ?? modelConfiguration.maximumResponseTokens)
            .reasoningLevel(configuration.resolvedAfterToolReasoningLevel ?? modelConfiguration.contextOptions.reasoningLevel)
            .toolCallingMode(.disallowed)
            .transcriptErrorHandlingPolicy(configuration.resolvedAfterToolTranscriptErrorPolicy)
            .onActivate {
                await recorder.recordTransition(configuration.name)
            }
            .onDeactivate {
                await recorder.recordDeactivation(afterToolProfileName)
            }
            .onPrompt {
                await recorder.recordPrompt(afterToolProfileName)
            }
            .onReasoning {
                await recorder.recordReasoning(afterToolProfileName)
            }
            .onToolCall { call in
                await recorder.recordToolCall(toolName: call.toolName)
            }
            .onToolOutput { call, _ in
                await recorder.recordToolOutput(toolName: call.toolName)
            }
            .onResponse {
                await recorder.recordResponse(afterToolProfileName)
            }
        } else {
            LanguageModelSession.Profile {
                Instructions(instructions)
                tools
            }
            .model(model)
            .samplingMode(modelConfiguration.generationOptions.samplingMode)
            .temperature(modelConfiguration.generationOptions.temperature)
            .maximumResponseTokens(modelConfiguration.maximumResponseTokens)
            .reasoningLevel(modelConfiguration.contextOptions.reasoningLevel)
            .toolCallingMode(configuration.requireToolFirst ? .required : .allowed)
            .onActivate {
                await recorder.recordActivation(configuration.name)
            }
            .onDeactivate {
                await recorder.recordDeactivation(initialProfileName)
            }
            .onPrompt {
                await recorder.recordPrompt(initialProfileName)
            }
            .onReasoning {
                await recorder.recordReasoning(initialProfileName)
            }
            .onToolCall { call in
                await recorder.recordToolCall(toolName: call.toolName)
            }
            .onToolOutput { call, _ in
                await recorder.recordToolOutput(toolName: call.toolName)
                receivedToolOutput = true
            }
            .onResponse {
                await recorder.recordResponse(initialProfileName)
            }
        }
    }

    /// Creates a two-phase profile session, starting after-tool when restored history already contains tool output.
    /// Restored phase state is immutable because session properties are not bound until the session is created.
    /// Each phase owns its generation settings, inheriting unspecified overrides from the supplied model configuration.
    /// Applies an optional tool boundary and model-only history projection while retaining the supplied session history.
    static func makeSession(
        model: some LanguageModel,
        instructions: String,
        tools: [any Tool],
        configuration: EvaluationProfileConfiguration,
        recorder: EvaluationProfileRecorder,
        modelConfiguration: EvaluationModelConfiguration = .init(),
        history: [Transcript.Entry] = [],
        modelHistoryProjection: EvaluationModelHistoryProjection? = nil,
        toolBoundary: EvaluationBuiltinToolBoundary? = nil
    ) -> LanguageModelSession {
        let profile = EvaluationDynamicProfile(
            model: model,
            instructions: instructions,
            tools: tools,
            configuration: configuration,
            modelConfiguration: modelConfiguration,
            recorder: recorder,
            initiallyAfterTool: history.contains { entry in
                if case .toolOutput = entry { true } else { false }
            }
        )
        if let toolBoundary {
            let boundedProfile = profile.modifier(toolBoundary)
            guard let modelHistoryProjection else {
                return LanguageModelSession(profile: boundedProfile, history: history)
            }
            return LanguageModelSession(
                profile: boundedProfile.historyTransform { history in
                    EvaluationConversationRuntime.projectedHistory(
                        history,
                        using: modelHistoryProjection
                    )
                },
                history: history
            )
        }
        guard let modelHistoryProjection else {
            return LanguageModelSession(profile: profile, history: history)
        }
        return LanguageModelSession(
            profile: profile.historyTransform { history in
                EvaluationConversationRuntime.projectedHistory(
                    history,
                    using: modelHistoryProjection
                )
            },
            history: history
        )
    }
}

@available(macOS 27.0, *)
extension EvaluationProfileConfiguration {
    var resolvedAfterToolSamplingMode: GenerationOptions.SamplingMode? {
        let resolvedSeed = afterToolSeedEnabled ? afterToolSeed : nil
        switch afterToolSamplingMode {
        case .automatic:
            return nil
        case .greedy:
            return .greedy
        case .topK:
            return .random(top: afterToolTopK, seed: resolvedSeed)
        case .probability:
            return .random(probabilityThreshold: afterToolProbabilityThreshold, seed: resolvedSeed)
        }
    }

    var resolvedAfterToolTemperature: Double? {
        afterToolTemperatureEnabled ? afterToolTemperature : nil
    }

    var resolvedAfterToolReasoningLevel: ContextOptions.ReasoningLevel? {
        switch afterToolReasoningLevel {
        case .automatic:
            return nil
        case .light:
            return .light
        case .moderate:
            return .moderate
        case .deep:
            return .deep
        case .custom:
            return .custom(afterToolCustomReasoning)
        }
    }

    var resolvedAfterToolTranscriptErrorPolicy: TranscriptErrorHandlingPolicy? {
        switch afterToolTranscriptErrorPolicy {
        case .automatic:
            return nil
        case .preserve:
            return .preserveTranscript
        case .revert:
            return .revertTranscript
        }
    }
}
