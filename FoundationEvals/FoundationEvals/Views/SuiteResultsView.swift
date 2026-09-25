import Charts
import SwiftUI

struct SuiteResultsView: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !store.runs.isEmpty {
                RunTrendPanel(runs: store.runs)
            }
            VStack(spacing: 0) {
                WorkspacePanelHeader("Run history", count: store.runs.count)
                Divider()
                if store.runs.isEmpty {
                    WorkspaceEmptyState(symbol: "chart.bar.doc.horizontal", title: "Ready for your first run",
                                        detail: "Run this suite to collect responses, scores, and execution traces. Your results will appear here.")
                } else {
                    ForEach(store.runs) { run in
                        let state = SuiteCheckState.evaluate(run: run, currentRevision: store.suiteRevision,
                                                             hasDraft: store.draftSuite != store.suite)
                        Button { store.selection = .run(run.id) } label: {
                            WorkspaceRunRow(run: run, state: state,
                                            isBaseline: store.activeBaselineApproval?.runID == run.id)
                        }
                        .buttonStyle(WorkspaceRowButtonStyle())
                        if run.id != store.runs.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
            .workspaceSurface()
        }
    }
}

/// Latest pass rate, its change since the previous run, and a compact trend of recent runs.
private struct RunTrendPanel: View {
    let runs: [EvaluationRun]

    private struct Point: Identifiable {
        let id: UUID
        let label: String
        let rate: Double
        let color: Color
    }

    private var points: [Point] {
        runs.prefix(12).reversed().enumerated().map { index, run in
            Point(id: run.id, label: "\(index)", rate: (run.passRate ?? 0) * 100, color: color(for: run))
        }
    }

    private var delta: Double? {
        guard runs.count > 1, let latest = runs[0].passRate, let previous = runs[1].passRate else { return nil }
        return (latest - previous) * 100
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest pass rate").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(runs[0].passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                if let delta {
                    let rounded = Int(delta.rounded())
                    WorkspacePill(
                        rounded == 0 ? "No change" : "\(rounded > 0 ? "+" : "")\(rounded) pts vs previous",
                        symbol: rounded > 0 ? "arrow.up.right" : rounded < 0 ? "arrow.down.right" : "equal",
                        color: rounded > 0 ? WorkspaceStyle.success : rounded < 0 ? WorkspaceStyle.failure : .secondary
                    )
                } else {
                    Text("First saved run").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 170, alignment: .leading)
            Divider().frame(height: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text("Pass rate · last \(points.count) run\(points.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Chart(points) { point in
                    BarMark(x: .value("Run", point.label), y: .value("Pass rate", point.rate), width: .ratio(0.6))
                        .foregroundStyle(point.color.gradient)
                        .cornerRadius(3)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
                    }
                }
                .frame(height: 86)
                .accessibilityLabel("Pass rate trend")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(22)
        .workspaceSurface()
    }

    private func color(for run: EvaluationRun) -> Color {
        if run.errorCount > 0 || run.cancelled || run.stoppedEarly { return WorkspaceStyle.warning }
        guard let rate = run.passRate else { return .gray }
        return rate >= 1 ? WorkspaceStyle.success : rate >= 0.5 ? .accentColor : WorkspaceStyle.failure
    }
}

private struct WorkspaceRunRow: View {
    let run: EvaluationRun
    let state: SuiteCheckState
    let isBaseline: Bool

    private var target: String {
        run.developerExecution.map { "\($0.runnerName) · \($0.operatingSystem)" } ?? run.environment.model
    }

    var body: some View {
        HStack(spacing: 14) {
            WorkspaceIconTile(symbol: state.symbol, tint: state.color == .secondary ? .gray : state.color, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if isBaseline {
                        WorkspacePill("Baseline", symbol: "checkmark.seal.fill", color: WorkspaceStyle.success)
                    }
                }
                Text("\(state.title) · \(run.suiteVersion) · \(target)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(run.passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                WorkspaceProportionBar(segments: [
                    WorkspaceRingSegment(count: run.passedCount, color: WorkspaceStyle.success),
                    WorkspaceRingSegment(count: run.failedCount, color: WorkspaceStyle.failure),
                    WorkspaceRingSegment(count: run.errorCount, color: WorkspaceStyle.warning)
                ], height: 5)
                .frame(width: 120)
                Text("\(run.passedCount) passed · \(run.failedCount) failed\(run.errorCount > 0 ? " · \(run.errorCount) errors" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SuiteCompareView: View {
    @Bindable var store: EvaluationStore
    @State private var selectedRunID: UUID?

    private var currentRun: EvaluationRun? {
        store.runs.first { $0.id == selectedRunID } ?? store.runs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.runs.count > 1, let current = currentRun {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Run to inspect", selection: Binding(
                        get: { current.id }, set: { selectedRunID = $0 }
                    )) {
                        ForEach(store.runs) { run in
                            Text(run.comparisonDisplayName).tag(run.id)
                        }
                    }
                    Text("Choose an earlier run in Analysis to compare quality and latency across devices or revisions.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18)
                .workspaceSurface()
                if let execution = current.developerExecution {
                    DeveloperExecutionSummary(execution: execution)
                }
                RunAnalysisSection(run: current, baselineRuns: store.runs.filter {
                    $0.id != current.id && $0.startedAt < current.startedAt
                })
                    .id(current.id)
            } else {
                WorkspaceEmptyState(
                    symbol: "arrow.left.arrow.right",
                    title: "Compare your saved runs",
                    detail: "Run this suite at least twice to compare quality, latency, and failures. Device runs keep their hardware and OS details."
                )
                .workspaceSurface()
            }
            SuiteExperimentsView(store: store)
        }
    }
}


extension EvaluationRun {
    var comparisonDisplayName: String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        let target = developerExecution.map { "\($0.runnerName) · \($0.operatingSystem)" } ?? environment.model
        return "\(date) · \(target) · \(suiteVersion)"
    }
}
