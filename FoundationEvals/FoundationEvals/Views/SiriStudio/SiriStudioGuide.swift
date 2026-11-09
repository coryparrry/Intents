import MacIntentTesting
import SwiftUI

/// Derives guided progress from the actual app, prerequisites and selected conversation.
enum SiriStudioGuideStep: Int, CaseIterable, Identifiable {
    case app, mac, conversation, run
    var id: Int { rawValue }
    var title: String { ["Choose app", "Prepare Mac", "Write conversation", "Run and review"][rawValue] }
    var detail: String {
        switch self {
        case .app: "Choose a development build of the native Mac app you want to test. The requirements below show where to find it."
        case .mac: "Choose Check my Mac to review any missing setup steps. Complete Mac setup before running; you can write your conversation while you finish."
        case .conversation: "Write what you would say to Siri, then choose the action you expect below the message. Create an example if you're unsure, and edit its request with the details your action needs."
        case .run: "Run this conversation, then read Siri's replies and called actions in Results. A failed check shows what differed from your expectations."
        }
    }
    var buttonTitle: String {
        switch self {
        case .app: "Choose app…"
        case .mac: "Check my Mac"
        case .conversation: "Open conversation editor"
        case .run: "Run this conversation"
        }
    }

    /// Requires real prerequisite readiness before marking setup complete; unrelated unfinished drafts do not block progress.
    static func current(catalog: MacIntentCatalog?, macReady: Bool, conversationReady: Bool) -> Self {
        if catalog?.actions.isEmpty != false { return .app }
        if !macReady { return .mac }
        return conversationReady ? .run : .conversation
    }

    /// Creates an editable example backed by an action in the selected app, without modifying existing drafts.
    static func example(for catalog: MacIntentCatalog) -> SiriStudioScenario? {
        guard let action = catalog.actions.first else { return nil }
        let app = catalog.appURL.deletingPathExtension().lastPathComponent
        return .init(name: "Try \(action.title)", turns: [.init(utterance: "In \(app), \(action.title).",
            expectations: .init(calls: [.init(actionIdentifier: action.id)]))])
    }
}

/// Makes the next setup action visible while retaining access to authoring and direct action testing.
struct SiriStudioGuide: View {
    let step: SiriStudioGuideStep
    let busy: Bool
    let canCreateExample: Bool
    let advance: () -> Void
    let createExample: () -> Void
    let directAction: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Guided setup · Step \(step.rawValue + 1) of 4").font(.headline)
                    .accessibilityIdentifier("siri-guide-progress")
                Spacer()
                Button("Hide guide", action: dismiss).buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                ForEach(SiriStudioGuideStep.allCases) { item in
                    Label(item.title, systemImage: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle")
                        .font(.caption).foregroundStyle(item == step ? Color.primary : Color.secondary)
                    if item != .run { Spacer(minLength: 0) }
                }
            }
            Text(step.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(step.buttonTitle, action: advance).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(step == .app ? "mac-intent-choose-app" : "siri-guide-continue")
                if canCreateExample && (step == .mac || step == .conversation) {
                    Button("Create an example conversation", action: createExample)
                        .accessibilityIdentifier("siri-guide-example")
                }
                Spacer()
                Button("Test an action without Siri", action: directAction)
                    .help("Call an App Intent with explicit inputs without using Siri.")
            }
            .disabled(busy)
        }
        .padding(16).workspaceSurface()
    }
}
