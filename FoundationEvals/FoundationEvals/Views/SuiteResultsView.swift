import Charts
import SwiftUI

/// The suite's history: how the pass rate has moved and every saved run.
struct SuiteResultsView: View {
    @Bindable var store: EvaluationStore
    let showCompare: () -> Void
    @Environment(DeveloperRunnerStore.self) private var runners

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if store.runs.isEmpty {
                WorkspaceEmptyState(symbol: "chart.xyaxis.line", title: "Ready for your first run",
                                    detail: runners.runIssue(for: store)
                                        ?? "Run this suite to see each response, its score, and how long it took.",
                                    actionTitle: "Run Suite", actionSymbol: "play.fill") {
                    do { try runners.startSelectedRun(for: store) } catch { store.notice = error.localizedDescription }
                }
                .disabled(!runners.canStartRun(for: store))
                .workspaceSurface()
            } else {
                RunTrendPanel(runs: store.runs)
                VStack(alignment: .leading, spacing: 14) {
                    WorkspaceSectionTitle("Run history", count: store.runs.count) {
                        Button("Compare runs", systemImage: "arrow.left.arrow.right", action: showCompare)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(store.runs.enumerated()), id: \.element.id) { index, run in
                            let state = SuiteCheckState.evaluate(run: run, currentRevision: store.suiteRevision,
                                                                 hasDraft: store.draftSuite != store.suite)
                            Button { store.selection = .run(run.id) } label: {
                                WorkspaceRunRow(run: run, state: state,
                                                isBaseline: store.activeBaselineApproval?.runID == run.id)
                            }
                            .buttonStyle(WorkspaceRowButtonStyle())
                            if index < store.runs.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .workspaceSurface()
                }
            }
        }
    }
}

/// The latest pass rate beside a large, hoverable chart of recent runs.
private struct RunTrendPanel: View {
    let runs: [EvaluationRun]
    @State private var hovered: String?

    private var trend: RunTrendSummary { RunTrendSummary(runs: runs) }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest scored pass rate").font(.subheadline).foregroundStyle(.secondary)
                Text(runs[0].passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 44, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(RunCoverageSummary(run: runs[0]).caption)
                    .font(.caption).foregroundStyle(.secondary)
                if let delta = trend.delta {
                    let rounded = Int(delta.rounded())
                    Label(rounded == 0 ? "No change" : "\(rounded > 0 ? "+" : "")\(rounded) pts vs previous run",
                          systemImage: rounded > 0 ? "arrow.up.right" : rounded < 0 ? "arrow.down.right" : "equal")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(rounded > 0 ? WorkspaceStyle.success : rounded < 0 ? WorkspaceStyle.failure : .secondary)
                } else {
                    Text(trend.comparisonCaption).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 28) {
                    WorkspaceFigure(title: "Passed", value: runs[0].passedCount.formatted())
                    WorkspaceFigure(title: "Failed", value: runs[0].failedCount.formatted())
                }
                .padding(.top, 18)
            }
            .frame(width: 230, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(trend.title).font(.headline)
                Text("Each point describes one saved run. Changes require complete, compatible evidence.")
                    .font(.caption).foregroundStyle(.secondary)
                if trend.points.isEmpty {
                    Text("No scored runs yet")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        }
        .padding(26)
        .workspaceSurface()
    }

    private var chart: some View {
        Chart(trend.points) { point in
            PointMark(x: .value("Run", point.label), y: .value("Pass rate", point.rate))
                .foregroundStyle(color(for: point.run))
                .symbolSize(point.label == hovered ? 100 : 40)
                .accessibilityLabel("\(point.run.startedAt.formatted()) · \(Int(point.rate.rounded()))% · \(RunCoverageSummary(run: point.run).caption)")
            if point.label == hovered {
                RuleMark(x: .value("Run", point.label))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(point.rate.rounded()))% passed").font(.callout.weight(.semibold)).monospacedDigit()
                            Text(RunCoverageSummary(run: point.run).caption)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(point.run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .workspaceChartCallout()
                        .allowsHitTesting(false)
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
            }
        }
        .chartXSelection(value: $hovered)
        .animation(.snappy(duration: 0.2), value: hovered)
        .accessibilityLabel("Pass rate trend")
    }

    /// Colors runs with errors or interrupted execution as warnings, then distinguishes unavailable, perfect, and failing pass rates.
    private func color(for run: EvaluationRun) -> Color {
        if run.errorCount > 0 || run.cancelled || run.terminationReason != nil { return WorkspaceStyle.warning }
        guard let rate = run.passRate else { return .secondary.opacity(0.4) }
        return rate >= 1 ? .accentColor : WorkspaceStyle.failure
    }
}

/// Keeps scored rates beside their planned coverage and execution state.
struct RunCoverageSummary {
    let scored: Int
    let completed: Int
    let planned: Int?
    let status: String
    let isFullyScored: Bool

    /// Summarizes saved evidence without interpreting missing, unscored or interrupted samples as passes.
    init(run: EvaluationRun) {
        let analysis = EvaluationRunAnalysis(run: run)
        scored = analysis.scoredSampleCount
        completed = analysis.completedSampleCount
        if let count = run.plannedSampleCount, count >= 0 {
            planned = count
        } else if let cases = run.plannedCases ?? run.suiteDefinition?.cases, run.repetitions > 0 {
            let count = cases.count.multipliedReportingOverflow(by: run.repetitions)
            planned = count.overflow ? nil : count.partialValue
        } else {
            planned = nil
        }
        let complete = planned.map { $0 > 0 } == true && completed == planned && !run.cancelled && run.terminationReason == nil
        status = run.cancelled ? "Cancelled" : run.terminationReason != nil ? "Stopped early"
            : planned == nil ? "Coverage unavailable" : complete ? "Complete" : "Incomplete"
        isFullyScored = complete && scored == planned
    }

    var caption: String {
        let denominator = planned.map(String.init) ?? "?"
        return "\(scored) / \(denominator) scored · \(completed) / \(denominator) saved · \(status)"
    }
}

struct RunTrendSummary {
    struct Point: Identifiable {
        let run: EvaluationRun
        let label: String
        let rate: Double

        var id: UUID { run.id }
    }

    let recentCount: Int
    let points: [Point]
    let delta: Double?
    let comparisonCaption: String

    /// Retains individual scored run points and compares only complete, compatible evidence from the same suite.
    init(runs: [EvaluationRun]) {
        let recent = Array(runs.prefix(12))
        recentCount = recent.count
        points = recent.reversed().enumerated().compactMap { index, run in
            guard let rate = run.passRate else { return nil }
            return Point(run: run, label: "\(index)", rate: rate * 100)
        }
        if runs.count > 1, RunCoverageSummary(run: runs[0]).isFullyScored,
           RunCoverageSummary(run: runs[1]).isFullyScored, runs[0].suiteID == runs[1].suiteID,
           EvaluationRunComparison(current: runs[0], baseline: runs[1]).compatibility == .compatible,
           let latest = runs[0].passRate, let previous = runs[1].passRate {
            delta = (latest - previous) * 100
        } else {
            delta = nil
        }
        comparisonCaption = runs.count == 1 ? "First saved run" : "Comparison unavailable: runs must be complete and compatible."
    }

    var title: String {
        if points.count != recentCount {
            return "Pass rate · \(points.count) scored of last \(recentCount) runs"
        }
        return "Pass rate · last \(recentCount) run\(recentCount == 1 ? "" : "s")"
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
        HStack(alignment: .center, spacing: 14) {
            WorkspaceStatusMark(state: state.mark, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if isBaseline {
                        WorkspacePill("Baseline", symbol: "checkmark.seal.fill", color: WorkspaceStyle.success)
                    }
                }
                Text("\(state.title) · \(run.suiteVersion) · \(target)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 13)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(run.passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(RunCoverageSummary(run: run).caption)
                    .font(.caption).foregroundStyle(.secondary)
                WorkspaceProportionBar(segments: [
                    WorkspaceRingSegment(count: run.passedCount, color: WorkspaceStyle.success),
                    WorkspaceRingSegment(count: run.failedCount, color: WorkspaceStyle.failure),
                    WorkspaceRingSegment(count: run.errorCount, color: WorkspaceStyle.warning)
                ], height: 4)
                .frame(width: 96)
            }
            Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SuiteCompareView: View {
    @Bindable var store: EvaluationStore
    var showPromptImprovement: (() -> Void)?
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
            SuiteExperimentsView(store: store, showPromptImprovement: showPromptImprovement)
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
