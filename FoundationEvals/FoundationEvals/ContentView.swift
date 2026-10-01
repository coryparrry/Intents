import SwiftUI

struct ContentView: View {
    @Bindable var store: EvaluationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            workspaceNavigation
            WorkbenchStatusBar(store: store)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("Workspace status")
        }
        .frame(minWidth: 1_000, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceResetControl(store: store)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Judge connections and app settings")
            }
        }
        .background { SuiteAutosaveObserver(store: store) }
        .alert(
            "Foundation Evals",
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
                .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 300)
        } detail: {
            switch store.selection {
            case .overview:
                WorkspaceOverviewView(store: store)
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
