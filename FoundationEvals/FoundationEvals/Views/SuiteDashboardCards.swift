import SwiftUI

/// A slim bar along the bottom of the content. At rest it quietly summarises the
/// current page; while a run is in flight it shows live progress and a Cancel button.
/// It reserves its own space, so it never covers page content.
struct WorkbenchStatusBar: View {
    let store: EvaluationStore
    @Environment(DeveloperRunnerStore.self) private var runners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedRun: EvaluationRun? {
        guard case .run(let id) = store.selection else { return nil }
        return store.run(with: id)
    }

    private var caseCount: Int {
        guard let run = selectedRun else { return store.draftSuite.cases.count }
        return run.plannedCases?.count ?? Set(run.results.map(\.caseID)).count
    }

    private var provider: String {
        guard let run = selectedRun else { return store.draftSuite.modelConfiguration.provider.title }
        return DeveloperRunPresentation.providerLabel(for: run)
    }

    private var isRunning: Bool { store.isRunning || runners.executingRunID != nil }

    private var total: Int {
        let active = runners.executingRunID.flatMap { runners.status(for: $0) }
        return max(store.totalSamples, active?.totalSamples ?? 0)
    }

    private var summary: String {
        if isRunning { return "Evaluation in progress" }
        if store.hasUnsavedCompletedRun { return "Run waiting to be saved" }
        switch store.selection {
        case .overview:
            let suites = store.suiteRecords.filter { !$0.isArchived }.count
            return "\(suites) \(suites == 1 ? "suite" : "suites") · Saved on this Mac"
        case .intentLab, .batchRuns, .appAutomation:
            return "Evidence is saved on this Mac"
        case .suite, .run, .evaluations, .traces:
            break
        }
        return "\(store.runs.count) saved \(store.runs.count == 1 ? "run" : "runs") · \(caseCount) case\(caseCount == 1 ? "" : "s") · \(provider)"
    }

    var body: some View {
        HStack(spacing: 10) {
            if isRunning {
                WorkspaceStatusMark(state: .running, size: 14)
                    .transition(.blurReplace)
            } else if store.hasUnsavedCompletedRun {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(WorkspaceStyle.warning)
                    .transition(.blurReplace)
            }
            Text(summary)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 12)
            if isRunning {
                Text("\(store.completedSamples) of \(total) responses")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .transition(.blurReplace)
                ProgressView(value: Double(store.completedSamples), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                    .transition(.blurReplace)
                if runners.canCancelRun(for: store) {
                    Button("Cancel run", systemImage: "stop.fill") { runners.cancelCurrentRun(for: store) }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .help("Cancel the current run")
                        .transition(.blurReplace)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(isRunning ? .primary : .secondary)
        .padding(.horizontal, 20)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: isRunning)
        .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: store.completedSamples)
    }
}
