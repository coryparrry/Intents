import SwiftUI

private enum WorkspaceDestination: Hashable {
    case overview
    case evaluations
    case batchRuns
    case traces
    case appIntentTesting
    case suite(UUID)
    case run(UUID)
}

struct WorkspaceSidebar: View {
    @Bindable var store: EvaluationStore
    @State private var isManagingWorkspace = false
    @State private var isCreatingSuite = false
    @State private var isCreatingProject = false
    @State private var collapsedSuiteIDs: Set<UUID> = []
    @State private var runToDelete: EvaluationRun?
    @State private var runSearch = ""
    @State private var showsAllRuns = false
    @State private var isProjectSwitcherHovered = false

    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var filteredRuns: [EvaluationRun] {
        let query = runSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.runs : store.runs.filter {
            $0.suiteName.localizedCaseInsensitiveContains(query)
                || $0.suiteVersion.localizedCaseInsensitiveContains(query)
        }
    }
    /// Keeps the current run visible while showing only a few recent runs unless the user expands or searches.
    private var displayedRuns: [EvaluationRun] {
        let runs = filteredRuns
        guard !showsAllRuns, runSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, runs.count > 3 else { return runs }
        let recent = Array(runs.prefix(3))
        guard case .run(let id) = store.selection, !recent.contains(where: { $0.id == id }),
              let selected = runs.first(where: { $0.id == id }) else { return recent }
        return recent + [selected]
    }

    private var destination: Binding<WorkspaceDestination?> {
        Binding(
            get: {
                switch store.selection {
                case .overview: .overview
                case .evaluations: .evaluations
                case .batchRuns: .batchRuns
                case .traces: .traces
                case .appIntentTesting: .appIntentTesting
                case .suite: .suite(store.selectedSuiteID)
                case .run(let id): .run(id)
                }
            },
            set: { selection in
                guard let selection else { return }
                do {
                    switch selection {
                    case .overview: store.selection = .overview
                    case .evaluations: store.selection = .evaluations
                    case .batchRuns: store.selection = .batchRuns
                    case .traces: store.selection = .traces
                    case .appIntentTesting: store.selection = .appIntentTesting
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
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .accessibilityIdentifier("Sidebar overview")
                    .tag(WorkspaceDestination.overview)
                Label("Evaluations", systemImage: "checklist")
                    .accessibilityIdentifier("Sidebar evaluations")
                    .tag(WorkspaceDestination.evaluations)
                Label("Batch runs", systemImage: "square.stack.3d.down.right")
                    .accessibilityIdentifier("Sidebar batch runs")
                    .tag(WorkspaceDestination.batchRuns)
                Label("Traces", systemImage: "point.3.connected.trianglepath.dotted")
                    .accessibilityIdentifier("Sidebar traces")
                    .tag(WorkspaceDestination.traces)
                Label("App Intents", systemImage: "app.badge.checkmark")
                    .accessibilityIdentifier("Sidebar app intents")
                    .tag(WorkspaceDestination.appIntentTesting)
            }

            Section("Suites") {
                ForEach(store.suiteRecords.filter { $0.archivedAt == nil }) { suite in
                    let isSelected = suite.id == store.selectedSuiteID
                    DisclosureGroup(isExpanded: Binding(
                        get: { isSelected && !collapsedSuiteIDs.contains(suite.id) },
                        set: { isExpanded in
                            if isExpanded {
                                collapsedSuiteIDs.remove(suite.id)
                                destination.wrappedValue = .suite(suite.id)
                            } else {
                                collapsedSuiteIDs.insert(suite.id)
                            }
                        }
                    )) {
                        if isSelected {
                            if store.runs.count > 5 || !runSearch.isEmpty {
                                WorkspaceSearchField(prompt: "Filter runs", text: $runSearch)
                                    .selectionDisabled()
                            }
                            if filteredRuns.isEmpty {
                                EmptyRunHistoryRow(isSearching: !runSearch.isEmpty)
                            } else {
                                ForEach(displayedRuns) { run in
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
                            if runSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredRuns.count > 3 {
                                Button {
                                    showsAllRuns.toggle()
                                } label: {
                                    Label(showsAllRuns ? "Show fewer runs" : "Show all runs", systemImage: showsAllRuns ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("Sidebar run expansion")
                                .selectionDisabled()
                            }
                        }
                    } label: {
                        Label(isSelected ? store.draftSuite.name : suite.name, systemImage: "doc.text")
                            .lineLimit(1)
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
                    .tag(WorkspaceDestination.suite(suite.id))
                }
            }

        }
        .onChange(of: store.selectedSuiteID) { _, _ in runSearch = ""; showsAllRuns = false }
        .safeAreaInset(edge: .top, spacing: 0) {
            projectSwitcher
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Button { isCreatingSuite = true } label: {
                    Label("New Suite", systemImage: "plus")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Create a new evaluation suite in this project")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
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

    private var projectSwitcher: some View {
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
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(store.selectedProject.name)
                    .font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(.rect)
            .background(
                isProjectSwitcherHovered ? Color.primary.opacity(0.05) : .clear,
                in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous)
            )
            .onHover { isProjectSwitcherHovered = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .accessibilityLabel("Choose project")
    }

    /// Runs a sidebar workspace action and exposes any localized failure through the shared store notice.
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.notice = error.localizedDescription }
    }
}
