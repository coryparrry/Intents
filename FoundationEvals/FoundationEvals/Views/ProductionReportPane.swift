import SwiftUI

struct ProductionReportPane: View {
    @Bindable var model: ProductionWorkspaceStore
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report = model.report {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(report.job.name).font(.headline); Spacer(); Text(gateName(report.exitCode)).font(.callout.weight(.semibold)) }
                    Text("\(report.completed) of \(report.planned) saved · \(report.counts.passed) passed · \(report.counts.failed) failed · \(report.counts.errors) errors · \(report.counts.unscored) unscored · \(report.counts.uncertain) uncertain").font(.callout)
                    Text("Pass rate \(rate(report.counts.passRate)) · \(report.counts.distinctSources) distinct sources").font(.callout)
                    if let lower = report.counts.lower95, let upper = report.counts.upper95 {
                        Text("Source pass rate \(rate(report.counts.sourcePassRate)) · 95% interval \(rate(lower))–\(rate(upper))").font(.callout)
                    }
                    Text(report.samplingNotice).font(.callout).foregroundStyle(.secondary)
                    Text("P95 latency \(report.p95UpperMilliseconds.map { String(format: "%.0f ms (upper estimate)", $0) } ?? "Unavailable") · Reported cost $\(String(format: "%.4f", report.reportedCost)) · \(report.missingCostCount) costs unavailable").font(.caption).foregroundStyle(.secondary)
                    if let before = report.baselinePassRate { Text("Baseline \(rate(before)) · Change \(String(format: "%+.1f", ((report.counts.passRate ?? 0)-before)*100)) percentage points").font(.callout) }
                    ForEach(report.issues, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    Button("Export evidence…") { model.export() }.buttonStyle(.bordered)
                }.padding(18).workspaceSurface()
                VStack(alignment: .leading, spacing: 0) {
                    WorkspacePanelHeader("Cohorts", count: report.cohorts.count)
                    WorkspaceSearchField(prompt: "Find a cohort", text: $search, identifier: "Search batch cohorts").padding(.horizontal,18).padding(.bottom,12)
                    Divider()
                    ForEach(report.cohorts.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.prefix(100), id: \.self) { key in
                        if let cohort = report.cohorts[key] {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) { Text(key).font(.callout.weight(.medium)); Text("\(cohort.samples) trials · \(cohort.distinctSources) sources · \(cohort.errors) errors · \(cohort.unscored + cohort.uncertain) need review").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(rate(cohort.passRate)).font(.callout.monospacedDigit())
                                    if let before = report.baselineCohortPassRates?[key], let after = cohort.passRate {
                                        Text(String(format: "%+.1f points", (after-before)*100)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(18); Divider()
                        }
                    }
                    if report.cohorts.count > 100 { Text("Showing up to 100 matching cohorts. Search to narrow the list; exports contain every cohort.").font(.caption).foregroundStyle(.secondary).padding(18) }
                }.workspaceSurface()
            } else { WorkspaceEmptyState(symbol: "chart.bar", title: "Select a batch", detail: "Choose a saved batch in Jobs to inspect its release gates and cohort results.").workspaceSurface() }
        }
    }
    private func rate(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0*100) } ?? "Unscored" }
    private func gateName(_ value: Int) -> String { switch value { case 0: "Pass"; case 10: "Quality gate failed"; case 20: "Incomplete evidence"; default: "Execution gate failed" } }
}
