import SwiftUI

struct ReviewSampleEditor: View {
    @Bindable var store: EvaluationStore
    let sample: EvaluationReviewSample
    let showCases: (UUID) -> Void
    let showCompare: () -> Void
    @State private var reviewID = UUID()
    @State private var verdict = EvaluationReviewVerdict.needsEvidence
    @State private var note = ""
    @State private var tags = ""
    @State private var showsJudge = false
    @State private var showsPromotion = false
    @State private var error: String?
    @State private var proposalToAccept: UUID?
    @State private var hasLoaded = false
    private var draftKey: String { EvaluationReviewDraftStore.key(for: sample) }

    private var annotation: EvaluationReviewAnnotation? {
        store.suiteLocalState.review.annotation(runID: sample.run.id, sampleID: sample.sample.id)
            .flatMap { EvaluationReviewWorkflow.isCurrent($0, sample: sample) ? $0 : nil }
    }
    private var tagValues: [String] { tags.split(separator: ",").map { String($0) } }
    private var isDirty: Bool {
        annotation?.verdict != verdict || annotation?.note != note.trimmingCharacters(in: .whitespacesAndNewlines)
            || annotation?.tags != Array(Set(tagValues.map(EvaluationReviewWorkflow.normalizedTag).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(sample.sample.caseName).font(.headline)
                    Spacer()
                    Button("Open report", systemImage: "doc.text.magnifyingglass") { store.selection = .run(sample.run.id) }
                        .buttonStyle(.borderless)
                }
                Text("\(sample.run.startedAt.formatted()) · Repetition \(sample.sample.repetition)")
                    .font(.caption).foregroundStyle(.secondary)
                ReviewEvidenceBlock(title: "User input", text: sample.sample.prompt)
                if let effective = sample.sample.effectivePrompt, effective != sample.sample.prompt {
                    DisclosureGroup("Effective model input") { Text(effective).font(.callout).textSelection(.enabled) }
                }
                Text("Captured output").font(.subheadline.weight(.semibold))
                ReviewOutputView(text: sample.sample.response)
                if let message = sample.sample.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(WorkspaceStyle.warning)
                }
                if !sample.sample.expected.isEmpty {
                    ReviewEvidenceBlock(title: "Recorded reference", text: sample.sample.expected)
                }
                if let value = sample.sample.structuredFeatureEvidence?.encodedValue,
                   let text = String(data: value, encoding: .utf8), text != sample.sample.response {
                    DisclosureGroup("Captured app value") { ReviewOutputView(text: text) }
                }
                if let conversation = sample.sample.featureTrace?.conversation { ConversationTraceSection(trace: conversation) }
                DisclosureGroup("Captured setup and execution") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model: \(sample.run.environment.model)")
                        Text("OS: \(sample.run.environment.operatingSystem) · Locale: \(sample.run.environment.locale)")
                        if let execution = sample.run.developerExecution {
                            Text("Device: \(execution.hardwareModel) · \(execution.operatingSystem)")
                            Text("App: \(execution.appBundleIdentifier) \(execution.appVersion) · Feature: \(execution.featureID) \(execution.featureVersion)")
                        }
                        ReviewEvidenceBlock(title: "Recorded instructions", text: sample.run.instructions)
                        SampleTraceSection(result: sample.sample)
                    }.font(.callout).padding(.top, 8)
                }
            }.padding(18).workspaceSurface()

            VStack(alignment: .leading, spacing: 12) {
                Text("Your review").font(.headline)
                Text("Judge scores stay hidden until you choose to reveal them. Describe the observable outcome before diagnosing its cause.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Human verdict", selection: $verdict) {
                    ForEach(EvaluationReviewVerdict.allCases) { Text($0.title).tag($0).disabled($0 != .needsEvidence && !sample.sample.hasCompleteSubjectEvidenceForJudging) }
                }.accessibilityIdentifier("Human verdict")
                Text("What went right or wrong?").font(.subheadline)
                TextEditor(text: $note).workspaceTextWell(minHeight: 104).accessibilityIdentifier("Review note")
                TextField("Failure tags, separated by commas", text: $tags).accessibilityIdentifier("Review tags")
                if let draftError = store.reviewDrafts.error { Text(draftError).font(.caption).foregroundStyle(WorkspaceStyle.warning) }
                Text("Use your own observable failure tags, such as wrong date or lost context. Up to six tags.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save review") { perform { try store.saveReview(makeAnnotation()); try store.reviewDrafts.clear(draftKey) } }
                        .buttonStyle(.borderedProminent).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isDirty)
                        .accessibilityIdentifier("Save review")
                    if annotation != nil && !isDirty { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                Button(showsJudge ? "Hide AI judgment" : "Reveal AI judgment") { showsJudge.toggle() }.buttonStyle(.borderless)
                if showsJudge {
                    let result = sample.run.effectiveResults.first(where: { $0.id == sample.sample.id }) ?? sample.sample
                    ReviewEvidenceBlock(title: "Automated judgment: \(result.status.rawValue)", text: result.rationale ?? "No automated explanation recorded.")
                    if let trace = result.judgeTrace { JudgeEvidenceSection(trace: trace) }
                }
                HStack {
                    Button("Create regression case", systemImage: "plus.square") { showsPromotion = true }
                        .disabled(annotation?.verdict != .failed || isDirty || store.isRunning || store.isReassessing)
                        .accessibilityIdentifier("Create regression case")
                    Menu("Use as judge check") {
                        ForEach(EvaluationJudgeCheckPartition.allCases) { partition in
                            Button(partition.title) { perform { try store.addReviewToJudgeChecks(reviewID: reviewID, partition: partition) } }
                        }
                    }.disabled(annotation?.verdict.resultStatus == nil || isDirty || store.isReassessing)
                }
                Button("Compare instruction changes", action: showCompare).buttonStyle(.borderless)
            }.padding(18).workspaceSurface()
            proposals
        }
        .onAppear {
            loadAnnotation()
            if let draft = store.reviewDrafts.draft(for: draftKey) {
                reviewID = draft.reviewID; verdict = draft.verdict; note = draft.note; tags = draft.tags
            }
            hasLoaded = true
        }
        .onChange(of: note) { retainDraft() }
        .onChange(of: tags) { retainDraft() }
        .onChange(of: verdict) { retainDraft() }
        .onDisappear { store.reviewDrafts.flush(draftKey) }
        .sheet(isPresented: $showsPromotion) {
            ReviewRegressionSheet(store: store, reviewID: reviewID, showCases: showCases)
        }
        .alert("Could not update review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Replace your review with this suggestion?", isPresented: Binding(get: { proposalToAccept != nil }, set: { if !$0 { proposalToAccept = nil } })) {
            Button("Use suggestion") { if let id = proposalToAccept { acceptProposal(id); proposalToAccept = nil } }
        }
    }

    private var proposals: some View {
        let proposals = store.suiteLocalState.review.proposals.filter {
            $0.status == .pending && $0.annotation.runID == sample.run.id && $0.annotation.sampleID == sample.sample.id
        }
        return Group {
            if !proposals.isEmpty {
                DisclosureGroup("Agent suggestions · \(proposals.count) pending") {
                    ForEach(proposals) { proposal in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested \(proposal.annotation.verdict.title.lowercased())").font(.subheadline.weight(.semibold))
                            Text(proposal.annotation.note).font(.callout).textSelection(.enabled)
                            Text(proposal.annotation.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use suggestion") {
                                    if annotation != nil || !note.isEmpty { proposalToAccept = proposal.id } else { acceptProposal(proposal.id) }
                                }
                                Button("Reject") { perform { try store.decideReviewProposal(id: proposal.id, accept: false) } }
                            }
                        }.padding(.vertical, 8)
                    }
                }.padding(18).workspaceSurface()
            }
        }
    }

    private func makeAnnotation() -> EvaluationReviewAnnotation {
        .init(id: reviewID, runID: sample.run.id, sampleID: sample.sample.id, sourceDigest: sample.sourceDigest,
              verdict: verdict, note: note, tags: tagValues, updatedAt: Date())
    }
    private func loadAnnotation() {
        if let annotation { reviewID = annotation.id; verdict = annotation.verdict; note = annotation.note; tags = annotation.tags.joined(separator: ", ") }
    }
    private func retainDraft() {
        guard hasLoaded else { return }
        if isDirty {
            store.reviewDrafts.update(.init(reviewID: reviewID, verdict: verdict, note: note, tags: tags), for: draftKey)
        } else { perform { try store.reviewDrafts.clear(draftKey) } }
    }
    private func acceptProposal(_ id: UUID) {
        perform { try store.decideReviewProposal(id: id, accept: true); try store.reviewDrafts.clear(draftKey); loadAnnotation() }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { self.error = error.localizedDescription } }
}

struct ReviewEvidenceBlock: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).workspaceInset()
        }
    }
}

private struct ReviewRegressionSheet: View {
    @Bindable var store: EvaluationStore
    let reviewID: UUID
    let showCases: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expected = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a regression case").font(.title2.weight(.semibold))
            Text("Supply the correct expected response or verified reference. The source prompt, conversation and field assertions are preserved. The case uses this suite's scoring settings.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $expected).workspaceTextWell(minHeight: 140).accessibilityIdentifier("Regression expected answer")
            if let error { Text(error).font(.callout).foregroundStyle(WorkspaceStyle.failure) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create case") {
                    do { let id = try store.promoteReviewToCase(reviewID: reviewID, expected: expected); dismiss(); showCases(id) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}
