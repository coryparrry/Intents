import Charts
import SwiftUI

/// A compact overview of captured evidence. Missing scores remain distinct from failures.
struct RunSummaryDashboard: View {
    let run: EvaluationRun

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                latencyCard.frame(minWidth: 320)
                outcomeCard.frame(minWidth: 216)
                metricsCard.frame(minWidth: 216)
            }
            .frame(height: 218)

            VStack(spacing: 14) {
                latencyCard.frame(height: 218)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        outcomeCard.frame(minWidth: 250)
                        metricsCard.frame(minWidth: 250)
                    }
                    .frame(height: 218)

                    VStack(spacing: 14) {
                        outcomeCard.frame(height: 218)
                        metricsCard.frame(height: 218)
                    }
                }
            }
        }
    }

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Response latency")
                    .font(.headline)
                Spacer()
                Label("Captured samples", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(run.results.isEmpty ? "—" : Duration.milliseconds(run.averageDurationMilliseconds)
                    .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("average")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if run.results.isEmpty {
                Text("No response timing captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(Array(run.results.enumerated()), id: \.element.id) { index, result in
                    AreaMark(
                        x: .value("Sample", index + 1),
                        y: .value("Seconds", result.durationMilliseconds / 1_000)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Sample", index + 1),
                        y: .value("Seconds", result.durationMilliseconds / 1_000)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    if run.results.count == 1 {
                        PointMark(x: .value("Sample", index + 1), y: .value("Seconds", result.durationMilliseconds / 1_000))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .accessibilityLabel("Response latency in seconds by sample")
                .frame(maxHeight: .infinity)
            }
        }
        .summaryCard()
    }

    private var unscoredCount: Int { run.results.count - run.scoredCount }

    private var outcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Outcome breakdown")
                .font(.headline)
            HStack(spacing: 18) {
                ZStack {
                    WorkspaceRing(
                        segments: [
                            WorkspaceRingSegment(count: run.passedCount, color: WorkspaceStyle.success),
                            WorkspaceRingSegment(count: run.failedCount, color: WorkspaceStyle.failure),
                            WorkspaceRingSegment(count: unscoredCount, color: WorkspaceStyle.warning)
                        ],
                        total: max(run.results.count, 1),
                        lineWidth: 9
                    )
                    VStack(spacing: 0) {
                        Text("\(run.passedCount)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of \(run.results.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
                .frame(width: 86, height: 86)
                VStack(spacing: 9) {
                    outcomeRow("Passed", count: run.passedCount, color: WorkspaceStyle.success)
                    outcomeRow("Failed", count: run.failedCount, color: WorkspaceStyle.failure)
                    outcomeRow("Unscored / errors", count: unscoredCount, color: WorkspaceStyle.warning)
                }
            }
            Spacer(minLength: 0)
            Text("Only scored samples count toward pass rate.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .summaryCard()
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run at a glance")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow {
                    metric(run.passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—", label: "Scored pass rate")
                    metric("\(run.results.count) / \(run.plannedResultCount)", label: "Completed")
                }
                GridRow {
                    metric(run.totalTokens.formatted(), label: "Total tokens")
                    if let average = run.averageScore {
                        metric("\(average.formatted(.number.precision(.fractionLength(1)))) / 4", label: "Rubric average")
                    } else {
                        metric(run.errorCount.formatted(), label: "Issues")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .summaryCard()
    }

    private func outcomeRow(_ title: LocalizedStringKey, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            WorkspaceStatusDot(color: color, size: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(count.formatted()).monospacedDigit().fontWeight(.semibold)
        }
        .font(.callout)
    }

    private func metric(_ value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func summaryCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .workspaceSurface()
    }
}
