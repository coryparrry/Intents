import SwiftUI

struct ProductionResultDetailView: View {
    @Bindable var model: ProductionWorkspaceStore
    @State private var trace: EvaluationRun?
    /// Presents validated response details and operator review for the selected batch record.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record = model.selectedRecord {
                Text("Source \(record.sourceID) · \(record.partition.rawValue) · trial \(record.repetition) · \(record.worker.name)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                let validatedRun = model.selectedJob.flatMap { ProductionResultPresentation.nativeRun(record: record, job: $0) }
                if let run = validatedRun, let result = run.results.first {
                    EvaluationResultDetail(result: result, scoringMode: run.scoringMode,
                        repetitions: run.repetitions,
                        subjectModelName: run.execution?.modelDisplayName ?? run.environment.model,
                        modelConfiguration: run.execution?.configuration)
                } else {
                    Text(record.metadata["task"] ?? record.exampleID).font(.title2.weight(.semibold))
                    if let example = model.selectedExample {
                        LabeledText(label: "Prompt", text: example.prompt)
                        if let expected = example.expected { LabeledText(label: "Reference answer", text: expected) }
                        if let feedback = example.feedback { LabeledText(label: "Production feedback", text: feedback) }
                    }
                    LabeledText(label: "Original output", text: record.response.output.isEmpty ? "No output recorded" : record.response.output)
                    if let explanation = record.response.explanation { Text(explanation).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if let output = model.review?.response?.output { LabeledText(label: "Reconciled output", text: output) }
                if let run = validatedRun {
                    Button("Inspect trace", systemImage: "point.3.connected.trianglepath.dotted") { trace = run }.buttonStyle(.bordered)
                }
                DisclosureGroup("Operator review") {
                    VStack(alignment: .leading, spacing: 14) {
                        if let review = model.review {
                            Text("Assigned to \(review.assignee ?? "nobody") · \(review.events.count) audit entries\(review.disagreement ? " · Disagreement needs adjudication" : "")").font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = model.reviewDraftSaveError {
                            Text(error).font(.callout).foregroundStyle(WorkspaceStyle.warning)
                            Button("Retry saving draft") { model.saveReviewDrafts() }
                        }
                        Text("Form input is saved separately from the audit. Assignments and labels keep it for further review; successful reconciliation clears an unchanged form.").font(.caption).foregroundStyle(.secondary)
                        TextField("Your reviewer name", text: field(\.reviewer))
                        HStack { TextField("Assign to", text: field(\.assignee)); Button("Assign") { append(.assign) }.disabled(draft.assignee.isEmpty || draft.reviewer.isEmpty || draft.note.isEmpty) }
                        Picker("Verdict", selection: field(\.outcome)) { Text("Pass").tag(ProductionOutcome.passed); Text("Fail").tag(ProductionOutcome.failed); Text("Needs evidence").tag(ProductionOutcome.needsEvidence) }.pickerStyle(.segmented)
                        TextField("Failure patterns, separated by commas", text: field(\.tags))
                        TextField("Evidence and explanation (required)", text: field(\.note), axis: .vertical).lineLimit(3...8)
                        HStack {
                            Button("Record label") { append(.label) }.buttonStyle(.borderedProminent)
                            Button("Adjudicate") { append(.adjudicate) }.buttonStyle(.bordered).disabled(model.review?.assignee != draft.reviewer)
                        }.disabled(draft.reviewer.isEmpty || draft.note.isEmpty)
                        if record.response.outcome == .needsEvidence && model.review?.response == nil {
                            Text("Verify the action's actual app state before reconciliation. This records human evidence and retains the interrupted result.").font(.callout).foregroundStyle(.secondary)
                            TextField("Verified output", text: field(\.verifiedOutput), axis: .vertical)
                            TextField("Verified outstanding cost (optional)", text: field(\.verifiedCost))
                            Button("Reconcile verified action") { append(.reconcile) }.buttonStyle(.bordered)
                                .disabled(draft.reviewer.isEmpty || draft.note.isEmpty || model.review?.assignee != draft.reviewer || draft.outcome == .needsEvidence || (!draft.verifiedCost.isEmpty && Double(draft.verifiedCost) == nil))
                        }
                        ForEach(model.review?.events ?? []) { event in
                            VStack(alignment: .leading, spacing: 3) { Text("\(event.reviewer) · \(event.action.rawValue) · \(event.outcome?.rawValue ?? event.assignee ?? "verified result")").font(.caption.weight(.medium)); Text(event.note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.top, 12)
                }
            }
        }
        .onChange(of: model.selectedRecord?.response.requestID) { _,_ in
            trace = nil
        }.sheet(isPresented: Binding(get: { trace != nil }, set: { if !$0 { trace = nil } })) {
            if let trace { VStack { HStack { Text("Saved batch trace").font(.headline); Spacer(); Button("Done") { self.trace = nil } }; WorkflowTraceView(run: trace) }.padding(24).frame(minWidth: 800, minHeight: 600) }
        }
    }
    private var draft: ProductionReviewDraft {
        guard let jobID = model.selectedJobID, let requestID = model.selectedRecord?.response.requestID else { return ProductionReviewDraft() }
        return model.reviewDraft(jobID: jobID, requestID: requestID)
    }
    /// Binds each edit to the result identity captured when its form is rendered.
    private func field<Value>(_ path: WritableKeyPath<ProductionReviewDraft, Value>) -> Binding<Value> {
        let jobID = model.selectedJobID, requestID = model.selectedRecord?.response.requestID
        return Binding(get: {
            guard let jobID, let requestID else { return ProductionReviewDraft()[keyPath: path] }
            return model.reviewDraft(jobID: jobID, requestID: requestID)[keyPath: path]
        }, set: { value in
            guard let jobID, let requestID else { return }
            var current = model.reviewDraft(jobID: jobID, requestID: requestID)
            current[keyPath: path] = value
            model.updateReviewDraft(current, jobID: jobID, requestID: requestID)
        })
    }
    /// Appends the selected action using the current result's durable draft.
    private func append(_ action: ProductionReviewAction) {
        model.appendReview(action: action, reviewer: draft.reviewer, assignee: draft.assignee, outcome: draft.outcome, note: draft.note, tags: draft.tags, verifiedOutput: draft.verifiedOutput, verifiedCost: Double(draft.verifiedCost))
    }
}

/// Artifacts are supporting evidence; a worker cannot override the saved response with an unrelated trace.
enum ProductionResultPresentation {
    /// Shows a directional change only when the candidate has a scored rate; zero remains a real score.
    static func baselineComparison(before: Double, after: Double?) -> String {
        let baseline = String(format: "%.1f%%", before * 100)
        guard let after else { return "Baseline \(baseline) · Comparison unavailable — no scored responses" }
        return "Baseline \(baseline) · Change \(String(format: "%+.1f", (after - before) * 100)) percentage points"
    }

    /// Returns a single native trace only when its request, revision, output and outcome match the authoritative saved record.
    static func nativeRun(record: ProductionRecord, job: ProductionJob) -> EvaluationRun? {
        guard let data = record.response.artifact,
              let run = try? ProductionCodec.decode(EvaluationRun.self, data),
              run.id == record.response.requestID, run.suiteRevision == job.revision,
              !run.cancelled, run.results.count == 1, let result = run.results.first,
              result.caseID == record.response.requestID,
              result.response == record.response.output,
              result.status.rawValue == record.response.outcome.rawValue else { return nil }
        return run
    }

    /// Formats recorded latency and preserves unavailable evidence instead of presenting a fabricated zero.
    static func latency(_ response: ProductionResponse) -> String {
        guard response.latencyAvailable != false else { return "Unavailable" }
        return Duration.milliseconds(response.latencyMilliseconds)
            .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }
}
