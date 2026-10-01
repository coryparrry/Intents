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
            VStack(alignment: .leading, spacing: 26) {
                header
                if let notice = store.migrationNotice {
                    Label(notice, systemImage: "tray.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                }
                metrics
                DeveloperConnectionBanner()
                let layout = availableWidth >= 820
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 22))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                layout {
                    suitePanel.frame(maxWidth: .infinity)
                    VStack(spacing: 22) {
                        WorkspaceCoverageCard(summaries: summaries, total: records.count)
                        WorkspaceActivityCard(summaries: summaries, disabled: isBusy, open: openLatest)
                    }
                    .frame(maxWidth: availableWidth >= 820 ? 280 : .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 1_400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(WorkspaceStyle.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 56 } action: { availableWidth = $0 }
        .navigationTitle("Overview")
        .toolbar {
            Button("Refresh project", systemImage: "arrow.clockwise") { refresh += 1 }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                    Text("WORKSPACE").tracking(1.8)
                    if let repository = store.selectedProject.repository {
                        Text("/").padding(.horizontal, 4)
                        Text(URL(filePath: repository.rootPath).lastPathComponent)
                            .tracking(0).lineLimit(1).help(repository.rootPath)
                    }
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(store.selectedProject.name)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .tracking(-0.8).lineLimit(2)
                Text("Your Foundation Models evaluations, at a glance.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { isCreatingSuite = true } label: {
                Label("New suite", systemImage: "plus")
                    .font(.callout.weight(.semibold)).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(isBusy)
        }
        .padding(.bottom, 2)
    }

    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: availableWidth < 680 ? 2 : 4), spacing: 14) {
            WorkspaceMetric(title: "Active suites", value: records.count.formatted(),
                            detail: "In this project", symbol: "square.stack", color: .accentColor)
            WorkspaceMetric(title: "Test cases", value: summaries.contains { $0.loadError != nil } ? "—" : metricValue(summaries.reduce(0) { $0 + $1.caseCount }),
                            detail: summaries.contains { $0.loadError != nil } ? "Some suites unavailable" : "Across your suites",
                            symbol: "checklist", color: .secondary)
            WorkspaceMetric(title: "Passing suites", value: metricValue(summaries.filter { $0.state == .passed }.count),
                            detail: "Current checks only", symbol: "checkmark.circle", color: WorkspaceStyle.success)
            WorkspaceMetric(title: "Needs attention", value: metricValue(summaries.filter { $0.state.needsAttention }.count),
                            detail: "Changed or incomplete", symbol: "flag", color: WorkspaceStyle.warning)
        }
    }

    private func metricValue(_ count: Int) -> String {
        guard isLoaded else { return "—" }
        return count.formatted()
    }

    private var suitePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evaluation suites").font(.headline)
                Text(records.count.formatted()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { attentionOnly.toggle() }
                } label: {
                    Image(systemName: attentionOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(attentionOnly ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show only suites needing attention")
                .accessibilityValue(attentionOnly ? "On" : "Off")
                .help(attentionOnly ? "Show all suites" : "Show suites needing attention")
            }
            .padding(20)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Find a suite…", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Find a suite")
                if !search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(WorkspaceStyle.canvas, in: .rect(cornerRadius: 8))
            .padding(.horizontal, 20).padding(.bottom, 16)
            if attentionOnly {
                Text("Showing suites that need attention")
                    .font(.caption).foregroundStyle(WorkspaceStyle.warning)
                    .padding(.horizontal, 20).padding(.bottom, 12)
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
                        if record.id != visibleRecords.last?.id { Divider().padding(.leading, 68) }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text("Suites and evidence are saved on this Mac.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(WorkspaceStyle.canvas.opacity(0.5))
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
        case .failed: .red
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
