import SwiftUI

/// A slim bar along the bottom of the content for a running or unsaved evaluation.
struct WorkbenchStatusBar: View {
    let store: EvaluationStore
    @Environment(DeveloperRunnerStore.self) private var runners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRunning: Bool { store.isRunning || runners.executingRunID != nil }

    private var total: Int {
        let active = runners.executingRunID.flatMap { runners.status(for: $0) }
        return max(store.totalSamples, active?.totalSamples ?? 0)
    }

    private var summary: String {
        if isRunning { return "Evaluation in progress" }
        return "Run waiting to be saved"
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
        .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: store.hasUnsavedCompletedRun)
        .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: store.completedSamples)
    }
}
