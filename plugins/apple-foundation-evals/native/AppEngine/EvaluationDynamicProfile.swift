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

    func recordActivation(_ profileName: String) {
        events.append("Activated profile: \(profileName)")
    }

    func recordDeactivation(_ profileName: String) {
        events.append("Deactivated profile: \(profileName)")
    }

    func recordPrompt(_ profileName: String) {
        events.append("Prompt received: \(profileName)")
    }

    func recordReasoning(_ profileName: String) {
        events.append("Reasoning received: \(profileName)")
    }

    func recordToolCall(toolName: String) {
        events.append("Tool call requested: \(toolName)")
    }

    func recordToolOutput(toolName: String) {
        events.append("Tool output received: \(toolName)")
    }

    func recordResponse(_ profileName: String) {
        events.append("Response received: \(profileName)")
    }

    func recordTransition(_ profileName: String) {
        transitioned = true
        recordActivation("\(profileName) · after tool")
    }

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
    private let recorder: EvaluationProfileRecorder

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
        if receivedToolOutput {
            LanguageModelSession.Profile {
                Instructions(afterToolInstructions)
            }
            .model(model)
            .samplingMode(configuration.resolvedAfterToolSamplingMode)
            .temperature(configuration.resolvedAfterToolTemperature)
            .maximumResponseTokens(configuration.afterToolMaximumResponseTokens)
            .reasoningLevel(configuration.resolvedAfterToolReasoningLevel)
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

    static func makeSession(
        model: some LanguageModel,
        instructions: String,
        tools: [any Tool],
        configuration: EvaluationProfileConfiguration,
        recorder: EvaluationProfileRecorder,
        history: [Transcript.Entry] = [],
        modelHistoryProjection: EvaluationModelHistoryProjection? = nil,
        toolBoundary: EvaluationBuiltinToolBoundary? = nil
    ) -> LanguageModelSession {
        let profile = EvaluationDynamicProfile(
            model: model,
            instructions: instructions,
            tools: tools,
            configuration: configuration,
            recorder: recorder
        )
        if history.contains(where: { entry in
            if case .toolOutput = entry { true } else { false }
        }) {
            profile.receivedToolOutput = true
        }
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
