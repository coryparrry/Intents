import SwiftUI

struct ConversationTraceSection: View {
    let trace: EvaluationConversationTrace

    var body: some View {
        DisclosureGroup("Conversation trace") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ConversationTraceMetric(
                        label: "Restored history",
                        value: "\(trace.restoredEntryCount) entr\(trace.restoredEntryCount == 1 ? "y" : "ies")"
                    )
                    ConversationTraceMetric(label: "History policy", value: historyPolicyTitle)
                    ConversationTraceMetric(
                        label: "Model-facing history",
                        value: modelHistoryProjectionTitle
                    )
                    ConversationTraceMetric(
                        label: "History before scored prompt",
                        value: "\(trace.historyEntryCountBeforeFinal) → \(trace.historyEntryCountAfterPolicy) entries"
                    )
                    if let modelFacingCount = trace.modelFacingHistoryEntryCountBeforeFinal {
                        ConversationTraceMetric(
                            label: "Entries exposed to model",
                            value: "\(modelFacingCount)"
                        )
                    }
                    if let retainedTurnCount = trace.retainedTurnCount {
                        ConversationTraceMetric(
                            label: "Configured retention",
                            value: "\(retainedTurnCount) complete turn\(retainedTurnCount == 1 ? "" : "s")"
                        )
                    }
                }

                ForEach(trace.turns.indices, id: \.self) { index in
                    ConversationTurnTraceRow(
                        turn: trace.turns[index],
                        setupNumber: trace.turns[..<index].count(where: { $0.kind == .setup }) + 1
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    private var historyPolicyTitle: String {
        switch trace.historyPolicy {
        case .keepAll: "Keep all history"
        case .resetBeforeFinal: "Reset before scored prompt"
        case .retainRecentCompleteTurns: "Retain recent complete turns"
        }
    }

    private var modelHistoryProjectionTitle: String {
        guard let projection = trace.modelHistoryProjection else {
            return "Framework default"
        }
        switch projection.policy {
        case .keepAll:
            return "Keep all stored history"
        case .reset:
            return "Hide prior stored history"
        case .retainRecentCompleteTurns:
            return "Use \(projection.retainedTurnCount) recent complete turn\(projection.retainedTurnCount == 1 ? "" : "s")"
        }
    }
}

private struct ConversationTurnTraceRow: View {
    let turn: EvaluationConversationTurnTrace
    let setupNumber: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ConversationTraceText(label: "Prompt", value: turn.prompt)
                if let effectivePrompt = turn.effectivePrompt,
                   effectivePrompt != turn.prompt {
                    ConversationTraceText(label: "Effective input", value: effectivePrompt)
                }
                if let response = turn.response {
                    ConversationTraceText(label: "Response", value: response)
                } else {
                    Text("No response was recorded.")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = turn.errorMessage {
                    ConversationTraceText(
                        label: turn.errorCategory.map { "Error · \($0)" } ?? "Error",
                        value: errorMessage
                    )
                }
                if let refusal = turn.refusal {
                    RefusalExplanationView(trace: refusal)
                }
                if let usage = turn.usage {
                    ConversationTraceMetric(
                        label: "Usage",
                        value: "\(usage.inputTokens) input · \(usage.outputTokens) output · \(usage.reasoningTokens) reasoning"
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: turn.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                Spacer(minLength: 12)
                Text(turn.durationMilliseconds, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                Text("ms")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
    }

    private var title: String {
        switch turn.kind {
        case .setup: "Setup turn \(setupNumber)"
        case .evaluation: "Scored prompt"
        }
    }
}

private struct ConversationTraceText: View {
    let label: String
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

private struct ConversationTraceMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
