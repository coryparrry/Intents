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

    var body: some View {
        HStack(spacing: 12) {
            if store.selection == .overview {
                Image(systemName: "square.stack").accessibilityHidden(true)
                Text("\(store.suiteRecords.filter { !$0.isArchived }.count) suites")
                Text("·")
                Text("Project overview")
            } else {
            Text("\(caseCount) case\(caseCount == 1 ? "" : "s")")
            Circle()
                .fill(store.isRunning ? Color.accentColor : Color.secondary)
                .frame(width: 5, height: 5)
            Text(
                store.isRunning
                    ? "Evaluation in progress"
                    : store.hasUnsavedCompletedRun
                        ? "Run waiting to be saved"
                        : "\(store.runs.count) saved runs"
            )
            }
            Spacer()
            if store.selection != .overview {
                Text(provider)
                Text("·")
            }
            Text("Local workspace")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
