import SwiftUI
import UniformTypeIdentifiers

private enum RubricTemplate: String, CaseIterable, Identifiable {
    case general
    case factual
    case summary
    case writing

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General answer"
        case .factual: "Grounded answer"
        case .summary: "Summary"
        case .writing: "Writing and tone"
        }
    }

    var requirements: String {
        switch self {
        case .general:
            EvaluationSuite.defaultRubric
        case .factual:
            """
            Every material claim agrees with the supplied reference answer or reference files.
            The response includes all facts needed to answer the prompt.
            The response does not invent unsupported details.
            The response follows every requested format and length constraint.
            """
        case .summary:
            """
            The summary includes every central point from the supplied source.
            The summary contains no claim that is unsupported by the source.
            The summary removes repetition and nonessential detail.
            The summary follows the requested length, format, and tone.
            """
        case .writing:
            """
            The response uses the requested audience, tone, and point of view.
            The response communicates the intended meaning clearly and unambiguously.
            The response is concise and contains no unnecessary repetition.
            The response follows every requested structure and length constraint.
            """
        }
    }
}

enum SuiteEditorPage: String, CaseIterable, Identifiable {
    case cases
    case runs
    case review
    case configure

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .cases: "Cases"
        case .runs: "Runs"
        case .review: "Review"
        case .configure: "Setup"
        }
    }
}

private enum RunsMode {
    case history
    case compare
}

struct SuiteEditorView: View {
    @Environment(DeveloperRunnerStore.self) private var runners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: EvaluationStore
    let initialPage: SuiteEditorPage
    @State private var selectedPage: SuiteEditorPage
    @State private var configurationPage = SuiteSetupPage.instructions
    @State private var configurationScrollRequest = UUID()
    @State private var shouldScrollToConfigurationPage = false
    @State private var expandedSetupSections: Set<SuiteSetupPage> = []
    @State private var runsMode: RunsMode = .history
    @State private var selectedCaseID: UUID?
    @State private var showsRunDetails = false
    @State private var showsDevices = false
    @State private var showsPromptImprovement = false
    @State private var runError: String?
    @FocusState private var isEditorFocused: Bool

    /// Connects the suite store and seeds the selected editor page from the requested initial page.
    init(store: EvaluationStore, initialPage: SuiteEditorPage = .cases) {
        self.store = store
        self.initialPage = initialPage
        _selectedPage = State(initialValue: initialPage)
    }

    private var isRunActive: Bool { store.isRunning || runners.executingRunID != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if selectedPage == .cases {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        GeometryReader { geometry in
                            SuiteCasesView(store: store, selectedCaseID: $selectedCaseID)
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        }
                    }
                    .padding(.horizontal, WorkspaceStyle.pagePadding)
                    .padding(.top, 20).padding(.bottom, 18)
                    .frame(maxWidth: WorkspaceStyle.readableWidth, maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: selectedPage == .configure ? 28 : 24) {
                                header
                                selectedPageContent
                            }
                            .workspacePage()
                            .id("suite-page-top")
                        }
                        .accessibilityIdentifier("Suite editor scroll")
                        .onAppear { scrollToConfigurationPage(using: proxy) }
                        .onChange(of: configurationScrollRequest) { _, _ in
                            scrollToConfigurationPage(using: proxy)
                        }
                    }
                }
            }
            .id(selectedPage)
            .transition(.blurReplace.combined(with: .offset(y: 6)))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isRunActive)
        .animation(reduceMotion ? nil : WorkspaceStyle.pageMotion, value: selectedPage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($isEditorFocused)
        .defaultFocus($isEditorFocused, true)
        .background {
            SuiteEditorSelectionObserver(
                store: store,
                initialPage: initialPage,
                selectedPage: $selectedPage,
                selectedCaseID: $selectedCaseID,
                runsMode: $runsMode
            )
        }
        .navigationTitle(store.draftSuite.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Suite page", selection: $selectedPage) {
                    ForEach(SuiteEditorPage.allCases) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Editor page")
            }
            SuiteRunToolbar(
                store: store,
                runners: runners,
                showsRunDetails: $showsRunDetails,
                showsDevices: $showsDevices,
                error: $runError
            )
        }
        .sheet(isPresented: $showsDevices) { DeveloperDevicesView(runners: runners) }
        .sheet(isPresented: $showsPromptImprovement) {
            PromptImprovementView(store: store) { needsCases in
                if needsCases { selectedPage = .cases }
                else { showConfigurationPage(.scoring) }
            }
        }
        .alert("Could not start run", isPresented: Binding(get: { runError != nil }, set: { if !$0 { runError = nil } })) {
            Button("OK") { runError = nil }
        } message: {
            Text(runError ?? "")
        }
        .fileImporter(
            isPresented: $store.isImportingFiles,
            allowedContentTypes: [.text, .json, .commaSeparatedText, .pdf, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): store.importFiles(urls)
            case .failure(let error): store.notice = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            SuiteOverviewHeader(store: store)
            if let migrationNotice = store.migrationNotice {
                WorkspaceNotice(.info, message: migrationNotice)
            }
            if let response = store.liveResponse, store.isRunning {
                LiveResponseSection(response: response)
            }
        }
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .cases:
            EmptyView() // Laid out separately in `body` as a master–detail page.
        case .runs:
            switch runsMode {
            case .history:
                SuiteResultsView(store: store, showCompare: {
                    selectedPage = .runs
                    runsMode = .compare
                })
            case .compare:
                VStack(alignment: .leading, spacing: 16) {
                    Button("All runs", systemImage: "chevron.left") { runsMode = .history }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("Back to runs")
                    SuiteCompareView(store: store, showPromptImprovement: { showsPromptImprovement = true })
                }
            }
        case .review:
            SuiteReviewView(store: store, showCases: { id in
                selectedCaseID = id; selectedPage = .cases
            }, showCompare: {
                selectedPage = .runs
                runsMode = .compare
            })
                .id(store.selectedSuiteID)
        case .configure:
            setupPageContent
        }
    }

    private var setupPageContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(SuiteSetupPage.basics) { page in
                setupSection(page)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Advanced")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(SuiteSetupPage.advanced) { page in
                    setupSection(page)
                }
            }
        }
    }

    /// Builds an always-visible basic section or a collapsed advanced section.
    @ViewBuilder
    private func setupSection(_ page: SuiteSetupPage) -> some View {
        if SuiteSetupPage.basics.contains(page) {
            VStack(alignment: .leading, spacing: 12) {
                setupSectionHeading(page)
                configurationContent(for: page)
            }
            .id(page)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Setup section \(page.title)")
        } else {
            DisclosureGroup(isExpanded: setupSectionExpansion(for: page)) {
                configurationContent(for: page)
                    .disabled(isConfigurationBusy)
                    .padding(.top, 14)
            } label: {
                setupSectionHeading(page)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page)
            .accessibilityIdentifier("Setup section \(page.title)")
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .workspaceSurface()
        }
    }

    /// Builds the title and supporting copy shown for a setup section.
    private func setupSectionHeading(_ page: SuiteSetupPage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(page.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var isConfigurationBusy: Bool {
        store.isRunning || store.isReassessing || store.isProcessingFiles
    }

    /// Binds an advanced section's disclosure state to the expanded-section set.
    private func setupSectionExpansion(for page: SuiteSetupPage) -> Binding<Bool> {
        Binding(
            get: { expandedSetupSections.contains(page) },
            set: { isExpanded in
                if isExpanded { expandedSetupSections.insert(page) }
                else { expandedSetupSections.remove(page) }
            }
        )
    }

    /// Opens Setup, expands an advanced target, and requests a scroll to it.
    private func showConfigurationPage(_ page: SuiteSetupPage) {
        if SuiteSetupPage.advanced.contains(page) {
            expandedSetupSections.insert(page)
        }
        configurationPage = page
        selectedPage = .configure
        shouldScrollToConfigurationPage = true
        configurationScrollRequest = UUID()
    }

    /// Scrolls to a requested section after its ScrollViewReader is available.
    private func scrollToConfigurationPage(using proxy: ScrollViewProxy) {
        guard shouldScrollToConfigurationPage else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(configurationPage, anchor: .top) }
        shouldScrollToConfigurationPage = false
    }

    /// Builds the existing controls for the specified setup section.
    @ViewBuilder
    private func configurationContent(for page: SuiteSetupPage) -> some View {
        switch page {
        case .instructions:
            ModelInstructionsSection(store: store, showPromptImprovement: { showsPromptImprovement = true })
            SharedReferenceFilesSection(store: store)
                .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
        case .scoring:
            ScoringSection(store: store)
            if store.draftSuite.scoringMode == .modelJudge {
                JudgeConfigurationSection(store: store)
                    .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
            }
            SuiteOptionalSection(title: "Release requirements", detail: "Pass thresholds, baseline and latency limits") {
                ReleasePolicySection(store: store)
            }
            .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
        case .model:
            ModelControlsSection(store: store)
        case .tools:
            FeatureControlsView(store: store, selectedPage: .tools, showsSectionHeader: false)
        case .output:
            FeatureControlsView(store: store, selectedPage: .output, showsSectionHeader: false)
        case .profile:
            FeatureControlsView(store: store, selectedPage: .profile, showsSectionHeader: false)
        case .performance:
            FeatureControlsView(store: store, selectedPage: .performance, showsSectionHeader: false)
        }
    }
}

private struct SuiteEditorSelectionObserver: View {
    let store: EvaluationStore
    let initialPage: SuiteEditorPage
    @Binding var selectedPage: SuiteEditorPage
    @Binding var selectedCaseID: UUID?
    @Binding var runsMode: RunsMode

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                repairEditorSelection(selectedCaseID, ids: store.draftSuite.cases.map(\.id)) { selectedCaseID = $0 }
            }
            .onChange(of: store.draftSuite.id) { _, _ in
                selectedPage = initialPage
                runsMode = .history
            }
            .onChange(of: store.draftSuite.cases.map(\.id)) { _, _ in
                repairEditorSelection(selectedCaseID, ids: store.draftSuite.cases.map(\.id)) { selectedCaseID = $0 }
            }
    }
}

private struct SuiteOverviewHeader: View {
    @Environment(DeveloperRunnerStore.self) private var runners
    @Bindable var store: EvaluationStore
    @State private var showsDetails = false
    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var caseCount: Int { store.draftSuite.cases.count }

    private var metadata: String {
        [
            "\(caseCount) case\(caseCount == 1 ? "" : "s")",
            store.draftSuite.scoringMode.title,
            runners.selectedRunner?.identity.displayName ?? store.draftSuite.modelConfiguration.provider.title
        ].joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Suite name", text: $store.draftSuite.name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .accessibilityLabel("Suite name").disabled(isBusy)
                    HStack(spacing: 10) {
                        Text(metadata).lineLimit(1)
                        saveStatus
                        if !store.isRunning, let blocker = runners.runIssue(for: store) {
                            let shortText = blocker.count <= 40 ? blocker : "Can't run"
                            Label(shortText, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(WorkspaceStyle.warning)
                                .help(blocker)
                                .accessibilityLabel(blocker)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if let run = store.runs.first {
                    LatestResultChip(run: run, state: SuiteCheckState.evaluate(
                        run: run, currentRevision: store.suiteRevision, hasDraft: store.draftSuite != store.suite
                    )) { store.selection = .run(run.id) }
                }
                Button("Suite details", systemImage: "info.circle") { showsDetails = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .help("Version and model availability")
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details }
            }
        }
    }

    /// Saving is automatic, so only say something when it is happening or has gone wrong.
    @ViewBuilder private var saveStatus: some View {
        if store.draftSaveFailed {
            Label("Changes could not be saved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkspaceStyle.warning)
                .lineLimit(1)
        } else if store.isDraftSavePending {
            Text("Saving…").foregroundStyle(.tertiary)
        } else {
            Text("· Saved")
                .foregroundStyle(.tertiary)
                .help(store.draftSuite != store.suite ? "Draft saved on this Mac" : "Saved automatically on this Mac")
                .accessibilityLabel(store.draftSuite != store.suite ? "Draft saved on this Mac" : "Saved automatically on this Mac")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suite details").font(.headline)
            LabeledContent("Version") {
                TextField("Suite version", text: $store.draftSuite.version).frame(width: 110)
                    .disabled(isBusy)
            }
            ModelStatusBadge(status: store.modelStatus)
        }
        .padding(20).frame(width: 320)
    }
}

/// The suite's latest result, one click from its report.
private struct LatestResultChip: View {
    let run: EvaluationRun
    let state: SuiteCheckState
    let open: () -> Void

    private var title: String {
        switch state {
        case .passed, .failed: "\(run.passedCount) of \(run.scoredCount) passed"
        default: state.title
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                WorkspaceStatusMark(state: state.mark, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.callout.weight(.semibold)).monospacedDigit()
                    Text("Latest run · \(run.startedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 7)
        }
        .buttonStyle(.glass)
        .help("Open the latest run’s report")
        .accessibilityLabel("Latest run: \(state.title), \(run.passedCount) of \(run.scoredCount) passed")
    }
}

struct RunReadinessPanel: View {
    @Bindable var store: EvaluationStore

    private var responseLabel: String {
        "\(store.plannedSampleCount) response\(store.plannedSampleCount == 1 ? "" : "s")"
    }

    var body: some View {
        let blocker = store.runBlocker
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: statusSymbol(blocker: blocker))
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor(blocker: blocker))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle(blocker: blocker))
                    .font(.headline)
                Text(statusDetail(blocker: blocker))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isRunning {
                    ProgressView(
                        value: Double(store.completedSamples),
                        total: Double(max(store.totalSamples, 1))
                    )
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 12)

            if store.isRunning {
                Button("Cancel Run", role: .cancel) { store.cancelRun() }
            } else if store.hasUnsavedCompletedRun {
                Button("Retry Save") { store.retryPendingRunSave() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Run \(responseLabel)", systemImage: "play.fill") {
                    store.startRun()
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker != nil || store.isProcessingFiles)
            }
        }
        .padding(18)
        .accessibilityElement(children: .contain)
    }

    /// Chooses the readiness heading, prioritizing an active run, an unsaved completed run, and file processing over blockers.
    private func statusTitle(blocker: String?) -> LocalizedStringResource {
        if store.isRunning { return "Evaluation in progress" }
        if store.hasUnsavedCompletedRun { return "Run could not be saved" }
        if store.isProcessingFiles { return "Importing reference files" }
        return blocker == nil ? "Ready to run" : "Needs attention"
    }

    /// Explains the current run, storage, import, or validation state; when ready, describes planned requests and judge behavior.
    private func statusDetail(blocker: String?) -> String {
        if store.isRunning {
            return "You can review the suite while the current run finishes."
        }
        if store.hasUnsavedCompletedRun {
            return blocker ?? "Restore storage access, then retry saving this run to history."
        }
        if store.isProcessingFiles {
            return "The suite will be ready when every selected file has been processed."
        }
        if let blocker {
            return blocker
        }
        if store.draftSuite.scoringMode == .modelJudge {
            if !store.draftSuite.needsModelJudge {
                return requestSummary + " All requirements use deterministic exact-text checks."
            }
            let quotaNote = store.draftSuite.modelConfiguration.provider == .privateCloudCompute
                ? " It uses an additional cloud request and quota for each response."
                : ""
            return requestSummary + " The AI rubric uses greedy decoding with tools off, with at most one repair if its assessment fails validation." + quotaNote
        }
        return requestSummary
    }

    private var requestSummary: String {
        let provider = store.draftSuite.modelConfiguration.provider.title
        let toolSuffix = store.plannedToolCallLimit > 0
            ? " · up to \(store.plannedToolCallLimit) tool calls"
            : ""
        return "\(responseLabel) · up to \(store.plannedRequestCount) model request\(store.plannedRequestCount == 1 ? "" : "s") · \(provider)\(toolSuffix)."
    }

    /// Chooses the readiness symbol, prioritizing active work and unsaved results before the supplied blocker.
    private func statusSymbol(blocker: String?) -> String {
        if store.isRunning { return "waveform.circle.fill" }
        if store.hasUnsavedCompletedRun { return "exclamationmark.triangle.fill" }
        if store.isProcessingFiles { return "arrow.down.doc.fill" }
        return blocker == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    /// Chooses the readiness color, showing active work in accent color and storage or validation problems as warnings.
    private func statusColor(blocker: String?) -> Color {
        if store.isRunning { return .accentColor }
        if store.hasUnsavedCompletedRun { return WorkspaceStyle.warning }
        if store.isProcessingFiles { return .accentColor }
        return blocker == nil ? WorkspaceStyle.success : WorkspaceStyle.warning
    }
}

private struct ModelInstructionsSection: View {
    @Bindable var store: EvaluationStore
    let showPromptImprovement: () -> Void

    var body: some View {
        EditorSection(
            "Model instructions",
            description: "Tell the model how to respond across all cases.",
            showsHeader: false
        ) {
            TextEditor(text: $store.draftSuite.instructions)
                .accessibilityLabel("Model instructions")
                .font(.body)
                .workspaceTextWell(minHeight: 140)
                .disabled(store.isRunning || store.isProcessingFiles || store.isReassessing)
            Button(store.activePromptImprovementID == nil ? "Improve instructions" : "View comparison", systemImage: "sparkles", action: showPromptImprovement)
                .accessibilityIdentifier("Improve instructions")
        }
    }
}

private struct ScoringSection: View {
    @Bindable var store: EvaluationStore
    /// Blocks scoring edits while preserving access to the read-only guide.
    private var editingDisabled: Bool {
        store.isRunning || store.isReassessing || store.isProcessingFiles
    }

    var body: some View {
        EditorSection(
            "Scoring and repetitions",
            description: "Decide what counts as a good answer, and how many times to ask.",
            showsHeader: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Scoring method", selection: $store.draftSuite.scoringMode) {
                    ForEach(ScoringMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingDisabled)

                if store.draftSuite.scoringMode == .modelJudge {
                    Text("Each requirement must score at least 3 to pass.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    WorkspaceNotice(.info, message: store.draftSuite.scoringMode.explanation)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run each case \(store.draftSuite.repetitions) \(store.draftSuite.repetitions == 1 ? "time" : "times")")
                        Text("\(store.plannedSampleCount) response\(store.plannedSampleCount == 1 ? "" : "s") per run. More repeats show how consistent the model is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(
                        "Repetitions: \(store.draftSuite.repetitions)",
                        value: $store.draftSuite.repetitions,
                        in: 1...5
                    )
                    .labelsHidden()
                    .disabled(editingDisabled)
                }

                Text("Add the expected answer for each prompt on the Cases tab.")
                    .font(.caption).foregroundStyle(.secondary)

                if store.draftSuite.scoringMode == .modelJudge {
                    ModelRubricEditor(store: store, editingDisabled: editingDisabled)
                }
            }
        }
    }

}

private struct ModelRubricEditor: View {
    @Bindable var store: EvaluationStore
    let editingDisabled: Bool
    @State private var showsScoringGuide = false

    private var isValid: Bool {
        (1...4).contains(store.draftSuite.rubricCriteria.count)
    }

    var body: some View {
        Divider()

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI rubric requirements")
                    .font(.headline)
                Text("Write one observable requirement per line, up to four.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Use Template", systemImage: "wand.and.stars") {
                templateActions
            }
            .disabled(editingDisabled)
            .accessibilityActions { templateActions }
        }

        TextEditor(text: $store.draftSuite.criteria)
            .accessibilityLabel("AI rubric requirements")
            .font(.body)
            .workspaceTextWell(minHeight: 112)
            .disabled(editingDisabled)

        Label(
            "\(store.draftSuite.rubricCriteria.count) of 4 requirements",
            systemImage: isValid ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(isValid ? Color.secondary : WorkspaceStyle.warning)

        Text("A matching reference answer does not bypass the rubric.")
            .font(.caption).foregroundStyle(.secondary)

        DisclosureGroup(isExpanded: $showsScoringGuide) {
            RubricScale()
            Label(
                "Use a standalone exact: \"text\" requirement for deterministic equality. Review AI scores against a small human-reviewed set before using them as a release gate.",
                systemImage: "person.2"
            )
            .font(.caption).foregroundStyle(.secondary)
        } label: {
            Text("How scoring works").contentShape(Rectangle()).onTapGesture { showsScoringGuide.toggle() }
        }
    }

    @ViewBuilder
    private var templateActions: some View {
        ForEach(RubricTemplate.allCases) { template in
            Button(template.title) {
                guard !editingDisabled else { return }
                store.draftSuite.criteria = template.requirements
            }
        }
    }
}

private struct RubricScale: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Passing score: 3 or 4")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("4").bold(); Text("Every requirement is fully met; no material error.") }
                GridRow { Text("3").bold(); Text("Core requirements are met; only minor issues.") }
                GridRow { Text("2").bold(); Text("At least one requirement is materially unmet.") }
                GridRow { Text("1").bold(); Text("Fundamentally wrong, off-task, or violates a key constraint.") }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceInset()
        .accessibilityElement(children: .combine)
    }
}

private struct SharedReferenceFilesSection: View {
    @Bindable var store: EvaluationStore
    @State private var isDropTargeted = false

    private var imageCount: Int {
        store.draftSuite.attachments.count(where: { $0.kind == .image })
    }

    var body: some View {
        SuiteOptionalSection(
            title: "Reference files",
            detail: store.draftSuite.attachments.isEmpty ? "Optional · Add documents or images shared by every case" : "\(store.draftSuite.attachments.count) files shared by every case"
        ) {
            HStack {
                Label("\(store.draftSuite.attachments.count) file\(store.draftSuite.attachments.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
                Text("·")
                Text("Images \(imageCount) of 4")
                Spacer()
                Button("Add Files", systemImage: "plus") {
                    store.isImportingFiles = true
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if store.draftSuite.attachments.isEmpty {
                Button {
                    store.isImportingFiles = true
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                            .font(.title2)
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        Text(isDropTargeted ? "Drop to add files" : "Drop files here or choose files")
                            .font(.callout.weight(.medium))
                        Text("Text, JSON, CSV, PDF, and up to four images")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .overlay {
                    RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 5])
                        )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(store.draftSuite.attachments) { attachment in
                        AttachmentRow(
                            attachment: attachment,
                            remove: { store.removeAttachment(id: attachment.id) }
                        )
                        if attachment.id != store.draftSuite.attachments.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .workspaceInset()
            }
        }
        .disabled(store.isRunning || store.isProcessingFiles)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            store.importFiles(urls)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }
}

private struct AttachmentRow: View {
    let attachment: EvaluationAttachment
    let remove: () -> Void
    @State private var isConfirmingDeletion = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .lineLimit(1)
                Text(attachment.kind == .image ? "Image attachment" : "Extracted text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Remove \(attachment.name)", systemImage: "xmark", role: .destructive) {
                isConfirmingDeletion = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
        .confirmationDialog(
            "Remove \(attachment.name)?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Remove File", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will no longer be included in future runs.")
        }
    }
}

private struct ModelStatusBadge: View {
    let status: ModelStatus

    var body: some View {
        WorkspacePill(
            status.label,
            symbol: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            color: tint
        )
        .help(status.detail)
        .accessibilityLabel("Foundation model status")
        .accessibilityValue("\(status.label). \(status.detail)")
    }

    private var tint: Color { status.isAvailable ? WorkspaceStyle.success : WorkspaceStyle.warning }
}
