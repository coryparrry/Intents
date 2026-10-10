import Charts
import SwiftUI

// MARK: - Hero

/// The project at a glance: how things stand in words, the headline figures,
/// and every suite's pass rate over time in one chart you can hover.
struct HomeHero: View {
    let summaries: [SuiteOverviewSummary]
    let total: Int
    let isLoaded: Bool
    let compact: Bool

    private var passed: Int { summaries.filter { $0.state == .passed }.count }
    private var failing: Int { summaries.filter { $0.state == .failed }.count }
    private var outdated: Int { summaries.filter { $0.state.needsAttention && $0.state != .failed }.count }
    private var collected: Int { summaries.filter { $0.state == .collected }.count }
    private var cases: Int { summaries.reduce(0) { $0 + $1.caseCount } }
    private var latest: Date? { summaries.compactMap(\.lastCheckedAt).max() }

    private func suites(_ count: Int) -> String { "\(count) \(count == 1 ? "suite" : "suites")" }

    private var mark: WorkspaceStatusMark.State {
        if !isLoaded { return .running }
        if failing > 0 { return .failed }
        if outdated > 0 { return .attention }
        if total > 0, passed == total { return .passed }
        return .idle
    }

    private var headline: String {
        if !isLoaded { return "Loading your suites…" }
        if total == 0 { return "Create your first suite" }
        if failing > 0 { return "\(suites(failing)) failing" }
        if outdated > 0 { return "\(suites(outdated)) \(outdated == 1 ? "needs" : "need") a fresh run" }
        if passed == total { return total == 1 ? "Your suite is passing" : "All \(total) suites passing" }
        if passed == 0, collected > 0 { return "Responses ready to review" }
        if passed == 0 { return "Ready for a first run" }
        return "\(passed) of \(total) suites passing"
    }

    private var detail: String {
        if !isLoaded { return "Reading saved results from this Mac." }
        if total == 0 { return "A suite is a list of prompts and the answers you expect back." }
        if failing > 0 { return "Some responses didn’t match what you expected. Open a suite to see which ones." }
        if outdated > 0 { return "A suite changed or its last run didn’t finish. Run it again for an up-to-date result." }
        if passed == total { return "Every suite’s latest run passed its checks." }
        if collected > 0 { return "Saved responses have not been scored. Open a suite to review them or choose a scoring method." }
        return "Press play on a suite to see how the model responds."
    }

    var body: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
        layout {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    WorkspaceStatusMark(state: mark, size: 26)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(headline)
                            .font(.title2.weight(.semibold))
                            .contentTransition(.interpolate)
                            .accessibilityAddTraits(.isHeader)
                        Text(detail)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 36) {
                    WorkspaceFigure(title: "Suites passing", value: isLoaded ? "\(passed) of \(total)" : "–")
                    WorkspaceFigure(title: "Test cases",
                                    value: !isLoaded || summaries.contains { $0.loadError != nil } ? "–" : cases.formatted())
                    WorkspaceFigure(title: "Last run",
                                    value: latest.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
            }
            .frame(maxWidth: compact ? .infinity : 400, alignment: .leading)
            // Sized to the summary beside it, so the card has no empty band under the figures.
            HomeTrendChart(summaries: summaries)
                .frame(maxWidth: .infinity)
                .frame(height: 164)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .accessibilityElement(children: .contain)
    }
}

/// Every suite's scored pass rate over time. Hovering reveals the nearest run.
struct HomeTrendChart: View {
    let summaries: [SuiteOverviewSummary]
    @State private var hovered: Date?

    struct Point: Identifiable {
        let id: UUID
        let suiteID: UUID
        let suite: String
        let date: Date
        let rate: Double
        let hasFailures: Bool
    }

    private var points: [Point] {
        Self.points(for: summaries)
    }

    static func points(for summaries: [SuiteOverviewSummary]) -> [Point] {
        summaries.flatMap { summary in
            summary.history.compactMap { point in
                point.rate.map {
                    Point(id: point.id, suiteID: summary.id, suite: summary.name,
                          date: point.date, rate: $0 * 100, hasFailures: point.hasFailures)
                }
            }
        }
    }

    private var selected: Point? {
        guard let hovered else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pass rate").font(.headline)
                Spacer()
                if let first = points.map(\.date).min() {
                    Text("Since \(first.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if points.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Your trend appears after the first scored run.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                if summaries.count == 1 {
                    AreaMark(x: .value("Date", point.date), y: .value("Pass rate", point.rate))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                LineMark(x: .value("Date", point.date), y: .value("Pass rate", point.rate), series: .value("Suite", point.suiteID.uuidString))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(point.suite)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                PointMark(x: .value("Date", point.date), y: .value("Pass rate", point.rate))
                    .foregroundStyle(point.hasFailures ? WorkspaceStyle.failure : Color.accentColor)
                    .symbolSize(point.id == selected?.id ? 90 : 30)
            }
            if let selected {
                RuleMark(x: .value("Date", selected.date))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.suite).font(.callout.weight(.semibold))
                            Text("\(Int(selected.rate.rounded()))% passed").font(.callout.monospacedDigit())
                            Text(selected.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .workspaceGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption)
            }
        }
        .chartXSelection(value: $hovered)
        .animation(.snappy(duration: 0.2), value: selected?.id)
        .accessibilityLabel("Pass rate over time")
    }
}

// MARK: - First run

/// Replaces the hero until the project has a saved run.
struct HomeOnboarding: View {
    let hasSuite: Bool
    let hasCases: Bool
    let disabled: Bool
    let primaryTitle: String
    let primaryAction: () -> Void

    private var current: Int { hasSuite && hasCases ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Run your first evaluation").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Write a few prompts, decide what a good answer looks like, then see how the model does.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { tiles }
                VStack(alignment: .leading, spacing: 14) { tiles }
            }
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: hasSuite ? "arrow.right" : "plus").labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }

    @ViewBuilder
    private var tiles: some View {
        OnboardingTile(number: 1, title: "Write test cases",
                       detail: "A prompt, and the answer you expect back.",
                       isDone: hasSuite && hasCases, isCurrent: current == 1)
        OnboardingTile(number: 2, title: "Pick how to score",
                       detail: "Exact text, contains text, or an AI rubric.",
                       isDone: false, isCurrent: current == 2)
        OnboardingTile(number: 3, title: "Run and review",
                       detail: "Read each response and see why it passed or failed.",
                       isDone: false, isCurrent: false)
    }
}

private struct OnboardingTile: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceStepNumber(number: number, isDone: isDone, isCurrent: isCurrent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(minWidth: 200, maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(WorkspaceStyle.inset, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : isCurrent ? "Next step" : "")
    }
}

// MARK: - Suites

/// One suite in the overview list: how it stands, its recent trend, and a quick way to run it.
struct SuiteRow: View {
    let summary: SuiteOverviewSummary?
    let name: String
    let isRunning: Bool
    let disabled: Bool
    let open: () -> Void
    let run: () -> Void

    private var title: String { summary?.name ?? name }

    private var detail: String {
        guard let summary else { return "Loading…" }
        return [
            isRunning ? "Running…" : summary.state.title,
            "\(summary.caseCount) \(summary.caseCount == 1 ? "case" : "cases")",
            summary.lastCheckedAt.map { "Run " + $0.formatted(.relative(presentation: .named)) } ?? "Never run"
        ].joined(separator: " · ")
    }

    private var warning: String? {
        if let error = summary?.loadError { return error }
        return summary?.repositoryChanged == true ? "Repository definition changed" : nil
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) {
                HStack(spacing: 14) {
                    WorkspaceStatusMark(state: isRunning ? .running : summary?.state.mark ?? .running, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity)
                        if let warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(WorkspaceStyle.warning).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 16)
                    SuiteSparkline(summary: summary)
                        .frame(width: 150, height: 30)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(summary?.latestPassRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(summary?.latestPassRate == nil ? "No score" : "passed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.leading, 18).padding(.trailing, 70).padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(WorkspaceRowButtonStyle())
            .disabled(disabled)
            .accessibilityLabel("\(title), \(summary?.state.title ?? "loading")")

            Group {
                if isRunning {
                    ProgressView().controlSize(.small).accessibilityLabel("Running suite")
                } else {
                    Button(action: run) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Run \(title)")
                    .help(summary?.loadError ?? "Run this suite")
                    .disabled(disabled || summary == nil || summary?.state == .unavailable)
                }
            }
            .frame(width: 36)
            .transition(.blurReplace)
            .padding(.trailing, 18)
        }
        .animation(.smooth(duration: 0.3), value: isRunning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Suite overview \(name)")
    }
}

/// A tiny trend of the suite's recent pass rates, or its latest split when there is only one run.
struct SuiteSparkline: View {
    let summary: SuiteOverviewSummary?

    private var scored: [SuiteHistoryPoint] { summary?.history.filter { $0.rate != nil } ?? [] }

    var body: some View {
        if scored.count >= 2 {
            Chart(scored) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Rate", (point.rate ?? 0) * 100))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Rate", (point.rate ?? 0) * 100))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                if point.id == summary?.latestScoredRunID {
                    PointMark(x: .value("Date", point.date), y: .value("Rate", (point.rate ?? 0) * 100))
                        .foregroundStyle(point.hasFailures ? WorkspaceStyle.failure : Color.accentColor)
                        .symbolSize(30)
                }
            }
            .chartYScale(domain: -6...106)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .accessibilityHidden(true)
        } else if let summary, summary.lastCheckedAt != nil {
            VStack {
                Spacer()
                WorkspaceProportionBar(segments: [
                    WorkspaceRingSegment(count: summary.passedCount, color: WorkspaceStyle.success),
                    WorkspaceRingSegment(count: summary.failedCount, color: WorkspaceStyle.failure),
                    WorkspaceRingSegment(count: summary.errorCount, color: WorkspaceStyle.warning)
                ], height: 6)
            }
        } else {
            VStack {
                Spacer()
                Capsule().fill(.fill.tertiary).frame(height: 6)
            }
        }
    }
}

// MARK: - Recent runs

/// The latest runs across every suite, newest first.
struct RecentRunsTimeline: View {
    struct Item: Identifiable {
        let id: UUID
        let suite: SuiteOverviewSummary
        let point: SuiteHistoryPoint
    }

    let summaries: [SuiteOverviewSummary]
    let disabled: Bool
    let open: (SuiteOverviewSummary, UUID) -> Void

    private var items: [Item] { Self.recentItems(in: summaries) }

    static func recentItems(in summaries: [SuiteOverviewSummary]) -> [Item] {
        Array(summaries.flatMap { summary in summary.history.map { Item(id: $0.id, suite: summary, point: $0) } }
            .sorted { ($0.point.historySequence ?? 0, $0.point.date) > ($1.point.historySequence ?? 0, $1.point.date) }
            .prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { open(item.suite, item.id) } label: {
                        HStack(alignment: .center, spacing: 11) {
                            WorkspaceStatusMark(state: item.point.state.mark, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.suite.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(item.point.date.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(item.point.state.title).font(.callout.weight(.medium))
                                if let rate = item.point.rate {
                                    Text(rate.formatted(.percent.precision(.fractionLength(0))) + " of scored responses passed")
                                        .font(.caption).monospacedDigit()
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WorkspaceRowButtonStyle())
                    .disabled(disabled)
                    .accessibilityElement(children: .combine)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 47)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}

extension SuiteCheckState {
    var color: Color {
        switch self {
        case .passed: WorkspaceStyle.success
        case .failed: WorkspaceStyle.failure
        case .changed, .incomplete, .unavailable: WorkspaceStyle.warning
        case .notRun, .collected: .secondary
        }
    }

    var needsAttention: Bool {
        switch self {
        case .changed, .failed, .incomplete, .unavailable: true
        case .notRun, .passed, .collected: false
        }
    }
}
