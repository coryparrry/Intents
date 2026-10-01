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
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("TEST CASES").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    Text(store.draftSuite.cases.count.formatted()).font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Find a case", text: $search).textFieldStyle(.plain).font(.caption)
                        .accessibilityIdentifier("Search cases")
                }
                .padding(9).background(WorkspaceStyle.surface, in: .rect(cornerRadius: 8))
                VStack(spacing: 5) {
                    ForEach(visibleCases) { evaluationCase in
                        Button { selectedCaseID = evaluationCase.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name)
                                    .font(.callout.weight(.medium)).lineLimit(2)
                                    .foregroundStyle(selectedCaseID == evaluationCase.id ? Color.accentColor : .primary)
                                Text(evaluationCase.prompt.isEmpty ? "Add a prompt…" : evaluationCase.prompt)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(selectedCaseID == evaluationCase.id ? Color.accentColor.opacity(0.08) : .clear,
                                        in: .rect(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name)
                        .accessibilityIdentifier("Select case \(evaluationCase.id)")
                        .accessibilityAddTraits(selectedCaseID == evaluationCase.id ? .isSelected : [])
                    }
                    if visibleCases.isEmpty {
                        Text("No matching cases").font(.caption).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                }
                Button("Add Case", systemImage: "plus", action: addCase)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).disabled(isBusy)
                Button("Import Cases", systemImage: "square.and.arrow.down") { isImportingCases = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(isBusy)
            }
            .frame(width: 190)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Case name", text: $evaluationCase.name)
                    .font(.title3.weight(.semibold))
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
                    .frame(minHeight: 170)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    }
                DisclosureGroup("Writing tools") {
                    PromptQuickActionsSection(prompt: $prompt, isDisabled: isDisabled)
                        .id(evaluationCase.id).padding(.top, 8)
                }
                .disclosureGroupStyle(.automatic)
                .font(.caption).foregroundStyle(.secondary)
            }

            if scoringMode != .review {
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 7) {
                    Text(scoringMode.expectedLabel).font(.callout.weight(.semibold))
                    TextEditor(text: $evaluationCase.expected)
                        .accessibilityLabel(scoringMode.expectedLabel)
                        .accessibilityIdentifier("Scoring expected text")
                        .font(.body).frame(minHeight: 90).padding(8)
                        .background(WorkspaceStyle.canvas, in: .rect(cornerRadius: 8))
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
        .padding(22)
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
