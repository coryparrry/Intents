import SwiftUI

struct ProductionReviewPane: View {
    @Bindable var model: ProductionWorkspaceStore
    @State private var reviewer = ""

    private struct Row: Identifiable {
        let record: ProductionRecord
        let outcome: ProductionOutcome
        var id: Int { record.slot }
    }
    private var selection: Binding<Int?> {
        Binding(get: { model.selectedRecord?.slot }, set: { slot in
            if let record = model.records.first(where: { $0.slot == slot }) { model.selectRecord(record) }
            else { model.dismissResult() }
        })
    }

    /// Presents paginated saved responses with selection-bound inline details.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let job = model.selectedJob {
                ProductionBatchOutcomeSummary(job: job, report: model.report, isRunning: model.runningJobID == job.id) {
                    model.pane = .reports
                }
                VStack(alignment: .leading, spacing: 0) {
                    WorkspacePanelHeader("Results", count: model.report?.completed ?? 0)
                    Table(model.records.map { Row(record: $0, outcome: model.outcome(for: $0)) }, selection: selection) {
                        TableColumn("Case") { row in
                            Text(row.record.metadata["task"] ?? row.record.exampleID).lineLimit(1)
                        }.width(min: 160, ideal: 300)
                        TableColumn("Outcome") { row in
                            Label(row.outcome.rawValue.capitalized, systemImage: symbol(row.outcome))
                                .foregroundStyle(color(row.outcome))
                        }.width(min: 90, ideal: 110)
                        TableColumn("Latency") { row in
                            Text(ProductionResultPresentation.latency(row.record.response)).monospacedDigit()
                        }.width(min: 90, ideal: 110)
                        TableColumn("Trial") { row in
                            Text("\(row.record.repetition) / \(job.configuration.repetitions)").monospacedDigit().foregroundStyle(.secondary)
                        }.width(80)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
                    .frame(height: min(320, CGFloat(max(1, model.records.count)) * 25 + 34))
                    .accessibilityIdentifier("Batch result list")
                    if model.selectedRecord != nil {
                        Divider()
                        ProductionResultDetailView(model: model, reviewer: $reviewer)
                            .id(model.selectedRecord?.response.requestID)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    Divider()
                    HStack {
                        Button("Previous") { changePage(max(0, model.offset - 50)) }.disabled(model.offset == 0)
                        Spacer()
                        Text(model.records.isEmpty ? "No saved results yet" : "Results \(model.offset+1)–\(model.offset+model.records.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next") { changePage(model.offset + 50) }
                            .disabled(model.offset + model.records.count >= (model.report?.completed ?? 0))
                    }.padding(18)
                }.workspaceSurface()
            } else {
                WorkspaceEmptyState(symbol: "text.bubble", title: "Select a batch", detail: "Choose a saved batch in Jobs to read its results and outcomes.").workspaceSurface()
            }
        }
    }
    /// Clears the selected detail before loading another page of saved results.
    private func changePage(_ offset: Int) {
        model.dismissResult(); model.offset = offset
        Task { await model.refresh() }
    }
    /// Maps each persisted outcome to the workspace status symbol used by the result table.
    private func symbol(_ outcome: ProductionOutcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .error, .needsEvidence: "exclamationmark.circle.fill"
        case .unscored: "circle.dashed"
        }
    }
    /// Maps result status to the shared workspace color vocabulary.
    private func color(_ outcome: ProductionOutcome) -> Color {
        switch outcome {
        case .passed: WorkspaceStyle.success
        case .failed: WorkspaceStyle.failure
        case .error, .needsEvidence: WorkspaceStyle.warning
        case .unscored: .secondary
        }
    }
}
