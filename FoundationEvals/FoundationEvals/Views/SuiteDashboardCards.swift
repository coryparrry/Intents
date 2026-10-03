import SwiftUI

struct WorkbenchStatusBar: View {
    let store: EvaluationStore

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

    private var activityColor: Color {
        if store.isRunning { return .accentColor }
        return store.hasUnsavedCompletedRun ? WorkspaceStyle.warning : WorkspaceStyle.success
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.selection == .overview {
                Image(systemName: "square.stack").accessibilityHidden(true)
                Text("\(store.suiteRecords.filter { !$0.isArchived }.count) suites")
                Text("·").foregroundStyle(.tertiary)
                Text("Project overview")
            } else {
                if store.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    WorkspaceStatusDot(color: activityColor, size: 6)
                }
                Text(
                    store.isRunning
                        ? "Evaluation in progress"
                        : store.hasUnsavedCompletedRun
                            ? "Run waiting to be saved"
                            : "\(store.runs.count) saved runs"
                )
                Text("·").foregroundStyle(.tertiary)
                Text("\(caseCount) case\(caseCount == 1 ? "" : "s")")
            }
            Spacer()
            if store.selection != .overview {
                WorkspaceMetaLabel(provider, symbol: "cpu")
                Text("·").foregroundStyle(.tertiary)
            }
            WorkspaceMetaLabel("Local workspace", symbol: "internaldrive")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
