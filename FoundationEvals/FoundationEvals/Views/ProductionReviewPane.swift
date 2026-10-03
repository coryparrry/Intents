import SwiftUI

struct ProductionReviewPane: View {
    @Bindable var model: ProductionWorkspaceStore
    @State private var reviewer = ""
    @State private var assignee = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var outcome: ProductionOutcome = .failed
    @State private var verifiedOutput = ""
    @State private var verifiedCost = ""
    @State private var trace: EvaluationRun?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.selectedJobID != nil {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspacePanelHeader("Saved results", count: model.report?.completed ?? 0)
                    ForEach(model.records, id: \.slot) { record in
                        Button { model.selectRecord(record) } label: {
                            HStack { Text(record.exampleID).lineLimit(1); Spacer(); Text(record.response.outcome.rawValue).foregroundStyle(.secondary); Text("#\(record.slot)").font(.caption.monospacedDigit()) }.font(.callout).padding(14).contentShape(.rect)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    HStack {
                        Button("Previous") { model.offset = max(0,model.offset-50); model.selectedRecord = nil; Task { await model.refresh() } }.disabled(model.offset == 0)
                        Spacer(); Text("Results \(model.offset+1)–\(model.offset+model.records.count)").font(.caption).foregroundStyle(.secondary); Spacer()
                        Button("Next") { model.offset += 50; model.selectedRecord = nil; Task { await model.refresh() } }.disabled(model.offset+model.records.count >= (model.report?.completed ?? 0))
                    }.padding(18)
                }.workspaceSurface()
                if let record = model.selectedRecord {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Review #\(record.slot)").font(.headline)
                        Text("Source \(record.sourceID) · \(record.partition.rawValue) · trial \(record.repetition) · \(record.worker.name)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let output = model.review?.response?.output { Text("Reconciled output").font(.subheadline.weight(.medium)); Text(output).textSelection(.enabled) }
                        if let example = model.selectedExample {
                            DisclosureGroup("Prompt and reference") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(example.metadata.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    Text(example.prompt).font(.callout).textSelection(.enabled)
                                    if let expected = example.expected { Text("Reference answer").font(.subheadline.weight(.medium)); Text(expected).font(.callout).textSelection(.enabled) }
                                    if let feedback = example.feedback { Text("Production feedback").font(.subheadline.weight(.medium)); Text(feedback).font(.callout).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text("Original output").font(.subheadline.weight(.medium)); Text(record.response.output.isEmpty ? "No output recorded" : record.response.output).font(.callout).textSelection(.enabled)
                        if let explanation = record.response.explanation { Text(explanation).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let data = record.response.artifact, let run = try? ProductionCodec.decode(EvaluationRun.self, data) { Button("Inspect trace") { trace = run }.buttonStyle(.bordered) }
                        if let review = model.review {
                            Text("Assigned to \(review.assignee ?? "nobody") · \(review.events.count) audit entries\(review.disagreement ? " · Disagreement needs adjudication" : "")").font(.callout).foregroundStyle(.secondary)
                        }
                        TextField("Your reviewer name", text: $reviewer)
                        HStack { TextField("Assign to", text: $assignee); Button("Assign") { append(.assign) }.disabled(assignee.isEmpty || reviewer.isEmpty || note.isEmpty) }
                        Picker("Verdict", selection: $outcome) { Text("Pass").tag(ProductionOutcome.passed); Text("Fail").tag(ProductionOutcome.failed); Text("Needs evidence").tag(ProductionOutcome.needsEvidence) }.pickerStyle(.segmented)
                        TextField("Failure patterns, separated by commas", text: $tags)
                        TextField("Evidence and explanation (required)", text: $note, axis: .vertical).lineLimit(3...8)
                        HStack {
                            Button("Record label") { append(.label) }.buttonStyle(.borderedProminent)
                            Button("Adjudicate") { append(.adjudicate) }.buttonStyle(.bordered).disabled(model.review?.assignee != reviewer)
                        }.disabled(reviewer.isEmpty || note.isEmpty)
                        if record.response.outcome == .needsEvidence && model.review?.response == nil {
                            Text("Verify the action's actual app state before reconciliation. This records human evidence and retains the interrupted result.").font(.callout).foregroundStyle(.secondary)
                            TextField("Verified output", text: $verifiedOutput, axis: .vertical)
                            TextField("Verified outstanding cost (optional)", text: $verifiedCost)
                            Button("Reconcile verified action") { append(.reconcile) }.buttonStyle(.bordered)
                                .disabled(reviewer.isEmpty || note.isEmpty || model.review?.assignee != reviewer || outcome == .needsEvidence || (!verifiedCost.isEmpty && Double(verifiedCost) == nil))
                        }
                        ForEach(model.review?.events ?? []) { event in
                            VStack(alignment: .leading, spacing: 3) { Text("\(event.reviewer) · \(event.action.rawValue) · \(event.outcome?.rawValue ?? event.assignee ?? "verified result")").font(.caption.weight(.medium)); Text(event.note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(18).workspaceSurface()
                }
            } else { WorkspaceEmptyState(symbol: "person.crop.circle.badge.checkmark", title: "Select a batch", detail: "Choose a batch in Jobs, then select a result for review.").workspaceSurface() }
        }.onChange(of: model.selectedRecord?.response.requestID) { _,_ in
            note = ""; tags = ""; assignee = ""; outcome = .failed; verifiedOutput = ""; verifiedCost = ""; trace = nil
        }.sheet(isPresented: Binding(get: { trace != nil }, set: { if !$0 { trace = nil } })) {
            if let trace { VStack { HStack { Text("Saved batch trace").font(.headline); Spacer(); Button("Done") { self.trace = nil } }; WorkflowTraceView(run: trace) }.padding(24).frame(minWidth: 800, minHeight: 600) }
        }
    }
    private func append(_ action: ProductionReviewAction) {
        model.appendReview(action: action, reviewer: reviewer, assignee: assignee, outcome: outcome, note: note, tags: tags, verifiedOutput: verifiedOutput, verifiedCost: Double(verifiedCost))
    }
}
