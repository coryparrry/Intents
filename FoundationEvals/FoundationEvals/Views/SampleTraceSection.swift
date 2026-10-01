import SwiftUI

struct SampleTraceSection: View {
    let result: EvaluationSampleResult

    var body: some View {
        DisclosureGroup("Execution trace") {
            VStack(alignment: .leading, spacing: 12) {
                timingSection
                usageSection

                if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
                    Divider()
                    toolSection(toolCalls)
                }
            }
            .padding(.top, 10)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TraceMetricRow(
                label: "Subject request",
                value: Self.milliseconds(result.durationMilliseconds)
            )

            if let timing = result.timing {
                if let preparation = timing.preparationMilliseconds {
                    TraceMetricRow(label: "Prepare input", value: Self.milliseconds(preparation))
                }
                if let generation = timing.generationMilliseconds {
                    TraceMetricRow(label: "Generate response", value: Self.milliseconds(generation))
                }
                if let scoring = timing.scoringMilliseconds {
                    TraceMetricRow(label: "Score response", value: Self.milliseconds(scoring))
                }
            } else {
                Text("Phase timing was not recorded for this saved run.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let judgeDuration = result.judgeDurationMilliseconds {
                TraceMetricRow(label: "AI judge", value: Self.milliseconds(judgeDuration))
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token usage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if result.status == .error && result.usage.totalTokens == 0 {
                Text("Unavailable — the model did not return usage for this failed request.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                TraceMetricRow(label: "Input", value: result.usage.inputTokens.formatted())
                TraceMetricRow(label: "Cached input", value: result.usage.cachedInputTokens.formatted())
                TraceMetricRow(label: "Output", value: result.usage.outputTokens.formatted())
                TraceMetricRow(label: "Reasoning", value: result.usage.reasoningTokens.formatted())
            }

            if let judgeUsage = result.judgeUsage {
                TraceMetricRow(
                    label: "AI judge",
                    value: "\(judgeUsage.inputTokens) input · \(judgeUsage.outputTokens) output · \(judgeUsage.reasoningTokens) reasoning · \(judgeUsage.cachedInputTokens) cached"
                )
            }
        }
    }

    private func toolSection(_ toolCalls: [EvaluationToolCallTrace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference tool activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, call in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: call.outcome == "completed" ? "checkmark.circle" : "magnifyingglass.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call \(call.callIndex) · \(call.toolName) · \(call.outcome)")
                        Text(toolDetail(call))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }

            Text("Queries and returned reference passages are intentionally omitted from the saved trace.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
    }

    private func toolDetail(_ call: EvaluationToolCallTrace) -> String {
        let files = call.matchedFiles.isEmpty ? "no matched files" : call.matchedFiles.joined(separator: ", ")
        let duration = call.durationMilliseconds.map { " · \(Self.milliseconds($0))" } ?? ""
        return "\(files) · \(call.outputCharacterCount) output characters\(duration)"
    }

    private static func milliseconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) ms"
    }
}

private struct TraceMetricRow: View {
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
