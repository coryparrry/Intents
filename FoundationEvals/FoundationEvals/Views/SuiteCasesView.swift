import SwiftUI

struct SuiteCasesView: View {
    @Bindable var store: EvaluationStore
    @Binding var selectedCaseID: UUID?
    @State private var isImportingCases = false
    @State private var search = ""
    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var visibleCases: [EvaluationCase] {
        store.draftSuite.cases.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.prompt.localizedCaseInsensitiveContains(search)
        }
    }
    private var selectedCaseIndex: Int? {
        guard let selectedCaseID, visibleCases.contains(where: { $0.id == selectedCaseID }) else { return nil }
        return store.draftSuite.cases.firstIndex(where: { $0.id == selectedCaseID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            caseList.frame(width: 250)
            if let index = selectedCaseIndex {
                let caseID = store.draftSuite.cases[index].id
                EvaluationCaseEditor(
                    evaluationCase: $store.draftSuite.cases[index],
                    prompt: Binding(get: { store.promptText(for: caseID) }, set: { store.editPrompt($0, for: caseID) }),
                    scoringMode: store.draftSuite.scoringMode,
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
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                WorkspaceEmptyState(symbol: "text.bubble", title: "Select a test case", detail: "Choose a case to edit its prompt and expected response.")
                    .frame(maxWidth: .infinity).workspaceSurface()
            }
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
                .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            VStack(spacing: 2) {
                ForEach(visibleCases) { evaluationCase in
                    let title = evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name
                    Button { selectedCaseID = evaluationCase.id } label: {
                        SuiteCaseRow(
                            title: title,
                            prompt: evaluationCase.prompt,
                            isSelected: selectedCaseID == evaluationCase.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("Select case \(evaluationCase.id)")
                    .accessibilityAddTraits(selectedCaseID == evaluationCase.id ? .isSelected : [])
                }
                if visibleCases.isEmpty {
                    Text("No matching cases")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                }
            }
            .padding(6)
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

    private func addCase() {
        let previousCount = store.draftSuite.cases.count
        search = ""
        store.addCase()
        if store.draftSuite.cases.count > previousCount { selectedCaseID = store.draftSuite.cases.last?.id }
    }
}

private struct EvaluationCaseEditor: View {
    @Binding var evaluationCase: EvaluationCase
    @Binding var prompt: String
    let scoringMode: ScoringMode
    let canDelete: Bool
    let isDisabled: Bool
    let duplicate: () -> Void
    let remove: () -> Void
    @State private var isConfirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Case name", text: $evaluationCase.name)
                    .font(.title2.weight(.semibold))
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

            VStack(alignment: .leading, spacing: 7) {
                Text("Prompt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                PromptTextEditor(
                    text: $prompt,
                    label: "Prompt for \(evaluationCase.name.isEmpty ? "untitled case" : evaluationCase.name)"
                )
                    .id(evaluationCase.id)
                    .workspaceTextWell(minHeight: 170)
                DisclosureGroup("Writing tools") {
                    PromptQuickActionsSection(prompt: $prompt, isDisabled: isDisabled)
                        .id(evaluationCase.id).padding(.top, 8)
                }
                .disclosureGroupStyle(.automatic)
                .font(.caption).foregroundStyle(.secondary)
            }

            if scoringMode != .review {
                VStack(alignment: .leading, spacing: 7) {
                    Text(scoringMode.expectedLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $evaluationCase.expected)
                        .accessibilityLabel(scoringMode.expectedLabel)
                        .accessibilityIdentifier("Scoring expected text")
                        .font(.body)
                        .workspaceTextWell(minHeight: 90)
                    Text(scoringMode.expectedHelp).font(.caption).foregroundStyle(.secondary)
                }
            }
            SuiteOptionalSection(title: "Field checks", detail: "\(evaluationCase.fieldAssertions?.count ?? 0) checks for structured responses", symbol: "checklist") {
                FieldAssertionsEditor(assertions: $evaluationCase.fieldAssertions, scoringMode: scoringMode)
            }
            ConversationConfigurationEditor(
                configuration: $evaluationCase.conversation,
                isDisabled: isDisabled
            )

        }
        .padding(24)
        .workspaceSurface()
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

private struct SuiteCaseRow: View {
    let title: String
    let prompt: String
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(prompt.isEmpty ? "Add a prompt…" : prompt)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(background, in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 9)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        return isHovering ? Color.primary.opacity(0.04) : .clear
    }
}
