import SwiftUI

struct ModelCustomizationSection: View {
    @Binding var configuration: EvaluationModelConfiguration
    let supportsReasoning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if configuration.provider == .onDevice {
            Text("System model").font(.headline)
            Picker("Use case", selection: $configuration.customizationSettings.useCase) {
                ForEach(EvaluationSystemUseCase.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("System model use case")
            .accessibilitySelectionActions(
                EvaluationSystemUseCase.allCases,
                selection: $configuration.customizationSettings.useCase,
                title: \.title
            )
            Text("Content tagging uses Apple's specialized tagging model. Its capabilities and context window may differ from the general model.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Guardrails", selection: $configuration.customizationSettings.guardrails) {
                ForEach(EvaluationGuardrails.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("System model guardrails")
            .accessibilitySelectionActions(
                EvaluationGuardrails.allCases,
                selection: $configuration.customizationSettings.guardrails,
                title: \.title
            )
            Text("Permissive transformations apply to plain text responses. Guided output keeps the default guardrails, and the model can still refuse a request.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Reasoning", selection: $configuration.reasoningLevel) {
                ForEach(EvaluationReasoningLevel.allCases) {
                    Text($0.title).tag($0).disabled(!supportsReasoning && $0 != .automatic)
                }
            }
            .accessibilitySelectionActions(
                EvaluationReasoningLevel.allCases.filter { supportsReasoning || $0 == .automatic },
                selection: $configuration.reasoningLevel,
                title: \.title
            )
            if configuration.reasoningLevel == .custom {
                TextField("Provider reasoning value", text: $configuration.customizationSettings.reasoningName)
                    .textFieldStyle(.roundedBorder)
            }
            if !supportsReasoning {
                Text("This model does not expose explicit reasoning levels. Keep Automatic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Request behavior").font(.headline)
            Picker("Schema guidance", selection: $configuration.customizationSettings.schemaPrompt) {
                ForEach(EvaluationSchemaPromptPolicy.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("Schema prompt policy")
            .accessibilitySelectionActions(
                EvaluationSchemaPromptPolicy.allCases,
                selection: $configuration.customizationSettings.schemaPrompt,
                title: \.title
            )
            Text("Guided generation still enforces the schema when its textual guidance is omitted. Including it helps the model interpret the requested structure. The AI judge always includes its own schema guidance.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Tool calling", selection: $configuration.customizationSettings.toolCalling) {
                ForEach(EvaluationToolCallingPolicy.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("Tool calling policy")
            .accessibilitySelectionActions(
                EvaluationToolCallingPolicy.allCases,
                selection: $configuration.customizationSettings.toolCalling,
                title: \.title
            )
            Text("Automatic allows configured tools. Required asks for a tool on every model request and can reach the call limit. An enabled dynamic profile supplies its own changing tool policy.")
                .font(.caption).foregroundStyle(.secondary)
            ModelTraceControls(configuration: $configuration.customizationSettings)
            Divider()
            VisionToolControls(configuration: $configuration.customizationSettings.visionSettings)
        }
    }
}

private struct ModelTraceControls: View {
    @Binding var configuration: EvaluationModelCustomization
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Transcript and errors").font(.headline)
            Toggle("Save full public transcript", isOn: $configuration.captureTranscript)
                .accessibilityIdentifier("Save full transcript")
            Text("Includes instructions, prompts, responses, and tool inputs/outputs, including reference passages. Saved locally with the run and included in JSON exports. This enables transcript review and Apple feedback attachment export.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("On generation error", selection: $configuration.errorPolicy) {
                ForEach(EvaluationTranscriptErrorPolicy.allCases) { Text($0.title).tag($0) }
            }
            .accessibilitySelectionActions(
                EvaluationTranscriptErrorPolicy.allCases,
                selection: $configuration.errorPolicy,
                title: \.title
            )
            Text("Preserve keeps the failed request and partial generation in session history. Revert restores history to before the request; discarded content cannot be exported.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Prewarm customization").font(.headline)
            TextField("Known prompt prefix", text: $configuration.warmupPrefix)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Prewarm prompt prefix")
            Stepper("Lead time: \(configuration.warmupSeconds.formatted()) seconds", value: $configuration.warmupSeconds, in: 0...10, step: 1)
                .accessibilityIdentifier("Prewarm lead time")
            Text("Enable prewarming in Performance to use these settings. Match the prefix to the start of your prompt. Lead time allows extra preparation but does not guarantee a faster response.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
