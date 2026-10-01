import SwiftUI

struct SuiteResultsView: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Results").font(.title2.bold())
            if store.runs.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "chart.bar", description: Text("Run this suite to review responses, scores and the trace behind each result."))
            } else {
                ForEach(store.runs) { run in
                    Button {
                        store.selection = .run(run.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(run.startedAt, format: .dateTime.year().month().day().hour().minute())
                                Text("\(run.passedCount) passed · \(run.failedCount) failed · \(run.errorCount) errors")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let state = SuiteCheckState.evaluate(run: run, currentRevision: store.suiteRevision,
                                                                 hasDraft: store.draftSuite != store.suite)
                            Label(state.title, systemImage: state.symbol).foregroundStyle(state.color)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

struct SuiteCompareView: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Compare").font(.title2.bold())
            if let current = store.runs.first,
               let baseline = BaselinePresentation.approvedRun(approval: store.activeBaselineApproval, runs: store.runs),
               baseline.id != current.id {
                RunAnalysisSection(run: current, baselineRuns: [baseline])
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Compare results against your baseline").font(.headline)
                        Text("Approve a completed run from its report, then run the suite again to see what changed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "arrow.left.arrow.right").font(.title2) }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
            }
            Divider()
            SuiteExperimentsView(store: store)
        }
    }
}
