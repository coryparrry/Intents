import SwiftUI

#Preview("Dashboard · Light") {
    let store = dashboardPreviewStore()
    WorkspaceOverviewView(store: store)
        .environment(DeveloperRunnerStore(evaluationStore: store))
        .frame(width: 1_000, height: 800)
        .preferredColorScheme(.light)
}

#Preview("Dashboard · Dark, compact") {
    let store = dashboardPreviewStore()
    WorkspaceOverviewView(store: store)
        .environment(DeveloperRunnerStore(evaluationStore: store))
        .frame(width: 730, height: 1_100)
        .preferredColorScheme(.dark)
}

/// Creates an isolated temporary workspace store so dashboard previews cannot read or change saved user data.
@MainActor
private func dashboardPreviewStore() -> EvaluationStore {
    // Previews never read or change the developer's saved workspace.
    EvaluationStore(supportDirectory: FileManager.default.temporaryDirectory
        .appending(path: "FoundationEvals-Dashboard-Preview-\(UUID().uuidString)"))
}
