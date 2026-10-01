import SwiftUI

struct FeatureConfigurationSummary: View {
    let configuration: EvaluationFeatureConfiguration

    var body: some View {
        DisclosureGroup("Foundation Models configuration") {
            VStack(alignment: .leading, spacing: 12) {
                FeatureConfigurationFlags(
                    profile: configuration.profile,
                    prewarm: configuration.prewarm,
                    streamResponse: configuration.streamResponse
                )

                Divider()

                FeatureOutputConfiguration(
                    fields: configuration.outputFields,
                    definitions: configuration.outputSchemaDefinitions,
                    representNilExplicitlyInGeneratedContent:
                        configuration.outputRepresentNilExplicitlyInGeneratedContent
                )

                Divider()

                FeatureToolConfiguration(tools: configuration.tools)
            }
            .padding(.top, 10)
        }
        .font(.callout)
    }
}

private struct FeatureConfigurationFlags: View {
    let profile: EvaluationProfileConfiguration
    let prewarm: Bool
    let streamResponse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FeatureConfigurationRow("Profile") {
                if profile.enabled {
                    Text(profile.name)
                } else {
                    Text("Disabled")
                }
            }

            if profile.enabled {
                FeatureConfigurationRow("First transition") {
                    if profile.requireToolFirst {
                        Text("Tool required")
                    } else {
                        Text("Model chooses")
                    }
                }
                FeatureConfigurationRow("After-tool instructions") {
                    if profile.afterToolInstructions.isEmpty {
                        Text("Default transition")
                    } else {
                        Text("Configured")
                    }
                }
            }

            FeatureConfigurationRow("Prewarm") {
                if prewarm {
                    Text("Enabled")
                } else {
                    Text("Disabled")
                }
            }
            FeatureConfigurationRow("Streaming") {
                if streamResponse {
                    Text("Enabled")
                } else {
                    Text("Disabled")
                }
            }
        }
    }
}

private struct FeatureOutputConfiguration: View {
    let fields: [EvaluationSchemaField]
    let definitions: [EvaluationSchemaField]
    let representNilExplicitlyInGeneratedContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Response format")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if fields.isEmpty {
                Text("Text")
            } else {
                FeatureSchemaSummary(fields: fields, definitions: definitions)
                if representNilExplicitlyInGeneratedContent {
                    Text("Missing optional properties use explicit nulls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FeatureSchemaSummary: View {
    let fields: [EvaluationSchemaField]
    let definitions: [EvaluationSchemaField]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(fields) { field in
                FeatureSchemaFieldSummary(field: field, depth: 0)
            }
            if !definitions.isEmpty {
                Text("\(definitions.count) reusable definitions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                ForEach(definitions) { definition in
                    FeatureSchemaFieldSummary(field: definition, depth: 0)
                }
            }
        }
    }
}

private struct FeatureSchemaFieldSummary: View {
    let field: EvaluationSchemaField
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.name)
                    .fontWeight(.medium)
                Text(field.type.title)
                    .foregroundStyle(.secondary)
                if field.isOptional {
                    Text("Optional")
                        .foregroundStyle(.secondary)
                }
                if let detail = fieldDetail {
                    Text(detail)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)

            if !field.children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(field.children) { child in
                        FeatureSchemaFieldSummary(field: child, depth: depth + 1)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.leading, depth == 0 ? 0 : 4)
    }

    private var fieldDetail: String? {
        switch field.type {
        case .string:
            field.constraints.stringPattern.isEmpty ? nil : "Pattern constrained"
        case .integer:
            boundsDescription(
                minimum: field.constraints.integerMinimum.map { String($0) },
                maximum: field.constraints.integerMaximum.map { String($0) }
            )
        case .number:
            boundsDescription(
                minimum: field.constraints.numberMinimum?.formatted(),
                maximum: field.constraints.numberMaximum?.formatted()
            )
        case .enumeration:
            "\(field.enumValues.count) values"
        case .array:
            boundsDescription(
                minimum: field.constraints.arrayMinimumCount.map { String($0) },
                maximum: field.constraints.arrayMaximumCount.map { String($0) },
                label: "items"
            )
        case .union:
            "\(field.children.count) choices"
        case .reference:
            "References \(field.referenceName)"
        case .object:
            field.representNilExplicitlyInGeneratedContent ? "Explicit nulls" : nil
        case .boolean, .null, .imageReference:
            nil
        }
    }

    private func boundsDescription(
        minimum: String?,
        maximum: String?,
        label: String = "range"
    ) -> String? {
        switch (minimum, maximum) {
        case (.some(let minimum), .some(let maximum)): "\(label) \(minimum)...\(maximum)"
        case (.some(let minimum), .none): "\(label) ≥ \(minimum)"
        case (.none, .some(let maximum)): "\(label) ≤ \(maximum)"
        case (.none, .none): nil
        }
    }
}

private struct FeatureToolConfiguration: View {
    let tools: [EvaluationCustomToolDefinition]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom tools")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if tools.isEmpty {
                Text("None")
            } else {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tool.name)
                                .fontWeight(.medium)
                            Text(modeTitle(for: tool.mode))
                                .foregroundStyle(.secondary)
                        }

                        if tool.mode == .localHTTP {
                            Text(tool.endpoint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if tool.representNilExplicitlyInGeneratedContent {
                            Text("Missing optional argument properties use explicit nulls")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !tool.parameters.isEmpty || !tool.schemaDefinitions.isEmpty {
                            FeatureSchemaSummary(
                                fields: tool.parameters,
                                definitions: tool.schemaDefinitions
                            )
                            .padding(.top, 5)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    private func modeTitle(for mode: EvaluationCustomToolMode) -> LocalizedStringResource {
        switch mode {
        case .fixture: "Fixture"
        case .localHTTP: "Local HTTP"
        }
    }
}

private struct FeatureConfigurationRow<Value: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder let value: Value

    init(
        _ label: LocalizedStringResource,
        @ViewBuilder value: () -> Value
    ) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
