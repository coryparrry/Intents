import SwiftUI

struct SuiteCasesView: View {
    @Bindable var store: EvaluationStore
    @Binding var selectedCaseID: UUID?
    @State private var isImportingCases = false
    @State private var search = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var visibleCases: [EvaluationCase] {
        store.draftSuite.cases.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.prompt.localizedCaseInsensitiveContains(search)
        }
    }
    private var latestRun: EvaluationRun? { store.runs.first }

    private var selectedCaseIndex: Int? {
        guard let selectedCaseID, visibleCases.contains(where: { $0.id == selectedCaseID }) else { return nil }
        return store.draftSuite.cases.firstIndex(where: { $0.id == selectedCaseID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            caseList
                .frame(width: 272)
                .frame(maxHeight: .infinity)
            ZStack(alignment: .topLeading) {
                Group {
                    if let index = selectedCaseIndex {
                        let caseID = store.draftSuite.cases[index].id
                        ScrollView {
                            EvaluationCaseEditor(
                                evaluationCase: $store.draftSuite.cases[index],
                                prompt: Binding(get: { store.promptText(for: caseID) }, set: { store.editPrompt($0, for: caseID) }),
                                scoringMode: store.draftSuite.scoringMode,
                                latestRun: latestRun,
                                verdict: verdict(for: caseID),
                                openRun: { store.selection = .run($0) },
                                canDelete: store.draftSuite.cases.count > 1,
                                isDisabled: isBusy,
                                duplicate: {
                                    let previousCount = store.draftSuite.cases.count
                                    store.duplicateCase(id: caseID)
                                    if store.draftSuite.cases.count > previousCount { selectedCaseID = store.draftSuite.cases[index + 1].id }
                                },
                                remove: {
                                    store.removeCase(id: caseID)
                                    selectedCaseID = store.draftSuite.cases.first?.id
                                }
                            )
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(caseID) // Each case opens at the top of the editor.
                        .accessibilityIdentifier("Case editor scroll")
                    } else {
                        WorkspaceEmptyState(symbol: "text.bubble", title: "Select a test case", detail: "Choose a case to edit its prompt and expected response.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .workspacePageTransition(value: selectedCaseID)
            .workspaceSurface()
        }
        .onChange(of: search) { _, _ in
            if !visibleCases.contains(where: { $0.id == selectedCaseID }) {
                selectedCaseID = visibleCases.first?.id
            }
        }
        .onChange(of: store.draftSuite.cases) { _, _ in
            if let selectedCaseID, !visibleCases.contains(where: { $0.id == selectedCaseID }) {
                search = ""
            }
        }
        .sheet(isPresented: $isImportingCases) { CaseImportView(store: store) }
    }

    private var caseList: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePanelHeader("Cases", count: store.draftSuite.cases.count)
            WorkspaceSearchField(prompt: "Find a case", text: $search, identifier: "Search cases")
                .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(visibleCases.enumerated()), id: \.element.id) { entry in
                            let evaluationCase = entry.element
                            let title = evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name
                            let verdict = verdict(for: evaluationCase.id)
                            Button { selectedCaseID = evaluationCase.id } label: {
                                SuiteCaseRow(
                                    title: title,
                                    prompt: evaluationCase.prompt,
                                    mark: verdict.mark,
                                    isSelected: selectedCaseID == evaluationCase.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(caseAccessibilityLabel(title: title, prompt: evaluationCase.prompt, position: entry.offset + 1))
                            .accessibilityValue(verdict.title)
                            .help(verdict.title)
                            .accessibilityIdentifier("Select case \(evaluationCase.id)")
                            .accessibilityAddTraits(selectedCaseID == evaluationCase.id ? .isSelected : [])
                            .id(evaluationCase.id)
                        }
                        if visibleCases.isEmpty {
                            Text("No matching cases")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 22)
                        }
                    }
                    .padding(6)
                }
                // Keep the selected case visible, such as one just added at the end of a long list.
                .onChange(of: selectedCaseID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button("Add Case", systemImage: "plus", action: addCase)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .fontWeight(.medium)
                    .disabled(isBusy)
                Spacer()
                Button("Import Cases", systemImage: "square.and.arrow.down") { isImportingCases = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Import cases from a file")
                    .disabled(isBusy)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .workspaceSurface()
    }

    private func verdict(for caseID: UUID) -> CaseVerdict {
        CaseVerdict(run: latestRun, caseID: caseID, currentRevision: store.suiteRevision,
                    hasDraft: store.draftSuite != store.suite)
    }

    private func caseAccessibilityLabel(title: String, prompt: String, position: Int) -> String {
        let excerpt = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return excerpt.isEmpty
            ? "Case \(position): \(title)"
            : "Case \(position): \(title). \(String(excerpt.prefix(80)))"
    }

    private func addCase() {
        let previousCount = store.draftSuite.cases.count
        search = ""
        store.addCase()
        if store.draftSuite.cases.count > previousCount { selectedCaseID = store.draftSuite.cases.last?.id }
    }
}

/// The latest run's outcome for one case, across its repetitions.
struct CaseVerdict {
    let results: [EvaluationSampleResult]
    let isOutOfDate: Bool
    let isIncomplete: Bool

    init(run: EvaluationRun?, caseID: UUID, currentRevision: String? = nil, hasDraft: Bool = false) {
        let caseResults = run?.effectiveResults.filter { $0.caseID == caseID } ?? []
        results = caseResults
        isOutOfDate = run != nil && (hasDraft || currentRevision.map { $0 != run?.suiteRevision } == true)
        isIncomplete = run.map { $0.cancelled || $0.stoppedEarly || caseResults.count < $0.repetitions } ?? false
    }

    var mark: WorkspaceStatusMark.State {
        if results.isEmpty { return .idle }
        if isOutOfDate || isIncomplete { return .attention }
        if results.contains(where: { $0.status == .failed }) { return .failed }
        if results.contains(where: { $0.status == .error || $0.errorMessage != nil }) { return .attention }
        if results.allSatisfy({ $0.status == .passed }) { return .passed }
        return .idle
    }

    var title: String {
        if results.isEmpty { return "Not run" }
        if isOutOfDate { return "Out of date" }
        if isIncomplete { return "Incomplete" }
        return switch mark {
        case .passed: results.count > 1 ? "Passed all \(results.count) attempts" : "Passed"
        case .failed:
            results.count > 1
                ? "Failed \(results.count(where: { $0.status == .failed })) of \(results.count) attempts"
                : "Failed"
        case .attention: "Needs review"
        case .idle, .running: "Not scored"
        }
    }
}

/// A case laid out as the exchange it tests: what you ask, what you expect,
/// and what the model actually said in the latest run.
private struct EvaluationCaseEditor: View {
    @Binding var evaluationCase: EvaluationCase
    @Binding var prompt: String
    let scoringMode: ScoringMode
    let latestRun: EvaluationRun?
    let verdict: CaseVerdict
    let openRun: (UUID) -> Void
    let canDelete: Bool
    let isDisabled: Bool
    let duplicate: () -> Void
    let remove: () -> Void
    @State private var isConfirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                TextField("Case name", text: $evaluationCase.name)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Case name")
                Spacer()
                Menu("Case actions", systemImage: "ellipsis") {
                    caseActions
                }
                .accessibilityActions { caseActions }
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
                .help("Case actions")
            }

            CaseField("Prompt") {
                PromptTextEditor(
                    text: $prompt,
                    label: "Prompt for \(evaluationCase.name.isEmpty ? "untitled case" : evaluationCase.name)"
                )
                .id(evaluationCase.id)
                .workspaceTextWell(minHeight: 96)
            }

            if scoringMode != .review {
                CaseField("Expected answer", detail: scoringMode.expectedLabel) {
                    TextEditor(text: $evaluationCase.expected)
                        .accessibilityLabel(scoringMode.expectedLabel)
                        .accessibilityIdentifier("Scoring expected text")
                        .font(.body)
                        .workspaceTextWell(minHeight: 64)
                    Text(scoringMode.expectedHelp).font(.caption).foregroundStyle(.secondary)
                }
            }

            LatestResponsePanel(verdict: verdict, run: latestRun, openRun: openRun)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    PromptQuickActionsSection(prompt: $prompt, isDisabled: isDisabled)
                        .id(evaluationCase.id)
                    SuiteOptionalSection(title: "Field checks", detail: "\(evaluationCase.fieldAssertions?.count ?? 0) checks for structured responses") {
                        FieldAssertionsEditor(assertions: $evaluationCase.fieldAssertions, scoringMode: scoringMode)
                    }
                    ConversationConfigurationEditor(
                        configuration: $evaluationCase.conversation,
                        isDisabled: isDisabled
                    )
                }
                .padding(.top, 12)
            } label: {
                Text("More options")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(.automatic)
        }
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

/// A labelled part of a case, such as its prompt or the answer you expect back.
private struct CaseField<Content: View, Accessory: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let detail, !detail.isEmpty, detail != title {
                    Text(detail).font(.subheadline).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                accessory
            }
            .accessibilityElement(children: .combine)
            content
        }
    }
}

/// What the model said for this case in the latest run, with its verdict and reasoning.
private struct LatestResponsePanel: View {
    let verdict: CaseVerdict
    let run: EvaluationRun?
    let openRun: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sample: EvaluationSampleResult? {
        verdict.results.first { $0.status == .failed }
            ?? verdict.results.first { $0.status == .error || $0.errorMessage != nil }
            ?? verdict.results.first
    }

    var body: some View {
        CaseField("Latest response", detail: run.map { $0.startedAt.formatted(.relative(presentation: .named)) }) {
            if let run, sample != nil {
                Button("Open Run") { openRun(run.id) }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        } content: {
            if let sample {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        WorkspaceStatusMark(state: verdict.mark, size: 18)
                        Text(verdict.title).font(.callout.weight(.semibold))
                        if let score = sample.score {
                            Text("Score \(score)/4").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if verdict.isOutOfDate {
                        Text("This response belongs to an earlier version. Run the suite again to check your changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    WorkspaceExpandableText(
                        sample.errorMessage.map(AttributedString.init) ?? .workspaceMarkdown(sample.response),
                        lineLimit: 8, label: "response"
                    )
                    .font(.body).lineSpacing(2)
                    if let rationale = sample.rationale, !rationale.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sample.status == .passed ? "Why it passed" : "Why it was marked this way")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            WorkspaceExpandableText(AttributedString(rationale), lineLimit: 3, label: "reasoning")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .workspaceInset(radius: 12)
                .transition(.blurReplace)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(.tertiary)
                    Text(run == nil ? "Run the suite to see the model’s answer here." : "This case wasn’t part of the latest run.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .workspaceInset(radius: 12)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: sample?.id)
    }
}

private struct SuiteCaseRow: View {
    let title: String
    let prompt: String
    let mark: WorkspaceStatusMark.State
    let isSelected: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkspaceStatusMark(state: mark, size: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(prompt.isEmpty ? "Add a prompt…" : prompt)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(background, in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.08) }
        return isHovering ? Color.primary.opacity(0.04) : .clear
    }
}
