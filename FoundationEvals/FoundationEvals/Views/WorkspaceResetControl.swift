import SwiftUI

struct WorkspaceResetControl: View {
    @Bindable var store: EvaluationStore
    @State private var action = ResetAction.suite
    @State private var isConfirming = false

    var body: some View {
        Menu {
            ForEach(ResetAction.allCases) { action in
                Button(action.title) {
                    self.action = action
                    isConfirming = true
                }
            }
        } label: {
            Label("Start from Scratch", systemImage: "arrow.counterclockwise")
        }
        .accessibilityIdentifier("Start from Scratch")
        .help("Reset the suite or clear saved runs and traces")
        .disabled(!store.canResetWorkspace)
        .alert(action.title, isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button(action.title, role: .destructive) {
                do {
                    if action != .history { try store.resetSuite() }
                    if action != .suite { try store.clearRunHistory() }
                } catch {
                    store.notice = "Could not finish \(action.title.lowercased()). Some changes may already have been saved. \(error.localizedDescription)"
                }
            }
        } message: {
            Text(action.detail)
        }
    }

    private enum ResetAction: String, CaseIterable, Identifiable {
        case suite, history, everything
        var id: Self { self }
        var title: String {
            switch self {
            case .suite: "Reset Current Suite"
            case .history: "Clear All Runs and Traces"
            case .everything: "Start from Scratch"
            }
        }
        var detail: String {
            switch self {
            case .suite:
                "Replace the current suite and draft with one blank case. Instructions, scoring, model settings, features, and reference-file selections will reset. Saved runs and traces will remain. This cannot be undone."
            case .history:
                "Permanently delete all saved runs, results, and traces on this Mac. Your current suite and draft will remain. This cannot be undone."
            case .everything:
                "Reset the current suite and draft to one blank case and permanently delete all saved runs, results, and traces on this Mac. This cannot be undone."
            }
        }
    }
}
