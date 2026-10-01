import SwiftUI

struct FeatureTraceSection: View {
    let trace: EvaluationFeatureTrace

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let firstContentMilliseconds = trace.firstContentMilliseconds {
                    FeatureTraceMetricRow(
                        label: "First visible content",
                        value: "\(firstContentMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms"
                    )
                }

                if let conversation = trace.conversation {
                    ConversationTraceSection(trace: conversation)
                }

                if !trace.profileEvents.isEmpty {
                    FeatureProfileEvents(events: trace.profileEvents)
                }

                if !trace.customToolCalls.isEmpty {
                    FeatureToolCalls(calls: trace.customToolCalls)
                }
                if let calls = trace.builtinToolCalls, !calls.isEmpty {
                    BuiltinToolCallsSection(calls: calls)
                }
                if let spotlightSearch = trace.spotlightSearch {
                    SpotlightSearchTraceView(trace: spotlightSearch)
                }

                if trace.firstContentMilliseconds == nil,
                   trace.profileEvents.isEmpty,
                   trace.customToolCalls.isEmpty,
                   trace.builtinToolCalls?.isEmpty != false,
                   trace.spotlightSearch == nil,
                   trace.conversation == nil {
                    Text("No profile transition, streamed content, or custom tool call was recorded for this sample.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !trace.customToolCalls.isEmpty {
                    Text("Custom tool arguments and outputs are stored locally in this saved run trace.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Foundation Models feature trace")
        }
        .font(.callout)
    }
}

private struct BuiltinToolCallsSection: View {
    let calls: [EvaluationBuiltinToolTrace]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Image tool calls").font(.headline)
            ForEach(calls) { call in
                VStack(alignment: .leading, spacing: 6) {
                    Text(call.toolName).fontWeight(.semibold)
                    FeatureTraceValue(label: "Arguments", value: call.argumentsJSON)
                    FeatureTraceValue(label: "Output", value: call.output ?? "No output recorded")
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
            }
            Text("The framework transcript does not provide duration or outcome metadata for these built-in tools.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FeatureProfileEvents: View {
    let events: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Profile lifecycle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(events.map { "• \($0)" }.joined(separator: "\n"))
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
    }
}

private struct FeatureToolCalls: View {
    let calls: [EvaluationCustomToolCallTrace]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom tool calls")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(calls) { call in
                FeatureToolCallRow(call: call)
            }
        }
    }
}

private struct FeatureToolCallRow: View {
    let call: EvaluationCustomToolCallTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(outcomeTitle, systemImage: outcomeSymbol)
                    .foregroundStyle(outcomeColor)
                Text(call.toolName)
                    .fontWeight(.medium)
                Spacer(minLength: 12)
                Text(call.durationMilliseconds, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                Text("ms")
                    .foregroundStyle(.secondary)
            }

            FeatureTraceValue(label: "Arguments", value: call.argumentsJSON)

            if let output = call.output {
                FeatureTraceValue(label: "Output", value: output)
            }

            if let errorDescription = call.errorDescription {
                FeatureTraceValue(label: "Error", value: errorDescription)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var outcomeTitle: LocalizedStringResource {
        switch call.outcome {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .rejected: "Rejected"
        }
    }

    private var outcomeSymbol: String {
        switch call.outcome {
        case .running: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .rejected: "exclamationmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch call.outcome {
        case .running: .secondary
        case .succeeded: .green
        case .failed, .rejected: .red
        case .cancelled: .orange
        }
    }
}

private struct FeatureTraceValue: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FeatureTraceMetricRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
