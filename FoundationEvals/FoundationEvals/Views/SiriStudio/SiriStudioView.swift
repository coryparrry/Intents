import AppKit
import MacIntentTesting
import SwiftUI
import UniformTypeIdentifiers

/// The scenario list, conversation, and inspector for the selected app.
struct SiriStudioView: View {
    @Bindable var native: MacIntentTestingStore
    @Bindable var studio: SiriStudioStore
    let catalog: MacIntentCatalog
    @State private var turnID: UUID?
    @State private var customAllowance = false
    @State private var allowance = 900
    @State private var pendingDeletion: SiriStudioScenario?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SiriStudioSetupView(native: native, catalog: catalog)
            toolbar
            if let reason = studio.diagnostic ?? studio.validationError {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("siri-studio-diagnostic")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    scenarioList.frame(width: 180)
                    conversation.frame(minWidth: 265, maxWidth: .infinity, alignment: .topLeading)
                    inspector.frame(minWidth: 260, maxWidth: 390, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    scenarioList
                    conversation
                    inspector
                }
            }
            signing
        }
        .task { native.detectSiriSetup() }
        .onChange(of: studio.selection) { _, _ in turnID = nil }
        .confirmationDialog("Delete scenario?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { scenario in
            Button("Delete \(scenario.name)", role: .destructive) { remove(scenario.id) }
        }
    }

    /// Explains which runtime prerequisite needs attention while authoring stays available.
    private var prerequisite: String? {
        native.siriSetup.issue(configuration: native.setupConfiguration)
    }

    /// Disables competing commands while either mode owns a run.
    private var busy: Bool { native.isRunning || native.isLoading || studio.isBusy }

    /// Binds a scenario by stable ID so moving or deleting another row cannot redirect an edit.
    private func binding(for id: UUID) -> Binding<SiriStudioScenario>? {
        guard let initial = studio.document?.scenarios.first(where: { $0.id == id }) else { return nil }
        return Binding {
            studio.document?.scenarios.first(where: { $0.id == id }) ?? initial
        } set: { value in
            guard let index = studio.document?.scenarios.firstIndex(where: { $0.id == id }) else { return }
            studio.document?.scenarios[index] = value
        }
    }

    /// Provides run and file actions without requiring the generated project to be opened manually.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { runControls; Spacer(minLength: 0); fileControls }
            VStack(alignment: .leading, spacing: 8) { runControls; fileControls }
        }
    }

    /// Shows the current scenario and repeat while the generated suite runs.
    private var runControls: some View {
        HStack {
            Button("Run") { start(all: false) }
                .buttonStyle(.borderedProminent)
                .disabled(busy || prerequisite != nil || studio.validationError != nil || studio.selection == nil)
            Menu {
                Button("Run all scenarios") { start(all: true) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Run options")
            .fixedSize()
            .disabled(busy || prerequisite != nil || studio.validationError != nil)
            if studio.isBusy {
                ProgressView().controlSize(.small)
                Text(progressLabel).font(.caption)
                Button("Cancel") { studio.cancel() }
            }
        }
    }

    /// Exposes explicit save, export and import choices.
    private var fileControls: some View {
        HStack {
            Button("Save") { perform { try studio.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(studio.document == nil)
            Button("Export Swift…") { export(swift: true) }
                .disabled(studio.validationError != nil)
            Menu("Documents") {
                Button("Export all scenarios as Swift…") { export(swift: true, all: true) }
                    .disabled(studio.validationError != nil)
                Button("Open scenario document…") { open(.document) }
                Button("Export scenario document…") { export(swift: false) }.disabled(studio.document == nil)
                Divider()
                Button("Import result bundle…") { open(.result) }.disabled(studio.document == nil)
                Button("Open saved run…") { open(.run) }
                if studio.run != nil {
                    Divider()
                    Button("Export verdict summary…") { exportEvidence(transcripts: false) }
                    Button("Export run with transcripts…") { exportEvidence(transcripts: true) }
                }
            }
        }.disabled(busy)
    }

    /// Shows either build preparation or the latest repeat started by the owned UI test.
    private var progressLabel: String {
        guard let progress = studio.progress,
              let scenario = studio.document?.scenarios.first(where: { $0.id == progress.scenarioID }) else {
            return "Preparing run…"
        }
        return "\(scenario.name) · repeat \(progress.repeatIndex + 1) of \(scenario.repeatCount)"
    }

    /// Shows draft scenarios and the latest verdict attached to each.
    private var scenarioList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scenarios").font(.headline)
            ForEach(studio.document?.scenarios ?? []) { scenario in
                Button {
                    studio.selection = scenario.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(scenario.name.isEmpty ? "Untitled scenario" : scenario.name).fontWeight(.medium)
                        if let result = studio.run?.scenarios.first(where: { $0.id == scenario.id }) {
                            Text(studio.isStale(result) ? "Stale · \(result.state.label)" : result.state.label)
                                .font(.caption).foregroundStyle(.secondary)
                            if let passed = result.passed {
                                Text("\(passed) of \(result.attempted) repeats passed").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(studio.selection == scenario.id ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(studio.selection == scenario.id ? .isSelected : [])
                .contextMenu {
                    Button("Delete scenario…", role: .destructive) { pendingDeletion = scenario }.disabled(busy)
                }
            }
            Button("New scenario", systemImage: "plus") { addScenario() }
                .accessibilityIdentifier("siri-studio-new-scenario")
                .disabled(busy || studio.document == nil || (studio.document?.scenarios.count ?? 0) >= 200)
        }
    }

    /// Shows the selected scenario's conversation, repeat count, and optional setup.
    @ViewBuilder private var conversation: some View {
        if let id = studio.selection, let scenario = binding(for: id) {
            SiriStudioConversation(scenario: scenario, actions: catalog.actions, turnID: $turnID)
                .disabled(busy)
        } else {
            ContentUnavailableView("No scenario selected", systemImage: "text.bubble",
                description: Text("Create a scenario or open a document to start authoring."))
        }
    }

    /// Edits the selected turn and shows its observations from the frozen run.
    @ViewBuilder private var inspector: some View {
        if let id = studio.selection, let scenario = binding(for: id) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Inspector").font(.headline)
                if let turn = scenario.turns.first(where: { $0.wrappedValue.id == turnID }) ?? scenario.turns.first {
                    SiriStudioExpectationEditor(group: turn.expectations, actions: catalog.actions, allowsReply: true)
                        .disabled(busy)
                }
                if let run = studio.run, let result = run.scenarios.first(where: { $0.id == id }) {
                    SiriStudioInspector(run: run, result: result,
                        turnID: turnID ?? scenario.wrappedValue.turns.first?.id,
                        stale: studio.isStale(result))
                }
            }
        }
    }

    /// Edits the shared Xcode and signing fields and the optional scenario allowance.
    private var signing: some View {
        DisclosureGroup("Xcode and signing") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Developer directory", text: $native.developerDirectory)
                    .accessibilityLabel("Developer directory")
                TextField("Signing identity", text: $native.signingIdentity, prompt: Text("Apple Development: …"))
                    .accessibilityLabel("Signing identity")
                TextField("Team identifier", text: $native.teamIdentifier)
                    .accessibilityLabel("Team identifier")
                Toggle("Use a custom test allowance", isOn: $customAllowance)
                if customAllowance {
                    Stepper("Per scenario: \(allowance) seconds", value: $allowance, in: 1...1800)
                }
            }.padding(.top, 8)
        }
        .disabled(busy)
    }

    /// Creates and selects a new draft without losing any existing scenarios.
    private func addScenario() {
        let new = SiriStudioScenario(name: "Scenario \((studio.document?.scenarios.count ?? 0) + 1)")
        studio.document?.scenarios.append(new)
        studio.selection = new.id
    }

    /// Deletes the confirmed draft and selects a neighboring scenario.
    private func remove(_ id: UUID) {
        studio.document?.scenarios.removeAll { $0.id == id }
        if studio.selection == id { studio.selection = studio.document?.scenarios.first?.id }
    }

    /// Starts the chosen selection with the shared native configuration.
    private func start(all: Bool) {
        studio.start(all: all, developer: native.developerDirectory, team: native.teamIdentifier,
                     identity: native.signingIdentity, allowance: customAllowance ? allowance : nil)
    }

    /// Identifies the type of file or directory to open.
    private enum OpenKind { case document, result, run }

    /// Presents a file panel and hands the chosen local file to the store.
    private func open(_ kind: OpenKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind != .run
        panel.canChooseDirectories = kind == .run
        panel.allowedContentTypes = switch kind {
        case .document: [.json]
        case .result: [UTType(filenameExtension: "xcresult") ?? .bundle]
        case .run: [.folder]
        }
        present(panel) { url in
            perform {
                switch kind {
                case .document: try studio.openDocument(url)
                case .result: studio.importResult(url, developer: native.developerDirectory)
                case .run: try studio.openRun(url)
                }
            }
        }
    }

    /// Prompts for a destination before writing a document copy or the generated Swift.
    private func export(swift: Bool, all: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = swift ? "SiriStudioTests.swift" : "scenarios.json"
        panel.allowedContentTypes = swift ? [.swiftSource] : [.json]
        present(panel) { url in
            perform { try studio.export(url, swift: swift, all: all) }
        }
    }

    /// Requires a separate explicit choice to include authored and observed conversation text.
    private func exportEvidence(transcripts: Bool) {
        guard let run = studio.run else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transcripts ? "siri-studio-run-with-transcripts.json" : "siri-studio-verdicts.json"
        panel.allowedContentTypes = [.json]
        present(panel) { url in
            perform { try run.exportEvidence(to: url, includeTranscripts: transcripts) }
        }
    }

    /// Presents a sheet without nesting AppKit's modal loop inside a SwiftUI menu action.
    private func present(_ panel: NSSavePanel, completion: @escaping @MainActor @Sendable (URL) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            studio.report(MacIntentTestingError("Open Siri Studio in a window before choosing a file."))
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            panel.orderOut(nil)
            completion(url)
        }
    }

    /// Keeps file errors in the workspace diagnostic.
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { studio.report(error) }
    }
}

extension SiriStudioState {
    /// Shows the user-facing state without collapsing incomplete and blocked runs into failures.
    var label: String { rawValue.capitalized }
}
