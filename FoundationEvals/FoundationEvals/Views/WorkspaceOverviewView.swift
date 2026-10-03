import SwiftUI

struct WorkspaceOverviewView: View {
    @Bindable var store: EvaluationStore
    @Environment(DeveloperRunnerStore.self) private var runners
    @State private var savedSummaries: [SuiteOverviewSummary] = []
    @State private var loader = WorkspaceOverviewLoader()
    @State private var refresh = 0
    @State private var isCreatingSuite = false
    @State private var search = ""
    @State private var attentionOnly = false
    @State private var availableWidth: CGFloat = 900
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles || runners.executingRunID != nil }
    private var records: [EvaluationSuiteRecord] { store.suiteRecords.filter { !$0.isArchived } }
    private var summaries: [SuiteOverviewSummary] { records.compactMap { summary(for: $0) } }
    private var isLoaded: Bool { summaries.count == records.count }
    private var visibleRecords: [EvaluationSuiteRecord] {
        records.filter { record in
            let value = summary(for: record)
            let name = value?.name ?? record.name
            return (search.isEmpty || name.localizedCaseInsensitiveContains(search))
                && (!attentionOnly || value.map { $0.state.needsAttention } == true)
        }
    }

    private func summary(for record: EvaluationSuiteRecord) -> SuiteOverviewSummary? {
        if record.id == store.selectedSuiteID {
            var value = SuiteOverviewSummary(record: record, suite: store.suite, currentRevision: store.suiteRevision,
                                             draft: store.draftSuite, runs: store.runs, localState: store.suiteLocalState)
            if let saved = savedSummaries.first(where: { $0.id == record.id }) {
                if saved.repositoryChanged { value.state = .changed; value.repositoryChanged = true }
                if let error = saved.loadError { value.state = .unavailable; value.loadError = error }
            }
            return value
        }
        return savedSummaries.first { $0.id == record.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let notice = store.migrationNotice {
                    Label(notice, systemImage: "tray.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workspaceInset()
                }
                WorkspaceHealthPanel(summaries: summaries, total: records.count, isLoaded: isLoaded, compact: availableWidth < 700)
                let wide = availableWidth >= 820
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                layout {
                    suitePanel.frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        WorkspaceActivityCard(summaries: summaries, disabled: isBusy, open: openLatest)
                        DeveloperConnectionBanner()
                    }
                    .frame(width: wide ? 300 : nil)
                    .frame(maxWidth: wide ? 300 : .infinity)
                }
            }
            .workspacePage()
        }
        .background(WorkspaceStyle.canvas)
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, WorkspaceStyle.readableWidth) - 2 * WorkspaceStyle.pagePadding } action: { availableWidth = $0 }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                    .help("Reload saved results for every suite")
                    .accessibilityLabel("Refresh project")
            }
        }
        .task(id: "\(store.selectedProject.id)-\(store.selectedProject.updatedAt)-\(refresh)") {
            let values = await loader.load(project: store.selectedProject, directory: store.overviewStorageDirectory)
            guard !Task.isCancelled else { return }
            savedSummaries = values
        }
        .onChange(of: store.selectedProjectID) { _, _ in
            savedSummaries = []
            search = ""
            attentionOnly = false
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh += 1 } }
        .sheet(isPresented: $isCreatingSuite) { NewSuiteView(store: store) }
    }

    private var eyebrow: String {
        guard let repository = store.selectedProject.repository else { return "Project" }
        return "Project · " + URL(filePath: repository.rootPath).lastPathComponent
    }

    private var header: some View {
        WorkspacePageHeader(
            store.selectedProject.name,
            eyebrow: eyebrow,
            subtitle: "Your Foundation Models evaluations, at a glance."
        ) {
            Button { isCreatingSuite = true } label: {
                Label("New Suite", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
        }
    }

    private var suitePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePanelHeader("Suites", count: records.count) {
                WorkspaceSearchField(prompt: "Find a suite", text: $search)
                    .frame(maxWidth: 200)
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { attentionOnly.toggle() }
                } label: {
                    Image(systemName: attentionOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.title3)
                        .foregroundStyle(attentionOnly ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show only suites needing attention")
                .accessibilityValue(attentionOnly ? "On" : "Off")
                .help(attentionOnly ? "Show all suites" : "Show suites needing attention")
            }
            if attentionOnly {
                Label("Showing suites that need attention", systemImage: "flag.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(WorkspaceStyle.warning)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider()
            if visibleRecords.isEmpty {
                WorkspaceEmptyState(symbol: records.isEmpty ? "square.stack" : search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                                    title: records.isEmpty ? "Your first evaluation starts here" : search.isEmpty ? "Nothing needs attention" : "No matching suites",
                                    detail: records.isEmpty ? "Create a suite to organise your test cases and compare results." : search.isEmpty ? "Switch the filter off to see all your suites." : "Try another name or clear the filter.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRecords) { record in
                        WorkspaceSuiteRow(summary: summary(for: record), name: record.name,
                                          isRunning: store.isRunning && record.id == store.selectedSuiteID,
                                          disabled: isBusy, open: { open(record.id) }, run: { open(record.id, run: true) })
                        if record.id != visibleRecords.last?.id { Divider().padding(.leading, 64) }
                    }
                }
            }
            Divider()
            WorkspaceMetaLabel("Suites and evidence are saved on this Mac.", symbol: "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .workspaceSurface()
    }

    private func open(_ id: UUID, run: Bool = false) {
        do {
            if id != store.selectedSuiteID { try store.switchSuite(id: id) }
            store.selection = .suite
            if run { try runners.startSelectedRun(for: store) }
        } catch { store.notice = error.localizedDescription }
    }

    private func openLatest(_ summary: SuiteOverviewSummary) {
        guard let runID = summary.latestRunID else { return }
        do {
            if summary.id != store.selectedSuiteID { try store.switchSuite(id: summary.id) }
            store.selection = .run(runID)
        } catch { store.notice = error.localizedDescription }
    }
}

extension SuiteCheckState {
    var color: Color {
        switch self {
        case .passed: WorkspaceStyle.success
        case .failed: WorkspaceStyle.failure
        case .changed, .incomplete, .unavailable: WorkspaceStyle.warning
        case .notRun, .collected: .secondary
        }
    }

    var needsAttention: Bool {
        switch self {
        case .changed, .failed, .incomplete, .unavailable: true
        case .notRun, .passed, .collected: false
        }
    }
}
