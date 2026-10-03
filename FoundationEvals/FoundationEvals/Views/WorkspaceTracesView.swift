import SwiftUI

/// A visible trace index uses the same saved runs and report/trace viewer as the sidebar history.
struct WorkspaceTracesView: View {
    @Bindable var store: EvaluationStore
    @State private var search = ""
    private var runs: [EvaluationRun] {
        store.runs.filter { run in
            search.isEmpty || run.suiteName.localizedCaseInsensitiveContains(search)
                || run.suiteVersion.localizedCaseInsensitiveContains(search)
                || run.results.contains { $0.caseName.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Traces").font(.title2.weight(.bold))
                    Text("Saved runs for \(store.draftSuite.name). Choose a run to inspect its available timeline, inputs, outputs and report.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if store.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkspaceEmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No saved traces yet",
                            detail: "Run this suite to capture a workflow, then inspect its saved trace here.")
                        Button("Open evaluations") { store.selection = .evaluations }.buttonStyle(.bordered)
                    }.padding(18).workspaceSurface()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        WorkspacePanelHeader("Saved traces", count: runs.count)
                        WorkspaceSearchField(prompt: "Find a trace", text: $search, identifier: "Search saved traces")
                            .padding(.horizontal, 18).padding(.bottom, 12)
                        Divider()
                        if runs.isEmpty {
                            WorkspaceEmptyState(symbol: "magnifyingglass", title: "No matching traces",
                                detail: "Try another case name or suite version.")
                        }
                        ForEach(runs) { run in
                            Button { store.selection = .run(run.id) } label: {
                                HStack(spacing: 16) {
                                    RunSidebarRow(run: run)
                                    Spacer()
                                    Text(run.results.contains { !($0.workflowTrace?.spans.isEmpty ?? true) }
                                         ? "\(run.results.count) samples" : "No recorded timeline")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 18).padding(.vertical, 14).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("Open saved trace \(run.id)")
                            Divider()
                        }
                    }.workspaceSurface()
                }
            }.workspacePage()
        }
        .background(WorkspaceStyle.canvas)
        .navigationTitle("Traces")
    }
}
