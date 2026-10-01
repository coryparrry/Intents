import SwiftUI

struct RunSidebarRow: View {
    let run: EvaluationRun

    private var statusSummary: String {
        if run.cancelled { return "Cancelled · \(run.results.count) of \(run.plannedResultCount)" }
        if run.stoppedEarly { return "\(run.terminationSummary ?? "Stopped early") · \(run.results.count) of \(run.plannedResultCount)" }
        if run.errorCount > 0 { return "\(run.errorCount) issue\(run.errorCount == 1 ? "" : "s")" }
        if let passRate = run.passRate {
            return "\(passRate.formatted(.percent.precision(.fractionLength(0)))) passed"
        }
        return "\(run.results.count) collected"
    }

    private var statusSymbol: String {
        if run.cancelled || run.stoppedEarly { return "exclamationmark.circle.fill" }
        if run.errorCount > 0 || run.failedCount > 0 { return "xmark.circle.fill" }
        if run.scoredCount > 0 { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if run.cancelled || run.stoppedEarly { return .orange }
        if run.errorCount > 0 || run.failedCount > 0 { return .red }
        if run.scoredCount > 0 { return .green }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.suiteName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(run.suiteVersion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 4) {
                    Text(statusSummary)
                    Text("·")
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.suiteName)
        .accessibilityValue("\(statusSummary), \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
    }
}

struct EmptyRunHistoryRow: View {
    let isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                isSearching ? "No matching runs" : "No runs yet",
                systemImage: isSearching ? "magnifyingglass" : "clock.arrow.circlepath"
            )
                .font(.callout.weight(.medium))
            Text(isSearching ? "Try a different suite name or version." : "Completed runs and their local traces appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let store = EvaluationStore()
    ContentView(store: store).environment(DeveloperRunnerStore(evaluationStore: store))
}
