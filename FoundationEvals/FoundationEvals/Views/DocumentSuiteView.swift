import SwiftUI
import UniformTypeIdentifiers

struct DocumentSuiteView: View {
    @Bindable var store: EvaluationStore
    @Environment(\.dismiss) private var dismiss
    @State private var controller: EvaluationDocumentDraftController
    @State private var importing = false
    @State private var importingArchive = false
    @State private var confirmingDiscard = false
    @State private var selectedCaseID: UUID?
    @State private var rangeStart = ""
    @State private var rangeEnd = ""

    /// Restore the selected project draft and use the workspace recorder for completed document workflows.
    init(store: EvaluationStore) {
        self.store = store
        _controller = State(initialValue: EvaluationDocumentDraftController(
            directory: store.overviewStorageDirectory, projectID: store.selectedProjectID, telemetry: store.telemetry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suite from a document").font(.title2.weight(.semibold))
                    Text("Import → choose coverage → generate → review → create")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.draft != nil || controller.storageBlocked {
                    Button("Discard draft…", role: .destructive) { confirmingDiscard = true }.disabled(controller.isBusy)
                }
            }
            if controller.draft != nil { workspace } else { importPanel }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.callout).textSelection(.enabled)
            }
            if !controller.progress.isEmpty {
                HStack {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(controller.progress).font(.callout).foregroundStyle(.secondary)
                }.accessibilityLabel(controller.progress)
            }
            Divider()
            HStack {
                Button("Save and close") {
                    controller.cancel()
                    if controller.storageBlocked || controller.persist() { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if controller.isBusy { Button("Stop generation") { controller.cancel() } }
                Spacer()
                if let draft = controller.draft {
                    Text("\(draft.acceptedCases.count) accepted · \(draft.representedPassageIDs.count) of \(draft.selectedPassageIDs.count) selected passages represented")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create suite with \(draft.acceptedCases.count) \(draft.acceptedCases.count == 1 ? "case" : "cases")", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy || draft.acceptedCases.isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("Create document suite")
                }
            }
        }
        .padding(24).frame(width: 1040, height: 740)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            do {
                let file = try result.get()
                let range: ClosedRange<Int>?
                if rangeStart.isEmpty && rangeEnd.isEmpty { range = nil }
                else if let lower = Int(rangeStart), let upper = Int(rangeEnd), lower > 0, upper >= lower { range = lower...upper }
                else { throw EvaluationStoreError.invalidSuite("Enter a valid first and last page/passage, or leave both empty.") }
                controller.importFile(file, selection: range)
            } catch { controller.error = error.localizedDescription }
        }
        .confirmationDialog("Discard this saved draft and its source text?", isPresented: $confirmingDiscard) {
            Button("Discard draft", role: .destructive) { controller.discard(); selectedCaseID = nil }
        } message: { Text("Created suites and saved runs keep their own source evidence.") }
        .fileImporter(isPresented: $importingArchive, allowedContentTypes: [.json]) { result in
            do { controller.importArchive(try result.get()) }
            catch { controller.error = error.localizedDescription }
        }
        .onChange(of: controller.draft?.cases) { _, cases in
            if selectedCaseID == nil { selectedCaseID = cases?.first?.id }
            controller.persist()
        }
        .onAppear { selectedCaseID = controller.draft?.cases.first?.id }
        .onDisappear { controller.cancel() }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentUnavailableView("Start with a specification or product guide", systemImage: "doc.text.magnifyingglass",
                description: Text("One text-based PDF, Markdown, or UTF-8 text file. Drafting uses this Mac; semantic review sends extracted text to your selected judge after authorization. Scanned pages, diagrams, and complex tables are not interpreted."))
            HStack {
                Text("Optional range")
                TextField("First", text: $rangeStart).frame(width: 70)
                Text("to")
                TextField("Last", text: $rangeEnd).frame(width: 70)
                Text("PDF pages or blank-line-separated text passages").font(.caption).foregroundStyle(.secondary)
            }
            Text("Up to 5 MB, 200 PDF pages, and 128,000 selected characters. Leave the range empty to inspect the complete document within these limits.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose document…") { importing = true }.buttonStyle(.borderedProminent)
                .disabled(controller.isBusy || controller.storageBlocked)
                .accessibilityIdentifier("Choose source document")
            Button("Import saved document suite…") { importingArchive = true }
                .disabled(controller.isBusy || controller.storageBlocked)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { files, _ in
            guard files.count == 1, let file = files.first, !controller.isBusy, !controller.storageBlocked else { return false }
            controller.importFile(file, selection: nil)
            return true
        }
    }

    private var workspace: some View {
        HStack(alignment: .top, spacing: 18) {
            sourcePanel.frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Suite name", text: Binding(get: { controller.draft?.name ?? "" }, set: {
                    controller.draft?.name = $0; controller.persist()
                })).textFieldStyle(.roundedBorder).accessibilityLabel("Document suite name")
                if let draft = controller.draft, !draft.cases.isEmpty {
                    let acceptedIDs = Set(draft.acceptedCases.map(\.id))
                    Picker("Draft", selection: $selectedCaseID) {
                        Text("Choose a draft").tag(UUID?.none)
                        ForEach(draft.cases) { item in
                            Text("\(item.discarded ? "Discarded · " : acceptedIDs.contains(item.id) ? "Accepted · " : "")\(item.evaluationCase.name)")
                                .tag(Optional(item.id))
                        }
                    }
                    if let id = selectedCaseID, let index = draft.cases.firstIndex(where: { $0.id == id }) {
                        draftDetail(index: index)
                    } else {
                        ContentUnavailableView("Review a draft", systemImage: "checklist",
                            description: Text("Choose a question above to inspect its answer, criteria, and source evidence."))
                    }
                } else {
                    ContentUnavailableView("Choose coverage, then generate drafts", systemImage: "text.badge.plus",
                        description: Text("Every draft needs your source review before it becomes an evaluation case."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity)
    }

    private var semanticJudge: EvaluationJudgeConnection? {
        store.judgeConnections.first { $0.id == controller.draft?.semanticJudgeID }
    }

    private var semanticReviewSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Semantic judge", selection: Binding(get: { controller.draft?.semanticJudgeID }, set: {
                controller.draft?.semanticJudgeID = $0
                controller.draft?.semanticApprovalDigest = nil
                controller.persist()
            })) {
                Text("Choose a configured judge").tag(UUID?.none)
                ForEach(store.judgeConnections) { connection in Text(connection.name + " · " + connection.modelID).tag(Optional(connection.id)) }
            }
            if let judge = semanticJudge {
                Text("Each draft is checked against the complete extracted document by \(judge.modelID) at \(judge.baseURL). Rejected drafts are regenerated up to twice. Provider charges may apply.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("Document semantic judge disclosure")
                Toggle("Allow sending this document, draft answers, rubrics, and prior questions to this judge", isOn: Binding(
                    get: { controller.draft?.semanticApprovalDigest == judge.disclosureDigest },
                    set: { controller.draft?.semanticApprovalDigest = $0 ? judge.disclosureDigest : nil; controller.persist() }))
                    .font(.caption)
            } else {
                Text("Configure a judge in Settings → Judges, then select it here. Generation requires semantic review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(controller.isBusy)
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = controller.draft {
                Text(draft.source.name).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(draft.source.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(draft.source.passages) { passage in
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(passage.location + " · " + passage.id, isOn: Binding(
                                    get: { controller.draft?.selectedPassageIDs.contains(passage.id) ?? false },
                                    set: { selected in
                                        if selected { controller.draft?.selectedPassageIDs.insert(passage.id) }
                                        else { controller.draft?.selectedPassageIDs.remove(passage.id) }
                                        controller.persist()
                                    }))
                                    .disabled(controller.isBusy || !draft.cases.isEmpty || !draft.completedBatchIDs.isEmpty || !draft.issues.isEmpty)
                                DisclosureGroup("Inspect text") { Text(passage.text).font(.callout).textSelection(.enabled) }
                                Text(draft.coverageLabel(for: passage.id)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !draft.issues.isEmpty {
                            Text("Omitted or failed attempts").font(.headline)
                            ForEach(draft.issues.keys.sorted(), id: \.self) { key in
                                Text(draft.issues[key] ?? "").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                semanticReviewSettings
                Picker("Requested drafts", selection: Binding(get: { controller.draft?.requestedCount ?? 10 }, set: {
                    controller.draft?.requestedCount = $0; controller.persist()
                })) {
                    ForEach([5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
                }.disabled(controller.isBusy || !draft.completedBatchIDs.isEmpty || !draft.issues.isEmpty)
                Button(draft.completedBatchIDs.isEmpty ? "Generate drafts" : "Resume generation") { controller.generate(judge: semanticJudge) }
                    .disabled(controller.isBusy || draft.selectedPassageIDs.isEmpty || controller.storageBlocked
                        || semanticJudge == nil || draft.semanticApprovalDigest != semanticJudge?.disclosureDigest
                        || draft.cases.filter { !$0.discarded }.count >= draft.requestedCount
                        || draft.completedBatchIDs.union(Set(draft.issues.keys)).count >= draft.requestedCount * 2)
                    .accessibilityIdentifier("Generate document drafts")
                if !draft.issues.isEmpty {
                    Button("Retry failed attempts") { controller.generate(retryFailures: true, judge: semanticJudge) }.disabled(controller.isBusy)
                }
                Text("Fewer drafts may be returned. Coverage counts accepted questions, not every requirement in a section.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Bind a draft row by case identity so edits remain attached to the same candidate across list changes.
    private func draftDetail(index: Int) -> some View {
        let initial = controller.draft!.cases[index].evaluationCase
        let binding = Binding<EvaluationCase>(get: {
            controller.draft?.cases.first(where: { $0.id == initial.id })?.evaluationCase ?? initial
        }, set: { value in
            if let currentIndex = controller.draft?.cases.firstIndex(where: { $0.id == initial.id }) {
                controller.draft?.cases[currentIndex].evaluationCase = value
            }
        })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Case name", text: binding.name).textFieldStyle(.roundedBorder)
                Text("Question").font(.headline)
                TextEditor(text: binding.prompt).frame(minHeight: 70).border(.separator).accessibilityLabel("Draft question")
                Text("Reference answer").font(.headline)
                TextEditor(text: binding.expected).frame(minHeight: 70).border(.separator).accessibilityLabel("Draft reference answer")
                DocumentEvidenceReview(evaluationCase: binding, availablePassages: controller.draft?.source.passages ?? [],
                    acceptAction: { controller.reviewAndAccept(caseID: initial.id, judge: semanticJudge) },
                    acceptanceReady: controller.draft?.semanticReviewIsCurrent(for: initial.id) == true)
                Toggle("Discard this draft", isOn: Binding(get: { controller.draft?.cases[index].discarded ?? false }, set: {
                    controller.draft?.cases[index].discarded = $0
                }))
            }.padding(4).padding(.trailing, 12)
        }.disabled(controller.isBusy).accessibilityIdentifier("Document draft review scroll")
    }

    /// Persist accepted draft state and create the destination suite before switching workspace selection.
    private func create() {
        guard controller.persist(), let draft = controller.draft else { return }
        do {
            _ = try store.createSuite(name: draft.name, documentDraft: draft)
            store.selection = .suite
            controller.discard()
            dismiss()
        } catch { controller.error = error.localizedDescription }
    }
}
