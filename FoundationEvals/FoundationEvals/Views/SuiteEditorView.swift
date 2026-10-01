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
    case instructions
    case scoring
    case model
    case features

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .cases: "Cases"
        case .instructions: "Instructions"
        case .scoring: "Scoring"
        case .model: "Model"
        case .features: "Features"
        }
    }
}

struct SuiteEditorView: View {
    @Bindable var store: EvaluationStore
    @State private var selectedPage = SuiteEditorPage.cases
    @State private var selectedCaseID: UUID?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    SuiteOverviewHeader(store: store)
                    SuiteDashboardCards(store: store)
                    RunReadinessPanel(store: store)
                    if let response = store.liveResponse, store.isRunning {
                        LiveResponseSection(response: response)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)

                selectedPageContent
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        .focusable()
        .focusEffectDisabled()
        .focused($isEditorFocused)
        .defaultFocus($isEditorFocused, true)
        .background {
            SuiteEditorSelectionObserver(
                store: store, selectedPage: $selectedPage, selectedCaseID: $selectedCaseID
            )
        }
        .navigationTitle("Foundation Evals")
        .background(Color.primary.opacity(0.025))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Editor page", selection: $selectedPage) {
                    ForEach(SuiteEditorPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 500)
                .accessibilityIdentifier("Editor page")
            }
            RunToolbarContent(store: store)
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
            CasesSection(store: store, selectedCaseID: $selectedCaseID)
        case .instructions:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 350), alignment: .top)],
                alignment: .leading,
                spacing: 18
            ) {
                ModelInstructionsSection(store: store)
                SharedReferenceFilesSection(store: store)
            }
        case .scoring:
            ScoringSection(store: store, selectedCaseID: $selectedCaseID)
        case .model:
            ModelControlsSection(store: store)
        case .features:
            FeatureControlsView(store: store)
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
    @Bindable var store: EvaluationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                TextField("Suite name", text: $store.draftSuite.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityLabel("Suite name")

                Spacer(minLength: 12)
                ModelStatusBadge(status: store.modelStatus)
            }

            HStack(spacing: 16) {
                LabeledContent("Suite version") {
                    TextField("v1", text: $store.draftSuite.version)
                        .frame(width: 110)
                        .multilineTextAlignment(.trailing)
                }
                .fixedSize()

                Divider()
                    .frame(height: 18)

                Label(
                    store.draftSaveFailed ? "Changes could not be saved"
                        : store.isDraftSavePending ? "Saving changes…"
                        : store.draftSuite != store.suite ? "Draft saved on this Mac"
                        : "Saved automatically on this Mac",
                    systemImage: store.draftSaveFailed ? "exclamationmark.triangle" : "lock.laptopcomputer"
                )
                    .font(.callout)
                    .foregroundStyle(store.draftSaveFailed ? Color.orange : Color.secondary)
            }
        }
        .disabled(store.isRunning || store.isProcessingFiles)
    }
}

private struct RunReadinessPanel: View {
    @Bindable var store: EvaluationStore

    private var responseLabel: String {
        "\(store.plannedSampleCount) response\(store.plannedSampleCount == 1 ? "" : "s")"
    }

    var body: some View {
        let blocker = store.runBlocker
        HStack(spacing: 14) {
            Image(systemName: statusSymbol(blocker: blocker))
                .font(.title2)
                .foregroundStyle(statusColor(blocker: blocker))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle(blocker: blocker))
                    .font(.headline)
                Text(statusDetail(blocker: blocker))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            if store.isRunning {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(store.completedSamples) of \(store.totalSamples) responses")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(
                        value: Double(store.completedSamples),
                        total: Double(max(store.totalSamples, 1))
                    )
                    .frame(width: 150)
                }
                Button("Cancel", role: .cancel) { store.cancelRun() }
            } else {
                Button("Run \(responseLabel)", systemImage: "play.fill") {
                    store.startRun()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(blocker != nil || store.isProcessingFiles)
                .accessibilityIdentifier("Run evaluation")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12))
        }
        .accessibilityElement(children: .contain)
    }

    private func statusTitle(blocker: String?) -> LocalizedStringResource {
        if store.isRunning { return "Evaluation in progress" }
        if store.isProcessingFiles { return "Importing reference files" }
        return blocker == nil ? "Ready to run" : "Needs attention"
    }

    private func statusDetail(blocker: String?) -> String {
        if store.isRunning {
            return "You can review the suite while the current run finishes."
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
        if store.isProcessingFiles { return "arrow.down.doc.fill" }
        return blocker == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(blocker: String?) -> Color {
        if store.isRunning || store.isProcessingFiles { return .accentColor }
        return blocker == nil ? .secondary : .orange
    }
}

private struct RunToolbarContent: ToolbarContent {
    @Bindable var store: EvaluationStore

    var body: some ToolbarContent {
        let blocker = store.runBlocker
        ToolbarItemGroup {
            if store.isRunning {
                RunToolbarProgress(completed: store.completedSamples, total: store.totalSamples)
                Button("Cancel", role: .cancel) { store.cancelRun() }
            } else {
                if store.isProcessingFiles {
                    ProgressView("Importing files")
                        .controlSize(.small)
                }
                Button("Run", systemImage: "play.fill") { store.startRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(blocker != nil || store.isProcessingFiles)
                    .help(blocker ?? "Run the current evaluation suite")
            }
        }
    }
}

private struct ModelInstructionsSection: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        EditorSection(
            "Model instructions",
            systemImage: "text.quote",
            description: "Shared guidance applied to every test case."
        ) {
            TextEditor(text: $store.draftSuite.instructions)
                .accessibilityLabel("Model instructions")
                .font(.body)
                .frame(minHeight: 118)
                .padding(8)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }

            Text("Each repetition starts with a fresh model session, so cases cannot influence one another.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(store.isRunning || store.isProcessingFiles)
    }
}

private struct ScoringSection: View {
    @Bindable var store: EvaluationStore
    @Binding var selectedCaseID: UUID?

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

                if let selectedCaseIndex {
                    Divider()

                    HStack {
                        Text("Scoring target")
                            .font(.headline)
                        Spacer()
                        Picker("Scoring case", selection: $selectedCaseID) {
                            ForEach(store.draftSuite.cases) { evaluationCase in
                                Text(evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name)
                                    .tag(Optional(evaluationCase.id))
                            }
                        }
                        .accessibilitySelectionActions(
                            store.draftSuite.cases.map { Optional($0.id) },
                            selection: $selectedCaseID,
                            title: { caseID in
                                guard let caseID,
                                      let evaluationCase = store.draftSuite.cases.first(where: { $0.id == caseID }) else {
                                    return "Untitled case"
                                }
                                return evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name
                            }
                        )
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .accessibilityIdentifier("Scoring case selector")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(store.draftSuite.cases[selectedCaseIndex].prompt.isEmpty
                             ? "No prompt entered yet."
                             : store.draftSuite.cases[selectedCaseIndex].prompt)
                            .font(.callout)
                            .foregroundStyle(store.draftSuite.cases[selectedCaseIndex].prompt.isEmpty ? .secondary : .primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                    }

                    if store.draftSuite.scoringMode != .review {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.draftSuite.scoringMode.expectedLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $store.draftSuite.cases[selectedCaseIndex].expected)
                                .accessibilityLabel(
                                    "\(store.draftSuite.scoringMode.expectedLabel) for \(store.draftSuite.cases[selectedCaseIndex].name.isEmpty ? "Untitled case" : store.draftSuite.cases[selectedCaseIndex].name)"
                                )
                                .accessibilityIdentifier("Scoring expected text")
                                .font(store.draftSuite.scoringMode == .modelJudge ? .body : .body.monospaced())
                                .frame(minHeight: 72)
                                .padding(8)
                                .background(.background, in: .rect(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2))
                                }
                            Text(store.draftSuite.scoringMode.expectedHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    FieldAssertionsEditor(
                        assertions: $store.draftSuite.cases[selectedCaseIndex].fieldAssertions,
                        scoringMode: store.draftSuite.scoringMode
                    )
                }

                if store.draftSuite.scoringMode == .modelJudge {
                    ModelRubricEditor(store: store)
                }
            }
            .disabled(store.isRunning || store.isProcessingFiles)
        }
    }

    private var selectedCaseIndex: Int? {
        guard let selectedCaseID else { return nil }
        return store.draftSuite.cases.firstIndex(where: { $0.id == selectedCaseID })
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
            .frame(minHeight: 112)
            .padding(8)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            }

        Label(
            "\(store.draftSuite.rubricCriteria.count) of 4 requirements",
            systemImage: isValid ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(isValid ? Color.secondary : Color.orange)

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
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

private struct CasesSection: View {
    @Bindable var store: EvaluationStore
    @Binding var selectedCaseID: UUID?

    var body: some View {
        EditorSection(
            "Test cases",
            systemImage: "list.bullet.rectangle",
            description: "Each case gets its own session. Optional restored history and setup turns run before the scored prompt."
        ) {
            HStack(spacing: 12) {
                Text("\(store.draftSuite.cases.count) case\(store.draftSuite.cases.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Editing case", selection: $selectedCaseID) {
                    ForEach(store.draftSuite.cases) { evaluationCase in
                        Text(evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name)
                            .tag(Optional(evaluationCase.id))
                    }
                }
                .accessibilitySelectionActions(
                    store.draftSuite.cases.map { Optional($0.id) },
                    selection: $selectedCaseID,
                    title: { caseID in
                        guard let caseID,
                              let evaluationCase = store.draftSuite.cases.first(where: { $0.id == caseID }) else {
                            return "Untitled case"
                        }
                        return evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name
                    }
                )
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityIdentifier("Case selector")

                Spacer()
                Button("Add Case", systemImage: "plus") {
                    let previousCount = store.draftSuite.cases.count
                    store.addCase()
                    if store.draftSuite.cases.count > previousCount {
                        selectedCaseID = store.draftSuite.cases.last?.id
                    }
                }
                    .disabled(store.isRunning || store.isProcessingFiles)
            }

            CaseOverviewTable(cases: store.draftSuite.cases, selection: $selectedCaseID)

            if let selectedCaseIndex {
                let caseID = store.draftSuite.cases[selectedCaseIndex].id
                EvaluationCaseEditor(
                    evaluationCase: $store.draftSuite.cases[selectedCaseIndex],
                    prompt: Binding(
                        get: { store.promptText(for: caseID) },
                        set: { store.editPrompt($0, for: caseID) }
                    ),
                    canDelete: store.draftSuite.cases.count > 1,
                    isDisabled: store.isRunning || store.isProcessingFiles,
                    duplicate: {
                        let id = store.draftSuite.cases[selectedCaseIndex].id
                        let previousCount = store.draftSuite.cases.count
                        store.duplicateCase(id: id)
                        if store.draftSuite.cases.count > previousCount {
                            selectedCaseID = store.draftSuite.cases[selectedCaseIndex + 1].id
                        }
                    },
                    remove: {
                        store.removeCase(id: store.draftSuite.cases[selectedCaseIndex].id)
                        selectedCaseID = store.draftSuite.cases.first?.id
                    }
                )
            }
        }
    }

    private var selectedCaseIndex: Int? {
        guard let selectedCaseID else { return nil }
        return store.draftSuite.cases.firstIndex(where: { $0.id == selectedCaseID })
    }

}

private struct EvaluationCaseEditor: View {
    @Binding var evaluationCase: EvaluationCase
    @Binding var prompt: String
    let canDelete: Bool
    let isDisabled: Bool
    let duplicate: () -> Void
    let remove: () -> Void
    @State private var isConfirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Case name", text: $evaluationCase.name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Case name")

                Spacer()

                Menu("Case actions", systemImage: "ellipsis.circle") {
                    caseActions
                }
                .accessibilityActions { caseActions }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("Case actions")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Prompt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PromptTextEditor(
                    text: $prompt,
                    label: "Prompt for \(evaluationCase.name.isEmpty ? "untitled case" : evaluationCase.name)"
                )
                    .id(evaluationCase.id)
                    .frame(height: 140)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    }
            }

            ConversationConfigurationEditor(
                configuration: $evaluationCase.conversation,
                isDisabled: isDisabled
            )

        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 11))
        .disabled(isDisabled)
        .confirmationDialog(
            "Delete \(evaluationCase.name.isEmpty ? "this case" : evaluationCase.name)?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Case", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its prompt and scoring value from the suite.")
        }
    }

    @ViewBuilder
    private var caseActions: some View {
        Button("Duplicate Case", systemImage: "plus.square.on.square") {
            guard !isDisabled else { return }
            duplicate()
        }
        Divider()
        Button("Delete Case", systemImage: "trash", role: .destructive) {
            guard !isDisabled, canDelete else { return }
            isConfirmingDeletion = true
        }
        .disabled(!canDelete)
    }
}

private struct SharedReferenceFilesSection: View {
    @Bindable var store: EvaluationStore
    @State private var isDropTargeted = false

    private var imageCount: Int {
        store.draftSuite.attachments.count(where: { $0.kind == .image })
    }

    var body: some View {
        EditorSection(
            "Shared reference files",
            systemImage: "paperclip",
            description: "Applied to every case. Text is extracted; images are attached directly."
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
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
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
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 9))
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
        .foregroundStyle(status.isAvailable ? Color.secondary : Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: .capsule)
        .help(status.detail)
        .accessibilityLabel("Foundation model status")
        .accessibilityValue("\(status.label). \(status.detail)")
    }
}

struct EditorSection<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let sectionDescription: LocalizedStringResource
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        description: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        sectionDescription = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(sectionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14))
        }
    }
}
