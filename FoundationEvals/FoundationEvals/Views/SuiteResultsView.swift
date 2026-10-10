import Charts
import SwiftUI

/// The suite's history: how the pass rate has moved, every saved run, and tools to compare them.
struct SuiteResultsView: View {
    @Bindable var store: EvaluationStore
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
                    WorkspaceSectionTitle("Run history", count: store.runs.count)
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
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceSectionTitle("Compare")
                SuiteCompareView(store: store)
            }
        }
    }
}

/// The latest pass rate beside a large, hoverable chart of recent runs.
private struct RunTrendPanel: View {
    let runs: [EvaluationRun]
    @State private var hovered: String?

    private var trend: RunTrendSummary { RunTrendSummary(runs: runs) }

    private var selected: RunTrendSummary.Point? {
        guard let hovered else { return nil }
        return trend.points.first { $0.label == hovered }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest pass rate").font(.subheadline).foregroundStyle(.secondary)
                Text(runs[0].passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 44, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
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
            AreaMark(x: .value("Run", point.label), y: .value("Pass rate", point.rate))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Run", point.label), y: .value("Pass rate", point.rate))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            PointMark(x: .value("Run", point.label), y: .value("Pass rate", point.rate))
                .foregroundStyle(color(for: point.run))
                .symbolSize(point.label == hovered ? 100 : 40)
            if point.label == hovered {
                RuleMark(x: .value("Run", point.label))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(point.rate.rounded()))% passed").font(.callout.weight(.semibold)).monospacedDigit()
                            Text("\(point.run.passedCount) passed · \(point.run.failedCount) failed")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(point.run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .workspaceGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func color(for run: EvaluationRun) -> Color {
        if run.errorCount > 0 || run.cancelled || run.stoppedEarly { return WorkspaceStyle.warning }
        guard let rate = run.passRate else { return .secondary.opacity(0.4) }
        return rate >= 1 ? .accentColor : WorkspaceStyle.failure
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

    init(runs: [EvaluationRun]) {
        let recent = Array(runs.prefix(12))
        recentCount = recent.count
        points = recent.reversed().enumerated().compactMap { index, run in
            guard let rate = run.passRate else { return nil }
            return Point(run: run, label: "\(index)", rate: rate * 100)
        }
        if runs.count > 1, let latest = runs[0].passRate, let previous = runs[1].passRate {
            delta = (latest - previous) * 100
        } else {
            delta = nil
        }
        comparisonCaption = runs.count == 1 ? "First saved run" : "No comparable scored run"
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
