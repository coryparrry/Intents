import SwiftUI

struct JudgeConnectionsSettingsView: View {
    @Bindable var store: EvaluationStore
    @State private var selectedID: UUID?
    @State private var draft = Self.newConnection()
    @State private var apiKey = ""
    @State private var message: String?
    @State private var isChecking = false
    @State private var isDeleting = false

    private var saved: EvaluationJudgeConnection? { store.judgeConnections.first { $0.id == draft.id } }
    private var hasChanges: Bool { saved != draft || !apiKey.isEmpty }
    private var effectiveRequest: EvaluationJudgeRequestConfiguration {
        EvaluationCompatibleJudgeClient.requestConfiguration(for: draft, criteriaCount: 1)
    }

    var body: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach(store.judgeConnections) { connection in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name)
                        Text(connection.modelID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(connection.id)
                }
                if saved == nil { Label("New connection", systemImage: "plus.circle").tag(draft.id) }
            }
            .frame(minWidth: 190, idealWidth: 210)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Add connection", systemImage: "plus") { startNew() }.labelStyle(.iconOnly)
                    Button("Delete connection", systemImage: "minus") { isDeleting = true }
                        .labelStyle(.iconOnly).disabled(saved == nil)
                    Spacer()
                }.buttonStyle(.borderless).padding(12)
            }
            .onChange(of: selectedID) { _, value in
                if let connection = store.judgeConnections.first(where: { $0.id == value }) {
                    draft = connection
                    apiKey = ""
                    message = nil
                }
            }
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("Name", text: $draft.name)
                            .accessibilityLabel("Connection name")
                            .accessibilityIdentifier("Judge connection name")
                        Picker("Service", selection: Binding(get: { draft.kind }, set: { kind in
                            let old = draft.kind
                            draft.kind = kind
                            applyPreset(from: old, to: kind)
                        })) {
                            ForEach(EvaluationJudgeConnectionKind.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("Base URL", text: $draft.baseURL, prompt: Text("https://your-endpoint.example/v1"))
                            .accessibilityLabel("Base URL")
                        TextField("Model ID", text: $draft.modelID)
                            .accessibilityLabel("Model ID")
                        SecureField(draft.requiresAPIKey ? "API key" : "API key (optional)", text: $apiKey)
                            .accessibilityLabel(draft.requiresAPIKey ? "API key" : "API key (optional)")
                        Text(saved == nil ? "Keys are saved in the macOS Keychain." : "Leave the key blank to keep the saved key. Keys are stored in the macOS Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("Judge connection") } footer: {
                        Text("Use the exact model ID provided by your service. Select this connection in a suite’s Setup → Scoring page.")
                    }
                    Section("Capabilities") {
                        Toggle("Strict structured outputs", isOn: $draft.capabilities.structuredOutputs)
                            .help("The judge must return scores in the required JSON format. Enable this option only for services that support strict structured outputs.")
                        Toggle("Accepts image evidence", isOn: $draft.capabilities.multimodal)
                            .help("Enable this option only for judges that can read images. Image evidence also needs approval in the suite’s Scoring setup.")
                        if draft.kind == .openRouter {
                            TextField("Provider order", text: Binding(
                                get: { draft.providerOrder.joined(separator: ", ") },
                                set: { draft.providerOrder = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
                            ), prompt: Text("Provider slugs, separated by commas"))
                            .accessibilityLabel("Provider order")
                            Text("Use the provider slugs from OpenRouter. The order is fixed for repeatable judging.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Picker("Generation policy", selection: $draft.generationPolicy) {
                            ForEach(EvaluationJudgeGenerationPolicy.allCases) { Text($0.title).tag($0) }
                        }
                        .help("Portable JSON returns one complete result. Streaming JSON reads the result as it arrives. DeepSeek thinking uses streaming with larger limits.")
                        Stepper("Configured timeout: \(draft.requestTimeoutSeconds.formatted(.number.precision(.fractionLength(0)))) seconds",
                            value: $draft.requestTimeoutSeconds, in: 1...900, step: 1)
                        LabeledContent("Effective output limit", value: "\(effectiveRequest.maximumResponseTokens.formatted()) tokens")
                        LabeledContent("Effective timeout", value: "\(effectiveRequest.timeoutSeconds.formatted(.number.precision(.fractionLength(0)))) seconds")
                    } header: { Text("Request policy") } footer: {
                        Text("Choose the policy your service supports. Changing the model or URL keeps this policy. The limits above apply to each attempt and are saved in its trace.")
                    }
                    if let issue = draft.validationIssue { Text(issue).font(.callout).foregroundStyle(.orange) }
                    if let message {
                        Text(message).font(.callout).textSelection(.enabled)
                    } else if let checked = saved, checked == draft, apiKey.isEmpty, let date = checked.lastCheckedAt {
                        Label("Checked \(date.formatted(date: .abbreviated, time: .shortened)): \(checked.lastCheckMessage ?? "Complete")", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if hasChanges, saved != nil {
                        Text("Save your changes before checking this connection.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                Divider()
                HStack {
                    if isChecking { ProgressView().controlSize(.small); Text("Checking…").font(.callout) }
                    Spacer()
                    Button("Check connection") { check() }.disabled(saved == nil || hasChanges)
                        .help("Sends a small test request using the saved connection. No evaluation evidence is sent.")
                    Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(draft.validationIssue != nil || !hasChanges)
                }.padding(16)
            }.frame(minWidth: 460)
        }
        .frame(width: 760, height: 580)
        .disabled(isChecking || store.isRunning || store.isReassessing)
        .onAppear {
            if selectedID == nil {
                if let first = store.judgeConnections.first { draft = first; selectedID = first.id }
                else { selectedID = draft.id }
            }
        }
        .alert("Delete this connection?", isPresented: $isDeleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do { try store.deleteJudgeConnection(id: draft.id); startNew() }
                catch { message = error.localizedDescription }
            }
        } message: { Text("The connection and its saved API key will be removed from this Mac.") }
    }

    private func startNew() {
        draft = Self.newConnection()
        apiKey = ""
        message = nil
        selectedID = draft.id
    }
    private static func newConnection() -> EvaluationJudgeConnection {
        .init(id: UUID(), name: "Local judge", kind: .localCompatible,
              baseURL: "http://127.0.0.1:11434/v1", modelID: "", generationPolicy: .portable)
    }
    private func applyPreset(from old: EvaluationJudgeConnectionKind, to new: EvaluationJudgeConnectionKind) {
        switch new {
        case .openRouter:
            draft.baseURL = "https://openrouter.ai/api/v1"
            if draft.name == "Local judge" || draft.name == "Custom judge" { draft.name = "OpenRouter judge" }
        case .localCompatible:
            draft.baseURL = "http://127.0.0.1:11434/v1"
            if draft.name == "OpenRouter judge" || draft.name == "Custom judge" { draft.name = "Local judge" }
        case .customCompatible:
            if old != .customCompatible { draft.baseURL = "" }
            if draft.name == "Local judge" || draft.name == "OpenRouter judge" { draft.name = "Custom judge" }
        }
        message = nil
    }
    private func save() {
        do {
            try store.saveJudgeConnection(draft, apiKey: apiKey.isEmpty ? nil : apiKey)
            draft = store.judgeConnections.first { $0.id == draft.id } ?? draft
            selectedID = draft.id
            apiKey = ""
            message = "Connection saved. Check it before using it for a run."
        } catch { message = error.localizedDescription }
    }
    private func check() {
        isChecking = true
        message = nil
        Task { @MainActor in
            await store.checkJudgeConnection(id: draft.id)
            draft = store.judgeConnections.first { $0.id == draft.id } ?? draft
            message = store.notice
            store.notice = nil
            isChecking = false
        }
    }
}
