import MacIntentTesting
import SwiftUI

/// Edits authored turns and scenario-wide behavior without mixing in live observations.
struct SiriStudioConversation: View {
    @Binding var scenario: SiriStudioScenario
    let actions: [MacIntentAction]
    @Binding var turnID: UUID?
    let showsAdvanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Conversation name", text: $scenario.name).font(.title3.weight(.semibold)).textFieldStyle(.plain)
                .accessibilityIdentifier("siri-studio-scenario-name")
            Text("Mention your app in the first message, then add follow-ups as needed.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($scenario.turns) { $turn in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Turn \(ordinal(turn.id))") { turnID = turn.id }
                            .buttonStyle(.borderless)
                            .accessibilityAddTraits(active(turn.id) ? .isSelected : [])
                        Spacer()
                        Button("Remove turn", systemImage: "minus.circle") { removeTurn(turn.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(scenario.turns.count <= 1)
                    }
                    TextEditor(text: $turn.utterance)
                        .workspaceTextWell(minHeight: 84)
                        .accessibilityLabel("What to say in turn \(ordinal(turn.id))")
                        .accessibilityIdentifier("siri-studio-utterance-\(ordinal(turn.id))")
                    if showsAdvanced && active(turn.id) {
                        SiriStudioExpectationEditor(group: $turn.expectations, actions: actions, allowsReply: true)
                    } else {
                        expectedActions($turn.expectations, for: turn.id)
                    }
                }
                .padding(.vertical, 6)
            }
            Button("Add turn", systemImage: "plus") {
                let turn = SiriStudioTurn()
                scenario.turns.append(turn); turnID = turn.id
            }.disabled(scenario.turns.count >= 12)
            if showsAdvanced {
                Divider()
                Stepper("Repeats: \(scenario.repeatCount)", value: $scenario.repeatCount, in: 1...10)
                DisclosureGroup("Scenario-wide expectations") {
                    SiriStudioExpectationEditor(group: $scenario.scenarioExpectations, actions: actions, allowsReply: false)
                        .padding(.top, 6)
                }
                DisclosureGroup("Before each repeat") { setup.padding(.top, 6) }
            }
        }
    }

    /// Selects expected actions by their user-facing names while preserving every saved argument and result constraint.
    private func expectedActions(_ group: Binding<SiriStudioExpectations>, for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.calls) { call in
                HStack {
                    Text("Siri should: " + (actions.first { $0.id == call.wrappedValue.actionIdentifier }?.title ?? call.wrappedValue.actionIdentifier))
                        .font(.callout)
                    Spacer()
                    Button("Remove expected action", systemImage: "xmark.circle") {
                        let removed = call.wrappedValue.id
                        group.wrappedValue.calls.removeAll { $0.id == removed }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Menu(group.wrappedValue.calls.isEmpty ? "Choose expected action" : "Add expected action") {
                ForEach(actions) { action in
                    Button(action.title) { group.wrappedValue.calls.append(.init(actionIdentifier: action.id)) }
                }
            }
            .accessibilityIdentifier("siri-studio-expected-action-\(ordinal(id))")
        }
    }

    /// Shows the selected setup action and its Direct Action JSON inputs.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Setup action", selection: Binding(
                get: { scenario.setup?.actionIdentifier ?? "" },
                set: { scenario.setup = $0.isEmpty ? nil : MacIntentTestCase(actionIdentifier: $0) }
            )) {
                Text("None").tag("")
                ForEach(actions) { Text($0.title).tag($0.id) }
            }
            if let action = actions.first(where: { $0.id == scenario.setup?.actionIdentifier }) {
                if !action.parameters.isEmpty {
                    Text(action.parameters.map { "\($0.id): \($0.type)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Setup inputs (JSON)", text: Binding(
                    get: { scenario.setup?.inputsJSON ?? "{}" },
                    set: { scenario.setup?.inputsJSON = $0 }
                ), axis: .vertical).font(.body.monospaced()).textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Looks up the displayed one-based turn number using the stable ID.
    private func ordinal(_ id: UUID) -> Int { (scenario.turns.firstIndex { $0.id == id } ?? 0) + 1 }

    /// Defaults the inspector to the first turn when no explicit selection exists.
    private func active(_ id: UUID) -> Bool { id == (turnID ?? scenario.turns.first?.id) }

    /// Removes one turn and resets selection if that turn was in the inspector.
    private func removeTurn(_ id: UUID) {
        scenario.turns.removeAll { $0.id == id }
        if turnID == id { turnID = nil }
    }
}
