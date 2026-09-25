import SwiftUI

struct ContentView: View {
    @Bindable var store: EvaluationStore
    @State private var scenarioCoordinator: ScenarioCoordinator
    @Environment(DeveloperRunnerStore.self) private var runners
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(store: EvaluationStore) {
        self.store = store
        _scenarioCoordinator = State(initialValue: ScenarioCoordinator(
            supportDirectory: store.overviewStorageDirectory,
            evaluationStore: store
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                workspaceNavigation
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                WorkbenchStatusBar(store: store)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("Workspace status")
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(minWidth: 1_000, minHeight: 700)
        .background(WorkspaceStyle.canvas)
        .toolbar(removing: .title)
        .background { SuiteAutosaveObserver(store: store) }
        .onChange(of: runners.activeRuns) { previous, current in
            for status in current.values where [.failed, .timedOut, .disconnected].contains(status.phase) {
                guard previous[status.id] != status else { continue }
                let sampleMessage = store.run(with: status.id)?.results.last { $0.errorMessage != nil }?.errorMessage
                store.notice = DeveloperRunPresentation.failureMessage(for: status, sampleMessage: sampleMessage)
            }
        }
        .alert(
            "Intents",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.notice = nil } }
            )
        ) {
            Button("OK") { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
    }

    private var workspaceNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            switch store.selection {
            case .overview:
                WorkspaceOverviewView(store: store)
            case .intentLab:
                IntentLabView(coordinator: scenarioCoordinator, projects: store.projects)
            case .suite:
                SuiteEditorView(store: store)
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
            case .run(let id):
                if let run = store.run(with: id) {
                    RunDetailView(
                        run: run,
                        store: store,
                        baselineRuns: store.runs.filter {
                            $0.id != run.id
                                && $0.suiteID == run.suiteID
                                && $0.startedAt < run.startedAt
                        }
                    )
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
                } else {
                    ContentUnavailableView(
                        "Run Not Found",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The saved run may have been removed.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
