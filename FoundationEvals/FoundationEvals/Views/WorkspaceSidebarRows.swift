import SwiftUI

struct RunSidebarRow: View {
    let run: EvaluationRun

    private var statusSummary: String {
        if run.cancelled { return "Cancelled · \(run.results.count) of \(run.plannedResultCount)" }
        if run.stoppedEarly { return "\(run.terminationSummary ?? "Stopped early") · \(run.results.count) of \(run.plannedResultCount)" }
        if run.errorCount > 0 { return "\(run.errorCount) issue\(run.errorCount == 1 ? "" : "s")" }
        if SuiteCheckState.savedRun(run) == .incomplete { return "Incomplete · \(run.results.count) of \(run.plannedResultCount)" }
        if let passRate = run.passRate {
            return "\(passRate.formatted(.percent.precision(.fractionLength(0)))) passed"
        }
        return "\(run.results.count) collected"
    }

    private var mark: WorkspaceStatusMark.State { SuiteCheckState.savedRun(run).mark }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            WorkspaceStatusMark(state: mark, size: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(statusSummary)
                    Text("·")
                    Text(run.suiteVersion)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.suiteName)
        .accessibilityValue("\(statusSummary), \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
    }
}

struct EmptyRunHistoryRow: View {
    let isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isSearching ? "No matching runs" : "No runs yet")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(isSearching ? "Try a different suite name or version." : "Completed runs and their traces appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let store = EvaluationStore()
    ContentView(store: store).environment(DeveloperRunnerStore(evaluationStore: store))
}
