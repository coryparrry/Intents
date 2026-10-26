import SwiftUI

struct ConversationConfigurationEditor: View {
    @Binding var configuration: EvaluationConversationConfiguration
    let isDisabled: Bool
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                SetupTurnsEditor(configuration: $configuration, isDisabled: isDisabled)
                RestoredTranscriptEditor(configuration: $configuration)
                HistoryPolicyEditor(configuration: $configuration)
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation setup")
                    .font(.callout.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isDisabled)
    }

    private var summary: String {
        let setupCount = configuration.setupTurns.count
        let restored = configuration.restoredTranscriptJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [
            setupCount == 0 ? nil : "\(setupCount) setup turn\(setupCount == 1 ? "" : "s")",
            restored?.isEmpty == false ? "restored transcript" : nil,
            configuration.modelHistoryProjection == nil ? nil : "model-facing projection",
            historyPolicyTitle(configuration.historyPolicy)
        ].compactMap { $0 }
        return parts.formatted()
    }
}

private struct SetupTurnsEditor: View {
    @Binding var configuration: EvaluationConversationConfiguration
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup turns")
                        .font(.caption.weight(.semibold))
                    Text("Each prompt generates a response in order in the same session before the scored prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Turn", systemImage: "plus") {
                    configuration.setupTurns.append(EvaluationSetupTurn())
                }
                .disabled(isDisabled || configuration.setupTurns.count >= EvaluationConversationConfiguration.maximumSetupTurns)
            }

            ForEach(configuration.setupTurns.enumerated(), id: \.element.id) { index, turn in
                SetupTurnRow(
                    number: index + 1,
                    prompt: binding(for: turn.id),
                    canMoveUp: index > 0,
                    canMoveDown: index + 1 < configuration.setupTurns.count,
                    moveUp: { move(turn.id, offset: -1) },
                    moveDown: { move(turn.id, offset: 1) },
                    remove: { configuration.setupTurns.removeAll { $0.id == turn.id } }
                )
            }

            Text("\(configuration.setupTurns.count) of \(EvaluationConversationConfiguration.maximumSetupTurns) setup turns")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Binds a setup-turn prompt by stable ID, returning empty text and ignoring writes if the turn has been removed.
    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { configuration.setupTurns.first(where: { $0.id == id })?.prompt ?? "" },
            set: { value in
                guard let index = configuration.setupTurns.firstIndex(where: { $0.id == id }) else { return }
                configuration.setupTurns[index].prompt = value
            }
        )
    }

    /// Swaps a setup turn with its offset neighbor only when both positions still exist.
    private func move(_ id: UUID, offset: Int) {
        guard let source = configuration.setupTurns.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard configuration.setupTurns.indices.contains(destination) else { return }
        configuration.setupTurns.swapAt(source, destination)
    }
}

private struct SetupTurnRow: View {
    let number: Int
    @Binding var prompt: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Turn \(number)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Move Up", systemImage: "chevron.up", action: moveUp)
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "chevron.down", action: moveDown)
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveDown)
                Button("Remove Turn", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
            }
            TextEditor(text: $prompt)
                .accessibilityLabel("Setup turn \(number) prompt")
                .font(.body)
                .frame(minHeight: 72)
                .padding(8)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }
        }
        .padding(10)
        .background(.quinary, in: .rect(cornerRadius: 9))
    }
}

private struct RestoredTranscriptEditor: View {
    @Binding var configuration: EvaluationConversationConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Restored transcript JSON")
                .font(.caption.weight(.semibold))
            Text("Optional. Paste a Foundation Models transcript export to seed the session history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: transcriptBinding)
                .accessibilityLabel("Restored transcript JSON")
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 104)
                .padding(8)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }
            Text("\(configuration.restoredTranscriptJSON?.count ?? 0) of \(EvaluationConversationConfiguration.maximumRestoredTranscriptCharacters) characters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptBinding: Binding<String> {
        Binding(
            get: { configuration.restoredTranscriptJSON ?? "" },
            set: { configuration.restoredTranscriptJSON = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct HistoryPolicyEditor: View {
    @Binding var configuration: EvaluationConversationConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Stored history before scored prompt", selection: $configuration.historyPolicy) {
                ForEach(EvaluationHistoryPolicy.allCases) { policy in
                    Text(historyPolicyTitle(policy)).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .accessibilitySelectionActions(
                EvaluationHistoryPolicy.allCases,
                selection: $configuration.historyPolicy,
                title: historyPolicyTitle
            )

            Text(historyPolicyDetail(configuration.historyPolicy))
                .font(.caption)
                .foregroundStyle(.secondary)

            if configuration.historyPolicy == .retainRecentCompleteTurns {
                Stepper(
                    "Retain \(configuration.retainedTurnCount) complete turn\(configuration.retainedTurnCount == 1 ? "" : "s")",
                    value: $configuration.retainedTurnCount,
                    in: 1...EvaluationConversationConfiguration.maximumRetainedTurns
                )
            }

            Divider()

            Toggle("Project history for the model", isOn: modelProjectionEnabled)
            Text("Apply Foundation Models' history transform on every request. This changes what the model sees without deleting entries from the stored transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if configuration.modelHistoryProjection != nil {
                Picker("Model-facing history", selection: modelProjectionPolicy) {
                    ForEach(EvaluationModelHistoryProjectionPolicy.allCases) { policy in
                        Text(modelProjectionTitle(policy)).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .accessibilitySelectionActions(
                    EvaluationModelHistoryProjectionPolicy.allCases,
                    selection: modelProjectionPolicy,
                    title: modelProjectionTitle
                )

                if configuration.modelHistoryProjection?.policy == .retainRecentCompleteTurns {
                    Stepper(
                        "Project \(configuration.modelHistoryProjection?.retainedTurnCount ?? 2) complete turn\((configuration.modelHistoryProjection?.retainedTurnCount ?? 2) == 1 ? "" : "s")",
                        value: modelProjectionRetainedTurnCount,
                        in: 1...EvaluationConversationConfiguration.maximumRetainedTurns
                    )
                }
            }
        }
    }

    private var modelProjectionEnabled: Binding<Bool> {
        Binding(
            get: { configuration.modelHistoryProjection != nil },
            set: { enabled in
                configuration.modelHistoryProjection = enabled ? EvaluationModelHistoryProjection() : nil
            }
        )
    }

    private var modelProjectionPolicy: Binding<EvaluationModelHistoryProjectionPolicy> {
        Binding(
            get: { configuration.modelHistoryProjection?.policy ?? .keepAll },
            set: { configuration.modelHistoryProjection?.policy = $0 }
        )
    }

    private var modelProjectionRetainedTurnCount: Binding<Int> {
        Binding(
            get: { configuration.modelHistoryProjection?.retainedTurnCount ?? 2 },
            set: { configuration.modelHistoryProjection?.retainedTurnCount = $0 }
        )
    }
}

/// Returns the editor title for a conversation history retention policy.
func historyPolicyTitle(_ policy: EvaluationHistoryPolicy) -> String {
    switch policy {
    case .keepAll: "Keep all history"
    case .resetBeforeFinal: "Reset before scored prompt"
    case .retainRecentCompleteTurns: "Retain recent complete turns"
    }
}

/// Explains which setup history the scored prompt receives under the chosen policy.
private func historyPolicyDetail(_ policy: EvaluationHistoryPolicy) -> String {
    switch policy {
    case .keepAll:
        "The scored prompt sees the restored transcript and every setup response."
    case .resetBeforeFinal:
        "The same session is kept, but its conversational history is cleared before the scored prompt."
    case .retainRecentCompleteTurns:
        "Only the latest complete prompt-to-response turns remain in the model's history."
    }
}

/// Returns the editor title for projecting stored conversation history into the model.
private func modelProjectionTitle(_ policy: EvaluationModelHistoryProjectionPolicy) -> String {
    switch policy {
    case .keepAll: "Keep all stored history"
    case .reset: "Hide prior stored history"
    case .retainRecentCompleteTurns: "Use recent complete turns"
    }
}
