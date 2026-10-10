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
    private var hasAnyRun: Bool { summaries.contains { $0.lastCheckedAt != nil } }
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
            VStack(alignment: .leading, spacing: 28) {
                header
                if let notice = store.migrationNotice {
                    WorkspaceNotice(.info, message: notice)
                }
                Group {
                    if isLoaded, !hasAnyRun {
                        HomeOnboarding(
                            hasSuite: !records.isEmpty,
                            hasCases: summaries.contains { $0.caseCount > 0 },
                            disabled: isBusy,
                            primaryTitle: records.first.map { "Open \(summary(for: $0)?.name ?? $0.name)" } ?? "Create a Suite"
                        ) {
                            if let first = records.first { open(first.id) } else { isCreatingSuite = true }
                        }
                    } else {
                        HomeHero(summaries: summaries, total: records.count, isLoaded: isLoaded, compact: availableWidth < 760)
                    }
                }
                .transition(.blurReplace)
                gallery
                if hasAnyRun {
                    VStack(alignment: .leading, spacing: 14) {
                        WorkspaceSectionTitle("Recent runs")
                        RecentRunsTimeline(summaries: summaries, disabled: isBusy, open: openRun)
                    }
                    .transition(.opacity)
                }
                DeveloperConnectionBanner()
            }
            .animation(reduceMotion ? nil : WorkspaceStyle.pageMotion, value: isLoaded)
            .animation(reduceMotion ? nil : WorkspaceStyle.pageMotion, value: hasAnyRun)
            .workspacePage()
        }
        .background(WorkspaceStyle.canvas)
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, WorkspaceStyle.readableWidth) - 2 * WorkspaceStyle.pagePadding } action: { availableWidth = $0 }
        .navigationTitle("Overview")
        .searchable(text: $search, placement: .toolbar, prompt: "Find a suite")
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
            subtitle: "See how Apple’s Foundation Models answer your prompts."
        ) {
            Button { isCreatingSuite = true } label: {
                Label("New Suite", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSectionTitle("Suites", count: records.count) {
                Picker("Show", selection: $attentionOnly) {
                    Text("All").tag(false)
                    Text("Needs attention").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show only suites needing attention")
            }
            if visibleRecords.isEmpty, !records.isEmpty {
                WorkspaceEmptyState(symbol: search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                                    title: search.isEmpty ? "Nothing needs attention" : "No matching suites",
                                    detail: search.isEmpty ? "Every suite is passing or waiting for its first run." : "Try another name or clear the search.")
                    .workspaceSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                        SuiteRow(summary: summary(for: record), name: record.name,
                                 isRunning: store.isRunning && record.id == store.selectedSuiteID,
                                 disabled: isBusy, open: { open(record.id) }, run: { open(record.id, run: true) })
                            .transition(.opacity)
                        if index < visibleRecords.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 4)
                .workspaceSurface()
                .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: visibleRecords.map(\.id))
            }
        }
    }

    private func open(_ id: UUID, run: Bool = false) {
        do {
            if id != store.selectedSuiteID { try store.switchSuite(id: id) }
            store.selection = .suite
            if run { try runners.startSelectedRun(for: store) }
        } catch { store.notice = error.localizedDescription }
    }

    private func openRun(_ summary: SuiteOverviewSummary, _ runID: UUID) {
        do {
            if summary.id != store.selectedSuiteID { try store.switchSuite(id: summary.id) }
            store.selection = .run(runID)
        } catch { store.notice = error.localizedDescription }
    }
}
