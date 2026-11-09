import AppKit
import MacIntentTesting
import SwiftUI
import UniformTypeIdentifiers

/// Matches the workspace's editor navigation while separating authoring, evidence, and setup.
private enum SiriStudioPage: String, CaseIterable, Identifiable {
    case conversations, results, setup
    var id: Self { self }
    var title: String {
        switch self {
        case .conversations: "Conversations"
        case .results: "Results"
        case .setup: "Setup"
        }
    }
}

/// Uses the same toolbar navigation, item list, and focused content surfaces as the suite editor.
struct SiriStudioView: View {
    @Bindable var native: MacIntentTestingStore
    @Bindable var studio: SiriStudioStore
    let catalog: MacIntentCatalog?
    let chooseApp: () -> Void
    let showDirectAction: () -> Void
    @State private var page = SiriStudioPage.conversations
    @State private var turnID: UUID?
    @State private var showsAdvanced = false
    @State private var hidesGuide = false
    @State private var customAllowance = false
    @State private var allowance = 900
    @State private var pendingDeletion: SiriStudioScenario?
    @State private var panelWindow = SiriStudioPanelWindow()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if !hidesGuide && (guideStep == .app || page != .results) {
                SiriStudioGuide(step: guideStep, busy: busy,
                    canCreateExample: catalog?.actions.isEmpty == false && (studio.document?.scenarios.count ?? 200) < 200,
                    advance: advanceGuide, createExample: createGuidedExample,
                    directAction: returnToDirectAction, dismiss: { hidesGuide = true })
            }
            if catalog == nil || (guideStep == .app && page != .results) {
                chooseAppState
            } else if page == .conversations {
                GeometryReader { geometry in
                    conversationWorkspace.frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if page == .setup { setupPage } else { resultsPage }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("App Intent steps")
            }
        }
        .padding(.horizontal, WorkspaceStyle.pagePadding)
        .padding(.top, 20).padding(.bottom, 18)
        .frame(maxWidth: WorkspaceStyle.readableWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("App Intents")
        .background(SiriStudioWindowReader(reference: panelWindow).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Direct Action", systemImage: "chevron.backward", action: returnToDirectAction)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("siri-studio-back-to-direct-action")
                    .help("Save your conversation and return to direct App Intent testing.")
                    .disabled(busy)
            }
            ToolbarItem(placement: .principal) {
                if catalog != nil {
                    Picker("Siri Studio page", selection: $page) {
                        ForEach(SiriStudioPage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("Siri Studio page")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Guided setup", systemImage: "list.number") { hidesGuide = false; page = .setup }
            }
            ToolbarItem(placement: .primaryAction) { advancedMenu }
            ToolbarItem(placement: .primaryAction) {
                Button(studio.diagnostic == nil ? "Save" : "Retry Save") { perform { try studio.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(busy || studio.document == nil)
            }
            ToolbarItem(placement: .primaryAction) { runControls }
        }
        .onChange(of: catalog?.productIdentity, initial: true) { _, identity in
            if identity != nil { native.detectSiriSetup(); hidesGuide = false; page = .setup }
        }
        .onChange(of: studio.document?.bundleIdentifier, initial: true) { _, bundle in
            if bundle != nil {
                if studio.document?.scenarios.isEmpty == true { addScenario() }
            }
        }
        .onChange(of: studio.selection) { _, _ in turnID = nil }
        .onChange(of: studio.run?.endedAt) { _, value in if value != nil { page = .results } }
        .onChange(of: page) { _, value in
            if value == .conversations, !(studio.document?.scenarios.contains { $0.id == studio.selection } ?? false) {
                studio.selection = studio.document?.scenarios.first?.id
            }
        }
        .confirmationDialog("Delete conversation?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { scenario in
            Button("Delete \(scenario.name)", role: .destructive) { remove(scenario.id) }
        }
    }

    /// Reflects the selected app and real readiness checks instead of maintaining a second completion checklist.
    private var guideStep: SiriStudioGuideStep {
        .current(catalog: catalog, macReady: prerequisite == nil,
                 conversationReady: hasSelectedDraft && studio.validationError == nil)
    }

    /// Takes the user to the next incomplete stage without bypassing validation or setup requirements.
    private func advanceGuide() {
        switch guideStep {
        case .app: chooseApp()
        case .mac: page = .setup; native.detectSiriSetup()
        case .conversation: page = .conversations
        case .run: start(all: false); page = .results
        }
    }

    /// Adds an explicit example as a new draft so existing authored conversations remain untouched.
    private func createGuidedExample() {
        guard !busy, let catalog, (studio.document?.scenarios.count ?? 200) < 200,
              let example = SiriStudioGuideStep.example(for: catalog) else { return }
        studio.document?.scenarios.append(example)
        studio.selection = example.id
        page = .conversations
    }

    /// Presents app context and a direct setup action using the same heading style as other workspaces.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspacePageHeader("App Intents", subtitle: catalog.map {
                "\($0.appURL.deletingPathExtension().lastPathComponent) · \(studio.document?.scenarios.count ?? 0) conversations"
            } ?? native.selectedAppURL.map { "Selected: \($0.deletingPathExtension().lastPathComponent)" }
              ?? "Test your app’s actions with a Siri conversation.")
            if studio.hasUnsavedEdits {
                Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("siri-studio-unsaved")
            }
            ForEach(Array(Set([selectionFailed ? nil : native.diagnostic, studio.diagnostic].compactMap { $0 })).sorted(), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("siri-studio-diagnostic")
            }
            if native.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Inspecting app…")
                    Button("Cancel inspection") { native.cancel() }
                }
            }
            if guideStep != .app {
                HStack(spacing: 10) {
                    if prerequisite != nil {
                        Button("Finish setup", systemImage: "exclamationmark.circle") { page = .setup }
                    } else { Label("Ready to run", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button("Change app…") { chooseApp() }.disabled(busy)
                }.font(.callout)
            }
        }
    }

    /// Explains eligibility, preserves a rejected selection, and gives concrete next steps before setup.
    private var chooseAppState: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            if selectionFailed {
                Label(missingActions
                    ? "\(selectedAppName) doesn’t include Siri actions"
                    : "We couldn’t inspect \(selectedAppName)", systemImage: "exclamationmark.triangle")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("siri-studio-app-selection-error")
                Text(missingActions
                    ? "This copy cannot be tested yet. An older app in Applications may not include the actions you just added to your project."
                    : "Choose the updated Mac .app itself. If access was denied, choose it again to allow Intents to read its Siri actions.")
                appGuideStep(1, "Build your updated Mac app", "Open your project in Xcode and build the Mac target with its Siri actions.")
                appGuideStep(2, "Install that build", "Copy the updated app to Applications, replacing the older copy. Open it once, then quit it.")
                appGuideStep(3, "Choose the updated app here", "We’ll inspect its actions and check Xcode and signing for you.")
            } else {
                Label("Test your app with Siri", systemImage: "app.badge.checkmark").font(.title2.weight(.semibold))
                Text("Start with a Mac app you’re developing that includes Siri actions. An app without those actions cannot be tested here.")
                Text("In Xcode, build your Mac target. Choose Product → Show Build Folder in Finder and find your .app under Products/Debug. Copy it to Applications, open it once, then quit it and choose that copy here.")
                Text("Choose the .app itself, not an Xcode project. iPhone and iPad builds are not supported by this Mac testing workflow.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if hidesGuide {
                    Button(selectionFailed ? "Choose another app…" : "Choose app…") { chooseApp() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac-intent-choose-app").disabled(busy)
                }
                if let url = native.selectedAppURL, selectionFailed {
                    Button("Check \(selectedAppName) again") { native.load(appURL: url) }.disabled(busy)
                }
                if selectionFailed, let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                    Button("Open Xcode") { NSWorkspace.shared.open(xcode) }
                }
            }
            if selectionFailed && showsAdvanced, let detail = native.diagnostic {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceSurface()
    }

    /// Retains the chosen name while a catalog is unavailable, including loading and failure states.
    private var selectedAppName: String { native.selectedAppURL?.deletingPathExtension().lastPathComponent ?? "This app" }

    /// Explains readable catalogs with no actions just as clearly as missing compiled metadata.
    private var missingActions: Bool { catalog?.actions.isEmpty == true || native.appSelectionIssue == .missingActions }

    /// Keeps app eligibility failures in the first stage instead of directing users into an unusable editor.
    private var selectionFailed: Bool {
        missingActions || (catalog == nil && !native.isLoading && native.selectedAppURL != nil && native.diagnostic != nil)
    }

    /// Presents one short, numbered instruction using the workspace’s standard text styles.
    private func appGuideStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Keeps the item list beside a focused editor, using the suite workspace's existing surfaces.
    private var conversationWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                conversationList.frame(width: 240)
                conversationEditor.frame(minWidth: 340)
            }
            VStack(spacing: 16) {
                conversationList.frame(height: 170)
                conversationEditor
            }
        }
    }

    /// Lists conversations and their latest outcomes, with creation and deletion in the same places as test cases.
    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePanelHeader("Conversations", count: studio.document?.scenarios.count ?? 0)
            Divider()
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(studio.document?.scenarios ?? []) { scenario in
                        Button { studio.selection = scenario.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(scenario.name.isEmpty ? "Untitled conversation" : scenario.name).fontWeight(.semibold)
                                Text(scenario.turns.first?.utterance ?? "Add your first message")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let result = studio.run?.scenarios.first(where: { $0.id == scenario.id }) {
                                    Text(studio.isStale(result) ? "Out of date · \(result.state.label)" : result.state.label)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(studio.selection == scenario.id ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(studio.selection == scenario.id ? .isSelected : [])
                        .contextMenu { Button("Delete conversation…", role: .destructive) { pendingDeletion = scenario }.disabled(busy) }
                    }
                }.padding(6)
            }
            Divider()
            Button("New conversation", systemImage: "plus") { addScenario() }
                .accessibilityIdentifier("siri-studio-new-scenario")
                .disabled(busy || studio.document == nil || (studio.document?.scenarios.count ?? 0) >= 200)
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .workspaceSurface()
    }

    /// Keeps only messages, expected actions, and optional advanced checks in the conversation editor.
    private var conversationEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let id = studio.selection, let scenario = binding(for: id) {
                    if let issue = studio.validationError {
                        Text(issue).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("siri-studio-diagnostic")
                    }
                    advancedNotice
                    SiriStudioConversation(scenario: scenario, actions: catalog?.actions ?? [], turnID: $turnID, showsAdvanced: showsAdvanced)
                        .disabled(busy)
                    if studio.run?.scenarios.contains(where: { $0.id == id }) == true {
                        Button("View results", systemImage: "chart.bar.doc.horizontal") { page = .results }
                    }
                } else {
                    WorkspaceEmptyState(symbol: "text.bubble", title: "Choose a conversation",
                        detail: "Select a conversation or add one to write your messages and expected actions.")
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("App Intent steps")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .workspaceSurface()
    }

    /// Keeps runtime prerequisites and manual overrides on a dedicated setup page.
    @ViewBuilder private var setupPage: some View {
        if let catalog {
            Text("We check Xcode and signing for you. Complete the next step below, then open Conversations. You can write a conversation while finishing setup.")
                .font(.callout).foregroundStyle(.secondary)
            SiriStudioSetupView(native: native, catalog: catalog, showsAdvanced: showsAdvanced)
            Button("Write a conversation", systemImage: "text.bubble") { page = .conversations }
            if showsAdvanced { signing.padding(20).workspaceSurface() }
        }
    }

    /// Separates live progress and completed results from the conversation's authoring controls.
    private var resultsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let run = studio.run, !run.scenarios.isEmpty {
                Picker("Conversation", selection: $studio.selection) {
                    ForEach(studio.document?.scenarios ?? []) { Text($0.name).tag(Optional($0.id)) }
                    ForEach(run.scenarios.filter { result in
                        !(studio.document?.scenarios.contains { $0.id == result.id } ?? false)
                    }) { Text("Saved · " + $0.name).tag(Optional($0.id)) }
                }
                .accessibilityLabel("Conversation")
                .accessibilityIdentifier("siri-studio-result-conversation")
            }
            if studio.isBusy {
                ProgressView(progressLabel)
                Button("Cancel") { studio.cancel() }
            } else if let id = studio.selection, let run = studio.run,
                      let result = run.scenarios.first(where: { $0.id == id }) {
                SiriStudioInspector(run: run, result: result,
                    turnID: turnID ?? studio.document?.scenarios.first(where: { $0.id == id })?.turns.first?.id,
                    stale: studio.isStale(result), showsAdvanced: showsAdvanced, actions: catalog?.actions ?? [])
            } else {
                WorkspaceEmptyState(symbol: "chart.bar.doc.horizontal", title: "No result yet",
                    detail: "Run a conversation to review Siri’s replies and the actions it called.")
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface()
    }

    /// Keeps technical controls and file operations in the same toolbar layer as the other workspaces.
    private var advancedMenu: some View {
        Menu("Advanced", systemImage: "slider.horizontal.3") {
            Toggle("Show advanced controls", isOn: $showsAdvanced)
            Button("Test an action directly", action: returnToDirectAction).disabled(busy)
            Divider()
            Button("Export Swift…") { export(swift: true) }.disabled(busy || studio.validationError != nil || !hasSelectedDraft)
            Button("Export all scenarios as Swift…") { export(swift: true, all: true) }.disabled(busy || studio.allValidationError != nil)
            Button("Open scenario document…") { open(.document) }.disabled(busy || catalog == nil)
            Button("Export scenario document…") { export(swift: false) }.disabled(busy || studio.document == nil)
            Button("Import result bundle…") { open(.result) }.disabled(busy || studio.document == nil)
            Button("Open saved run…") { open(.run) }.disabled(busy || catalog == nil)
            if studio.run != nil {
                Button("Export verdict summary…") { exportEvidence(transcripts: false) }.disabled(busy)
                Button("Export run with transcripts…") { exportEvidence(transcripts: true) }.disabled(busy)
            }
            Divider()
            Button("Run all conversations") { start(all: true) }
                .help(studio.allValidationError ?? prerequisite ?? "Run every conversation")
                .disabled(busy || guideStep == .app || prerequisite != nil || studio.allValidationError != nil)
        }
        .accessibilityIdentifier("siri-studio-advanced")
    }

    /// Starts the selected test from the workspace toolbar while retaining the shared runner admission checks.
    private var runControls: some View {
        Group {
            if studio.isBusy { Button("Cancel") { studio.cancel() } }
            else {
                Button { start(all: false); page = .results } label: {
                    Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                    .buttonStyle(.borderedProminent)
                    .help(prerequisite ?? studio.validationError ?? "Run the selected conversation")
                    .disabled(busy || guideStep == .app || prerequisite != nil || studio.validationError != nil || !hasSelectedDraft)
            }
        }
    }

    /// Makes retained technical settings visible without mixing their controls into the simple editor.
    @ViewBuilder private var advancedNotice: some View {
        if !showsAdvanced && hasAdvancedSettings {
            Label("Advanced settings apply to this test.", systemImage: "slider.horizontal.3")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("siri-studio-saved-settings")
        }
    }

    /// Warns about every retained rule or runtime override that is not represented by the simple action menus.
    private var hasAdvancedSettings: Bool {
        guard let scenario = studio.document?.scenarios.first(where: { $0.id == studio.selection }) else { return false }
        let groups = [scenario.scenarioExpectations] + scenario.turns.map(\.expectations)
        return !studio.appLaunchArguments.isEmpty || customAllowance || scenario.repeatCount > 1 || scenario.setup != nil
            || groups.contains { $0.ordering != .ordered || !$0.forbidden.isEmpty || !$0.replyContains.isEmpty
                || $0.calls.contains { !$0.arguments.isEmpty || $0.result != nil } }
            || !scenario.scenarioExpectations.calls.isEmpty
    }

    /// Distinguishes an editable conversation from an outcome whose original draft was removed.
    private var hasSelectedDraft: Bool {
        studio.document?.scenarios.contains { $0.id == studio.selection } ?? false
    }

    /// Explains which runtime prerequisite needs attention without locking authoring.
    private var prerequisite: String? {
        if catalog == nil { return "Choose an app first." }
        return native.siriSetup.issue(configuration: native.setupConfiguration) ?? studio.launchArgumentsError
    }

    /// Disables competing commands while either native mode owns a run.
    private var busy: Bool { native.isRunning || native.isLoading || studio.isBusy }

    /// Binds by stable scenario identity so selection or deletion cannot redirect edits.
    private func binding(for id: UUID) -> Binding<SiriStudioScenario>? {
        guard let initial = studio.document?.scenarios.first(where: { $0.id == id }) else { return nil }
        return Binding {
            studio.document?.scenarios.first(where: { $0.id == id }) ?? initial
        } set: { value in
            guard let index = studio.document?.scenarios.firstIndex(where: { $0.id == id }) else { return }
            studio.document?.scenarios[index] = value
        }
    }

    /// Describes the current scenario and repeat while the generated suite runs.
    private var progressLabel: String {
        guard let progress = studio.progress,
              let scenario = studio.document?.scenarios.first(where: { $0.id == progress.scenarioID }) else { return "Preparing run…" }
        return "\(scenario.name) · repeat \(progress.repeatIndex + 1) of \(scenario.repeatCount)"
    }

    /// Edits the shared Xcode and signing fields and the optional scenario allowance.
    private var signing: some View {
        DisclosureGroup("Xcode and signing") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("App", value: catalog?.appURL.path ?? "No app selected")
                LabeledContent("Bundle identifier", value: catalog?.bundleIdentifier ?? "")
                TextField("Developer directory", text: $native.developerDirectory)
                    .accessibilityLabel("Developer directory")
                TextField("Signing identity", text: $native.signingIdentity, prompt: Text("Apple Development: …"))
                    .accessibilityLabel("Signing identity")
                TextField("Team identifier", text: $native.teamIdentifier)
                    .accessibilityLabel("Team identifier")
                TextField("App launch arguments (one per line)", text: $studio.appLaunchArgumentsText, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityLabel("App launch arguments")
                Text("Optional test-data flags. Each line is one literal argument. Saved with this app’s scenarios and local runs; omitted from verdict-only exports.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = studio.launchArgumentsError { Text(error).font(.callout).foregroundStyle(.red) }
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
        let new = SiriStudioScenario(name: "Conversation \((studio.document?.scenarios.count ?? 0) + 1)")
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
                case .document: try studio.openDocument(url); page = .conversations
                case .result: studio.importResult(url, developer: native.developerDirectory); page = .results
                case .run: try studio.openRun(url); page = .results
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
        guard let window = panelWindow.window else {
            studio.report(MacIntentTestingError("Open Siri Studio in a window before choosing a file."))
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            panel.orderOut(nil)
            completion(url)
        }
    }

    /// Saves conversation edits before leaving Studio and keeps the editor open if saving fails.
    private func returnToDirectAction() {
        guard !busy else { return }
        perform { try studio.save(); showDirectAction() }
    }

    /// Keeps file errors in the workspace diagnostic.
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { studio.report(error) }
    }
}

/// Keeps a weak reference to the workspace's own window without publishing view-update state.
@MainActor
private final class SiriStudioPanelWindow {
    weak var window: NSWindow?
}

/// Connects file sheets to their workspace even while a toolbar menu temporarily owns focus.
private struct SiriStudioWindowReader: NSViewRepresentable {
    let reference: SiriStudioPanelWindow

    /// Creates an inert window probe whose lifetime follows this workspace.
    func makeNSView(context: Context) -> SiriStudioWindowProbe {
        SiriStudioWindowProbe(reference: reference)
    }

    /// Keeps the probe associated with the current reference when SwiftUI updates it.
    func updateNSView(_ nsView: SiriStudioWindowProbe, context: Context) {
        nsView.reference = reference
        reference.window = nsView.window
    }
}

/// Tracks attachment and removal without retaining the window or relying on global focus.
private final class SiriStudioWindowProbe: NSView {
    var reference: SiriStudioPanelWindow

    /// Associates this probe with the workspace's weak window storage.
    init(reference: SiriStudioPanelWindow) {
        self.reference = reference
        super.init(frame: .zero)
    }

    /// Rejects archive construction because this probe is created only by its representable.
    required init?(coder: NSCoder) { nil }

    /// Refreshes the owner when AppKit attaches or detaches the workspace.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference.window = window
    }
}

extension SiriStudioState {
    /// Shows the user-facing state without collapsing incomplete and blocked runs into failures.
    var label: String { rawValue.capitalized }
}
