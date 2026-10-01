import SwiftUI

private enum WorkspaceDestination: Hashable {
    case overview
    case suite(UUID)
    case run(UUID)
}

struct WorkspaceSidebar: View {
    @Bindable var store: EvaluationStore
    @State private var isManagingWorkspace = false
    @State private var isCreatingSuite = false
    @State private var isCreatingProject = false
    @State private var runToDelete: EvaluationRun?
    @State private var runSearch = ""

    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var filteredRuns: [EvaluationRun] {
        let query = runSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.runs : store.runs.filter {
            $0.suiteName.localizedCaseInsensitiveContains(query)
                || $0.suiteVersion.localizedCaseInsensitiveContains(query)
        }
    }

    private var destination: Binding<WorkspaceDestination?> {
        Binding(
            get: {
                switch store.selection {
                case .overview: .overview
                case .suite: .suite(store.selectedSuiteID)
                case .run(let id): .run(id)
                }
            },
            set: { selection in
                guard let selection else { return }
                do {
                    switch selection {
                    case .overview: store.selection = .overview
                    case .suite(let id):
                        guard !isBusy || id == store.selectedSuiteID else { return }
                        if id != store.selectedSuiteID { try store.switchSuite(id: id) }
                        store.selection = .suite
                    case .run(let id): store.selection = .run(id)
                    }
                } catch { store.notice = error.localizedDescription }
            }
        )
    }

    var body: some View {
        SidebarNavigationList(selection: destination) {
            Label("Overview", systemImage: "square.grid.2x2.fill")
                .fontWeight(.medium)
                .tag(WorkspaceDestination.overview)

            Section("Suites") {
                ForEach(store.suiteRecords.filter { $0.archivedAt == nil }) { suite in
                    Label(suite.id == store.selectedSuiteID ? store.draftSuite.name : suite.name,
                          systemImage: "checklist")
                        .tag(WorkspaceDestination.suite(suite.id))
                        .contextMenu {
                            Button("Duplicate suite", systemImage: "plus.square.on.square") {
                                perform { _ = try store.duplicateSuite(id: suite.id) }
                            }
                            .disabled(isBusy)
                            Button("Archive suite", systemImage: "archivebox") {
                                perform { try store.archiveSuite(id: suite.id) }
                            }
                            .disabled(isBusy)
                        }
                }
            }

            Section("Run history · \(store.draftSuite.name)") {
                if filteredRuns.isEmpty {
                    EmptyRunHistoryRow(isSearching: !runSearch.isEmpty)
                } else {
                    ForEach(filteredRuns) { run in
                        RunSidebarRow(run: run)
                            .tag(WorkspaceDestination.run(run.id))
                            .contextMenu {
                                Button("Delete run…", systemImage: "trash", role: .destructive) {
                                    runToDelete = run
                                }
                                .disabled(isBusy)
                            }
                    }
                }
            }
        }
        .searchable(text: $runSearch, placement: .sidebar, prompt: "Search run history")
        .onChange(of: store.selectedSuiteID) { _, _ in runSearch = "" }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("FOUNDATION EVALS", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.secondary)
            Menu {
                ForEach(store.projects.filter { $0.archivedAt == nil }) { project in
                    Button {
                        perform {
                            try store.switchProject(id: project.id)
                            store.selection = .overview
                        }
                    } label: {
                        if project.id == store.selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else { Text(project.name) }
                    }
                }
                Divider()
                Button("New project…", systemImage: "folder.badge.plus") { isCreatingProject = true }
                Button("Manage projects…", systemImage: "folder.badge.gearshape") { isManagingWorkspace = true }
            } label: {
                Label(store.selectedProject.name, systemImage: "folder")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .disabled(isBusy)
            .accessibilityLabel("Choose project")
            }
            .padding(.horizontal, 18).padding(.vertical, 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("New suite", systemImage: "plus") { isCreatingSuite = true }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Manage projects", systemImage: "folder.badge.gearshape") { isManagingWorkspace = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(14)
            .disabled(isBusy)
        }
        .sheet(isPresented: $isCreatingSuite) { NewSuiteView(store: store) }
        .sheet(isPresented: $isCreatingProject) { WorkspaceCreationView(store: store, isProject: true) }
        .sheet(isPresented: $isManagingWorkspace) { WorkspaceManagerView(store: store) }
        .alert("Delete saved run?", isPresented: Binding(
            get: { runToDelete != nil }, set: { if !$0 { runToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { runToDelete = nil }
            Button("Delete", role: .destructive) {
                if let run = runToDelete { store.deleteRun(id: run.id) }
                runToDelete = nil
            }
        } message: {
            Text("This removes the saved results and trace from this Mac. It cannot be undone.")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.notice = error.localizedDescription }
    }
}
