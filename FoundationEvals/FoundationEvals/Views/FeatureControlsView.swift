import SwiftUI

private enum FeatureEditorPage: String, CaseIterable, Identifiable {
    case tools
    case profile
    case output
    case performance

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .tools: "Tools"
        case .profile: "Profile"
        case .output: "Output"
        case .performance: "Performance"
        }
    }
}

struct FeatureControlsView: View {
    @Bindable var store: EvaluationStore
    @State private var selectedPage = FeatureEditorPage.tools

    private var isDisabled: Bool {
        store.isRunning || store.isImportingFiles || store.isProcessingFiles
    }

    var body: some View {
        EditorSection(
            "Foundation Models features",
            systemImage: "wand.and.stars",
            description: "Evaluate custom tools, profiles, structured output, prewarming, and streaming as part of this suite."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Feature settings are saved with the suite. Custom tool arguments and outputs are saved locally in each run trace. Reference-file privacy settings are unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Feature", selection: $selectedPage) {
                    ForEach(FeatureEditorPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("Feature editor page")

                FeaturePageContent(
                    selectedPage: selectedPage,
                    configuration: $store.draftSuite.features,
                    maximumToolCalls: $store.draftSuite.modelConfiguration.maximumToolCalls
                )

                if let issue = store.draftSuite.features.validationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("Feature validation issue")
                }
            }
            .disabled(isDisabled)
        }
    }
}

private struct FeaturePageContent: View {
    let selectedPage: FeatureEditorPage
    @Binding var configuration: EvaluationFeatureConfiguration
    @Binding var maximumToolCalls: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch selectedPage {
            case .tools:
                VStack(alignment: .leading, spacing: 16) {
                    SpotlightSearchToolEditor(configuration: $configuration.spotlightSearch)
                    Divider()
                    CustomToolsEditor(
                        tools: $configuration.tools,
                        maximumToolCalls: $maximumToolCalls
                    )
                }
            case .profile:
                ProfileEditor(profile: $configuration.profile)
            case .output:
                StructuredOutputEditor(
                    fields: $configuration.outputFields,
                    definitions: $configuration.outputSchemaDefinitions,
                    representNilExplicitlyInGeneratedContent:
                        $configuration.outputRepresentNilExplicitlyInGeneratedContent
                )
            case .performance:
                PerformanceEditor(
                    prewarm: $configuration.prewarm,
                    streamResponse: $configuration.streamResponse
                )
            }
        }
    }
}

private struct CustomToolsEditor: View {
    @Binding var tools: [EvaluationCustomToolDefinition]
    @Binding var maximumToolCalls: Int
    @State private var selectedToolID: UUID?

    private var selectedToolIndex: Int? {
        guard let selectedToolID else { return nil }
        return tools.firstIndex { $0.id == selectedToolID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Tool call limit per sample") {
                Picker("Tool call limit per sample", selection: $maximumToolCalls) {
                    ForEach(1...4, id: \.self) { limit in
                        Text(limit.formatted()).tag(limit)
                    }
                }
                .accessibilitySelectionActions(
                    Array(1...4),
                    selection: $maximumToolCalls,
                    title: { $0.formatted() }
                )
                .labelsHidden()
                .frame(width: 90)
            }

            Text("Custom, reference, image, and Spotlight tools share this total across all turns in each sample.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 12) {
                Text("\(tools.count) of \(EvaluationFeatureConfiguration.maximumTools) tools")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !tools.isEmpty {
                    Picker("Editing tool", selection: $selectedToolID) {
                        ForEach(tools) { tool in
                            Text(tool.name.isEmpty ? "Untitled tool" : tool.name)
                                .tag(Optional(tool.id))
                        }
                    }
                    .accessibilitySelectionActions(
                        tools.map { Optional($0.id) },
                        selection: $selectedToolID,
                        title: { toolID in
                            guard let toolID,
                                  let tool = tools.first(where: { $0.id == toolID }) else {
                                return "Untitled tool"
                            }
                            return tool.name.isEmpty ? "Untitled tool" : tool.name
                        }
                    )
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("Tool selector")
                }

                Spacer()

                Button("Add Sample", systemImage: "shippingbox") {
                    addSampleTool()
                }
                .disabled(tools.count >= EvaluationFeatureConfiguration.maximumTools)
                .help("Add a fixture-backed lookupOrder tool")

                Button("Add Tool", systemImage: "plus") {
                    addTool()
                }
                .disabled(tools.count >= EvaluationFeatureConfiguration.maximumTools)
            }

            if let selectedToolIndex {
                CustomToolEditor(
                    tool: $tools[selectedToolIndex],
                    remove: { removeTool(at: selectedToolIndex) }
                )
            } else {
                EmptyFeatureMessage(
                    systemImage: "wrench.and.screwdriver",
                    title: "No custom tools",
                    detail: "Add a blank tool or the lookupOrder fixture to exercise tool calling in a run."
                )
            }
        }
        .onAppear { selectToolIfNeeded() }
        .onChange(of: tools.map(\.id)) { _, _ in
            selectToolIfNeeded()
        }
    }

    private func addTool() {
        guard tools.count < EvaluationFeatureConfiguration.maximumTools else { return }
        let tool = EvaluationCustomToolDefinition()
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func addSampleTool() {
        guard tools.count < EvaluationFeatureConfiguration.maximumTools else { return }
        let tool = EvaluationCustomToolDefinition(
            name: "lookupOrder",
            description: "Look up the current delivery status for an order.",
            parameters: [
                EvaluationSchemaField(
                    name: "orderID",
                    description: "The order identifier to look up.",
                    type: .string
                )
            ],
            mode: .fixture,
            fixtureResponse: #"{"status":"shipped"}"#
        )
        tools.append(tool)
        selectedToolID = tool.id
    }

    private func removeTool(at index: Int) {
        tools.remove(at: index)
        selectedToolID = tools.indices.contains(index) ? tools[index].id : tools.last?.id
    }

    private func selectToolIfNeeded() {
        if selectedToolID.flatMap({ id in tools.firstIndex { $0.id == id } }) == nil {
            selectedToolID = tools.first?.id
        }
    }
}

private struct CustomToolEditor: View {
    @Binding var tool: EvaluationCustomToolDefinition
    let remove: () -> Void
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Tool name", text: $tool.name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Tool name")

                Spacer()

                Button("Delete Tool", systemImage: "trash", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .labelStyle(.iconOnly)
                .help("Delete this tool")
            }

            LabeledField("Description") {
                TextField("What the tool lets the model do", text: $tool.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Picker("Implementation", selection: $tool.mode) {
                ForEach(EvaluationCustomToolMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Tool implementation")

            if tool.mode == .fixture {
                LabeledField("Fixture response") {
                    TextEditor(text: $tool.fixtureResponse)
                        .font(.body.monospaced())
                        .frame(minHeight: 88)
                        .padding(7)
                        .background(.background, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2))
                        }
                        .accessibilityLabel("Fixture response")
                }

                Text("The fixture returns this saved response for every call. It does not run custom code from your app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledField("Local HTTP endpoint") {
                    TextField("http://127.0.0.1:8080/tool", text: $tool.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Local HTTP tool endpoint")
                }

                Text("Local HTTP connects to the actual tool implementation at a 127.0.0.1 endpoint. Start that service before the run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            EvaluationSchemaEditor(
                title: "Arguments",
                emptyDetail: "No arguments. The model calls this tool without a generated input object.",
                maximumFields: EvaluationCustomToolDefinition.maximumParameters,
                fields: $tool.parameters,
                definitions: $tool.schemaDefinitions,
                representNilExplicitlyInGeneratedContent:
                    $tool.representNilExplicitlyInGeneratedContent
            )
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 11))
        .confirmationDialog(
            "Delete \(tool.name.isEmpty ? "this tool" : tool.name)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete Tool", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its definition and saved fixture or endpoint from the suite.")
        }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: EvaluationProfileConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Use an evaluation profile", isOn: $profile.enabled)

            if profile.enabled {
                LabeledField("Profile name") {
                    TextField("Tool workflow", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Require the model to call a tool first", isOn: $profile.requireToolFirst)

                LabeledField("Instructions after tool completion") {
                    TextEditor(text: $profile.afterToolInstructions)
                        .font(.body)
                        .frame(minHeight: 104)
                        .padding(7)
                        .background(.background, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2))
                        }
                        .accessibilityLabel("Instructions after tool completion")
                }

                Text("After a tool completes, the runtime applies these instructions to the model's next transition. Leave them empty to use the default profile transition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ProfileGenerationOverrides(profile: $profile)
            } else {
                Text("The run uses the suite instructions without profile transitions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProfileGenerationOverrides: View {
    @Binding var profile: EvaluationProfileConfiguration

    private let responseLimits: [Int?] = [nil, 256, 512, 1_024, 2_048, 4_096]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("After-tool generation")
                .font(.headline)

            Text("Override generation only after the first tool output. Automatic and Inherit keep the run's existing settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                LabeledContent("Sampling") {
                    Picker("After-tool sampling", selection: $profile.afterToolSamplingMode) {
                        ForEach(EvaluationSamplingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilitySelectionActions(
                        EvaluationSamplingMode.allCases,
                        selection: $profile.afterToolSamplingMode,
                        title: \.title
                    )
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityIdentifier("After-tool sampling")
                }

                LabeledContent("Response limit") {
                    Picker("After-tool response limit", selection: $profile.afterToolMaximumResponseTokens) {
                        ForEach(responseLimits, id: \.self) { limit in
                            if let limit {
                                Text("\(limit.formatted()) tokens").tag(Optional(limit))
                            } else {
                                Text("Inherit").tag(Optional<Int>.none)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityIdentifier("After-tool response limit")
                }
            }

            if profile.afterToolSamplingMode == .topK {
                Stepper(
                    "Top K: \(profile.afterToolTopK)",
                    value: $profile.afterToolTopK,
                    in: 1...1_000
                )
                .accessibilityIdentifier("After-tool top K")
            } else if profile.afterToolSamplingMode == .probability {
                HStack(alignment: .firstTextBaseline) {
                    Text("Probability threshold")
                    Spacer()
                    Slider(
                        value: $profile.afterToolProbabilityThreshold,
                        in: 0.01...1,
                        step: 0.01
                    )
                    .frame(width: 180)
                    .accessibilityLabel("After-tool probability threshold")
                    Text(profile.afterToolProbabilityThreshold.formatted(
                        .number.precision(.fractionLength(2))
                    ))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                }
            }

            if profile.afterToolSamplingMode == .topK
                || profile.afterToolSamplingMode == .probability {
                Toggle("Use a repeatable random seed", isOn: $profile.afterToolSeedEnabled)
                    .accessibilityIdentifier("After-tool seed enabled")
                if profile.afterToolSeedEnabled {
                    LabeledContent("Seed") {
                        TextField("Seed", value: $profile.afterToolSeed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .accessibilityIdentifier("After-tool seed")
                    }
                }
            }

            Toggle("Override temperature", isOn: $profile.afterToolTemperatureEnabled)
                .accessibilityIdentifier("After-tool temperature enabled")
            if profile.afterToolTemperatureEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("Temperature")
                    Spacer()
                    Slider(value: $profile.afterToolTemperature, in: 0...1, step: 0.05)
                        .frame(width: 180)
                        .accessibilityLabel("After-tool temperature")
                    Text(profile.afterToolTemperature.formatted(
                        .number.precision(.fractionLength(2))
                    ))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                }
            }

            Picker("Reasoning", selection: $profile.afterToolReasoningLevel) {
                ForEach(EvaluationReasoningLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .accessibilitySelectionActions(
                EvaluationReasoningLevel.allCases,
                selection: $profile.afterToolReasoningLevel,
                title: \.title
            )
            .accessibilityIdentifier("After-tool reasoning")

            if profile.afterToolReasoningLevel == .custom {
                TextField(
                    "Custom reasoning value",
                    text: $profile.afterToolCustomReasoning
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("After-tool custom reasoning")
            }

            Picker("On generation error", selection: $profile.afterToolTranscriptErrorPolicy) {
                ForEach(EvaluationTranscriptErrorPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .accessibilitySelectionActions(
                EvaluationTranscriptErrorPolicy.allCases,
                selection: $profile.afterToolTranscriptErrorPolicy,
                title: \.title
            )
            .accessibilityIdentifier("After-tool error policy")

            Text("Explicit reasoning requires model support. Preserve keeps a failed after-tool request in the transcript; Revert restores the transcript to before that request.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StructuredOutputEditor: View {
    @Binding var fields: [EvaluationSchemaField]
    @Binding var definitions: [EvaluationSchemaField]
    @Binding var representNilExplicitlyInGeneratedContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("With no fields, the model produces ordinary text. Add fields to require a structured generated response whose schema is saved in the trace.")
                .font(.callout)
                .foregroundStyle(.secondary)

            EvaluationSchemaEditor(
                title: "Response fields",
                emptyDetail: "No response schema. Runs return text.",
                maximumFields: EvaluationFeatureConfiguration.maximumOutputFields,
                fields: $fields,
                definitions: $definitions,
                representNilExplicitlyInGeneratedContent: $representNilExplicitlyInGeneratedContent
            )
        }
    }
}

private struct PerformanceEditor: View {
    @Binding var prewarm: Bool
    @Binding var streamResponse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Prewarm the model before each sample", isOn: $prewarm)
            Text("Prewarming prepares the model before timed generation so cold-start work is kept separate from the response measurement.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Stream the response", isOn: $streamResponse)
            Text("Streaming measures time to first visible content. Background suite runs that stream repeatedly may be rate limited by the model service.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder let content: Content

    init(_ label: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct EmptyFeatureMessage: View {
    let systemImage: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
