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

private enum SuiteEditorPage: String, CaseIterable, Identifiable {
    case cases
    case results
    case compare
    case configure

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .cases: "Cases"
        case .results: "Results"
        case .compare: "Compare"
        case .configure: "Setup"
        }
    }
}

enum SuiteCasePickerSelection {
    static func resolved(_ selection: UUID?, in cases: [EvaluationCase]) -> UUID? {
        guard let selection, cases.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }

    static func resolvedOrFirst(_ selection: UUID?, in cases: [EvaluationCase]) -> UUID? {
        resolved(selection, in: cases) ?? cases.first?.id
    }
}

struct SuiteEditorView: View {
    @Environment(DeveloperRunnerStore.self) private var runners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: EvaluationStore
    @State private var selectedPage = SuiteEditorPage.cases
    @State private var configurationPage = SuiteSetupPage.instructions
    @State private var selectedCaseID: UUID?
    @State private var showsRunDetails = false
    @State private var showsDevices = false
    @State private var runError: String?
    @FocusState private var isEditorFocused: Bool

    private var isRunActive: Bool { store.isRunning || runners.executingRunID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SuiteOverviewHeader(store: store)
                if let migrationNotice = store.migrationNotice {
                    Label(migrationNotice, systemImage: "tray.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workspaceInset()
                }
                if isRunActive {
                    SuiteRunActivityBanner(store: store, runners: runners)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let response = store.liveResponse, store.isRunning {
                    LiveResponseSection(response: response)
                }
                selectedPageContent
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isRunActive)
            .workspacePage()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($isEditorFocused)
        .defaultFocus($isEditorFocused, true)
        .background {
            SuiteEditorSelectionObserver(
                store: store, selectedPage: $selectedPage, selectedCaseID: $selectedCaseID
            )
        }
        .navigationTitle(store.draftSuite.name)
        .background(WorkspaceStyle.canvas)
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

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .cases:
            SuiteCasesView(store: store, selectedCaseID: $selectedCaseID)
        case .results:
            SuiteResultsView(store: store)
        case .compare:
            SuiteCompareView(store: store)
        case .configure:
            WorkspacePaneLayout(heading: "Suite setup", selection: $configurationPage) {
                configurationContent
                    .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
            }
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
        switch configurationPage {
        case .instructions:
            ModelInstructionsSection(store: store)
            SharedReferenceFilesSection(store: store)
        case .scoring:
            ScoringSection(store: store)
            if store.draftSuite.scoringMode == .modelJudge {
                JudgeConfigurationSection(store: store)
            }
            SuiteOptionalSection(title: "Release requirements", detail: "Pass thresholds, baseline and latency limits", symbol: "checkmark.shield") {
                ReleasePolicySection(store: store)
            }
        case .model:
            ModelControlsSection(store: store)
        case .tools:
            FeatureControlsView(store: store, selectedPage: .tools)
        case .output:
            FeatureControlsView(store: store, selectedPage: .output)
        case .profile:
            FeatureControlsView(store: store, selectedPage: .profile)
        case .performance:
            FeatureControlsView(store: store, selectedPage: .performance)
        }
    }
}

private struct SuiteEditorSelectionObserver: View {
    let store: EvaluationStore
    @Binding var selectedPage: SuiteEditorPage
    @Binding var selectedCaseID: UUID?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { selectFirstCaseIfNeeded() }
            .onChange(of: store.draftSuite.id) { _, _ in selectedPage = .cases }
            .onChange(of: store.draftSuite.cases.map(\.id)) { _, _ in
                selectFirstCaseIfNeeded()
            }
    }

    private func selectFirstCaseIfNeeded() {
        if selectedCaseID.flatMap({ id in store.draftSuite.cases.firstIndex(where: { $0.id == id }) }) == nil {
            selectedCaseID = store.draftSuite.cases.first?.id
        }
    }

}

private struct SuiteOverviewHeader: View {
    @Environment(DeveloperRunnerStore.self) private var runners
    @Bindable var store: EvaluationStore
    @State private var showsDetails = false
    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var caseCount: Int { store.draftSuite.cases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                WorkspaceIconTile(symbol: "checklist", tint: .accentColor, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Suite name", text: $store.draftSuite.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .bold)).tracking(-0.3)
                        .accessibilityLabel("Suite name").disabled(isBusy)
                    HStack(spacing: 16) {
                        WorkspaceMetaLabel("\(caseCount) case\(caseCount == 1 ? "" : "s")", symbol: "list.bullet.rectangle")
                        WorkspaceMetaLabel(store.draftSuite.scoringMode.title, symbol: "checkmark.seal")
                        WorkspaceMetaLabel(
                            runners.selectedRunner?.identity.displayName ?? store.draftSuite.modelConfiguration.provider.title,
                            symbol: "cpu"
                        )
                        saveStatus
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button("Suite details", systemImage: "info.circle") { showsDetails = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help("Version and model availability")
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details }
            }
            if let blocker = runners.runIssue(for: store), !store.isRunning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkspaceStyle.warning)
                    Text(blocker).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceStyle.warning.opacity(0.1), in: .rect(cornerRadius: WorkspaceStyle.controlRadius))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var saveStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: store.draftSaveFailed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .imageScale(.small)
                .foregroundStyle(store.draftSaveFailed ? WorkspaceStyle.warning : Color.secondary.opacity(0.7))
            Text(store.draftSaveFailed ? "Changes could not be saved"
                 : store.isDraftSavePending ? "Saving changes…"
                 : store.draftSuite != store.suite ? "Draft saved on this Mac"
                 : "Saved automatically on this Mac")
                .foregroundStyle(store.draftSaveFailed ? WorkspaceStyle.warning : .secondary)
                .lineLimit(1)
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

    private func statusTitle(blocker: String?) -> LocalizedStringResource {
        if store.isRunning { return "Evaluation in progress" }
        if store.hasUnsavedCompletedRun { return "Run could not be saved" }
        if store.isProcessingFiles { return "Importing reference files" }
        return blocker == nil ? "Ready to run" : "Needs attention"
    }

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

    private func statusSymbol(blocker: String?) -> String {
        if store.isRunning { return "waveform.circle.fill" }
        if store.hasUnsavedCompletedRun { return "exclamationmark.triangle.fill" }
        if store.isProcessingFiles { return "arrow.down.doc.fill" }
        return blocker == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(blocker: String?) -> Color {
        if store.isRunning { return .accentColor }
        if store.hasUnsavedCompletedRun { return WorkspaceStyle.warning }
        if store.isProcessingFiles { return .accentColor }
        return blocker == nil ? WorkspaceStyle.success : WorkspaceStyle.warning
    }
}

private struct ModelInstructionsSection: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        EditorSection(
            "Model instructions",
            systemImage: "text.quote",
            description: "Tell the model how to respond across all cases."
        ) {
            TextEditor(text: $store.draftSuite.instructions)
                .accessibilityLabel("Model instructions")
                .font(.body)
                .workspaceTextWell(minHeight: 190)

        }
        .disabled(store.isRunning || store.isProcessingFiles)
    }
}

private struct ScoringSection: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        EditorSection(
            "Scoring and repetitions",
            systemImage: "checkmark.seal",
            description: "Choose how responses are judged and how many times each case runs."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Scoring method", selection: $store.draftSuite.scoringMode) {
                    ForEach(ScoringMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(store.draftSuite.scoringMode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Label(
                        "\(store.plannedSampleCount) response\(store.plannedSampleCount == 1 ? "" : "s") per run",
                        systemImage: "square.stack.3d.up"
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        "Repetitions: \(store.draftSuite.repetitions)",
                        value: $store.draftSuite.repetitions,
                        in: 1...5
                    )
                }

                Text("Set expected responses and field checks in each test case.")
                    .font(.caption).foregroundStyle(.secondary)

                if store.draftSuite.scoringMode == .modelJudge {
                    ModelRubricEditor(store: store)
                }
            }
            .disabled(store.isRunning || store.isProcessingFiles)
        }
    }

}

private struct ModelRubricEditor: View {
    @Bindable var store: EvaluationStore

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
            .accessibilityActions { templateActions }
        }

        TextEditor(text: $store.draftSuite.criteria)
            .accessibilityLabel("AI rubric requirements")
            .font(.body)
            .workspaceTextWell(minHeight: 112)

        Label(
            "\(store.draftSuite.rubricCriteria.count) of 4 requirements",
            systemImage: isValid ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(isValid ? Color.secondary : WorkspaceStyle.warning)

        RubricScale()

        Label(
            "A matching reference answer does not bypass the rubric. Use a standalone exact: \"text\" requirement for deterministic equality. Review AI scores against a small human-reviewed set before using them as a release gate.",
            systemImage: "person.2"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var templateActions: some View {
        ForEach(RubricTemplate.allCases) { template in
            Button(template.title) {
                guard !store.isRunning, !store.isProcessingFiles else { return }
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
            detail: store.draftSuite.attachments.isEmpty ? "Optional · Add documents or images shared by every case" : "\(store.draftSuite.attachments.count) files shared by every case",
            symbol: "paperclip"
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
        Label(
            status.label,
            systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: .capsule)
        .help(status.detail)
        .accessibilityLabel("Foundation model status")
        .accessibilityValue("\(status.label). \(status.detail)")
    }

    private var tint: Color { status.isAvailable ? WorkspaceStyle.success : WorkspaceStyle.warning }
}
