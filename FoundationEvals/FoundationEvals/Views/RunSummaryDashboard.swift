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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Captured samples", systemImage: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(run.results.isEmpty ? "—" : Duration.milliseconds(run.averageDurationMilliseconds)
                    .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                    .font(.system(size: 28, weight: .medium))
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
                    .foregroundStyle(Color.accentColor.opacity(0.09))
                    LineMark(
                        x: .value("Sample", index + 1),
                        y: .value("Seconds", result.durationMilliseconds / 1_000)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
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

    private var outcomeCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Outcome breakdown")
                .font(.system(size: 12, weight: .semibold))
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    outcomeSegment(count: run.passedCount, color: .blue, width: geometry.size.width)
                    outcomeSegment(count: run.failedCount, color: .pink, width: geometry.size.width)
                    outcomeSegment(count: run.results.count - run.scoredCount, color: .orange, width: geometry.size.width)
                }
            }
            .frame(height: 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(.capsule)
            VStack(spacing: 9) {
                outcomeRow("Passed", count: run.passedCount, color: .blue)
                outcomeRow("Failed", count: run.failedCount, color: .pink)
                outcomeRow("Unscored / errors", count: run.results.count - run.scoredCount, color: .orange)
            }
            Spacer(minLength: 0)
            Text("Only scored samples count toward pass rate.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .summaryCard()
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Run at a glance")
                .font(.system(size: 12, weight: .semibold))
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

    @ViewBuilder
    private func outcomeSegment(count: Int, color: Color, width: CGFloat) -> some View {
        if count > 0 {
            color.frame(width: max(0, (width - 4) * Double(count) / Double(max(1, run.results.count))))
        }
    }

    private func outcomeRow(_ title: LocalizedStringKey, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(count.formatted()).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private func metric(_ value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func summaryCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}
