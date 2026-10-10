import SwiftUI

private enum WorkspaceDestination: Hashable {
    case overview
    case intentLab
    case evaluations
    case batchRuns
    case traces
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
                case .intentLab: .intentLab
                case .evaluations: .evaluations
                case .batchRuns: .batchRuns
                case .traces: .traces
                case .suite: .suite(store.selectedSuiteID)
                case .run(let id): .run(id)
                }
            },
            set: { selection in
                guard let selection else { return }
                do {
                    switch selection {
                    case .overview: store.selection = .overview
                    case .intentLab: store.selection = .intentLab
                    case .evaluations: store.selection = .evaluations
                    case .batchRuns: store.selection = .batchRuns
                    case .traces: store.selection = .traces
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
                    .tag(WorkspaceDestination.overview)
                Label {
                    HStack(spacing: 6) {
                        Text("Intent Lab")
                        Text("Beta")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: .capsule)
                    }
                } icon: { Image(systemName: WorkspaceIcon.systemName(for: "intent-lab")) }
                    .accessibilityElement(children: .combine)
                    .tag(WorkspaceDestination.intentLab)
                Label { Text("Evaluations") } icon: { WorkspaceIcon(symbol: "text.bubble", size: 18) }
                    .accessibilityIdentifier("Sidebar evaluations")
                    .tag(WorkspaceDestination.evaluations)
                Label { Text("Batch runs") } icon: { WorkspaceIcon(symbol: "play.rectangle", size: 18) }
                    .accessibilityIdentifier("Sidebar batch runs")
                    .tag(WorkspaceDestination.batchRuns)
                Label { Text("Traces") } icon: { WorkspaceIcon(symbol: "point.3.connected.trianglepath.dotted", size: 18) }
                    .accessibilityIdentifier("Sidebar traces")
                    .tag(WorkspaceDestination.traces)
            }

            Section("Suites") {
                ForEach(store.suiteRecords.filter { $0.archivedAt == nil }) { suite in
                    Label(suite.id == store.selectedSuiteID ? store.draftSuite.name : suite.name, systemImage: "checklist")
                        .lineLimit(1)
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

            Section("Runs for \(store.draftSuite.name)") {
                if store.runs.count > 5 || !runSearch.isEmpty {
                    WorkspaceSearchField(prompt: "Filter runs", text: $runSearch)
                        .selectionDisabled()
                }
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
        .onChange(of: store.selectedSuiteID) { _, _ in runSearch = "" }
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
                VStack(alignment: .leading, spacing: 0) {
                    Text("Project").font(.caption2).foregroundStyle(.secondary)
                    Text(store.selectedProject.name)
                        .font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quinary, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .accessibilityLabel("Choose project")
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.notice = error.localizedDescription }
    }
}
