import SwiftUI

struct WorkspaceOverviewView: View {
    @Bindable var store: EvaluationStore
    @State private var savedSummaries: [SuiteOverviewSummary] = []
    @State private var loader = WorkspaceOverviewLoader()
    @State private var refresh = 0
    @State private var isCreatingSuite = false
    @Environment(\.scenePhase) private var scenePhase

    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }

    private func summary(for record: EvaluationSuiteRecord) -> SuiteOverviewSummary? {
        if record.id == store.selectedSuiteID {
            var summary = SuiteOverviewSummary(record: record, suite: store.suite, currentRevision: store.suiteRevision,
                                        draft: store.draftSuite, runs: store.runs, localState: store.suiteLocalState)
            if let saved = savedSummaries.first(where: { $0.id == record.id }) {
                if saved.repositoryChanged { summary.state = .changed; summary.repositoryChanged = true }
                if saved.loadError != nil { summary.state = .unavailable; summary.loadError = saved.loadError }
            }
            return summary
        }
        return savedSummaries.first { $0.id == record.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let notice = store.migrationNotice {
                    Label(notice, systemImage: "tray.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Suites").font(.title3.weight(.semibold))
                        Text(store.suiteRecords.filter { !$0.isArchived }.count.formatted())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New suite", systemImage: "plus") { isCreatingSuite = true }
                            .disabled(isBusy)
                    }
                    .padding(.bottom, 14)
                    ForEach(store.suiteRecords.filter { !$0.isArchived }) { record in
                        SuiteOverviewRow(summary: summary(for: record), name: record.name,
                                         isRunning: store.isRunning && record.id == store.selectedSuiteID) {
                            open(record.id)
                        } run: {
                            open(record.id, run: true)
                        }
                        .disabled(isBusy)
                        Divider()
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checklist").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Build a set of checks you can trust").font(.headline)
                        Text("Keep a suite for each AI feature. Review its results, compare a change, then choose which run to approve as your baseline.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            }
            .padding(28)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(store.selectedProject.name)
        .toolbar {
            Button("Refresh project", systemImage: "arrow.clockwise") { refresh += 1 }
        }
        .task(id: "\(store.selectedProject.id)-\(store.selectedProject.updatedAt)-\(refresh)") {
            let values = await loader.load(project: store.selectedProject, directory: store.overviewStorageDirectory)
            guard !Task.isCancelled else { return }
            savedSummaries = values
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh += 1 } }
        .sheet(isPresented: $isCreatingSuite) { NewSuiteView(store: store) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("PROJECT", systemImage: "folder")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(store.selectedProject.name).font(.system(size: 30, weight: .semibold))
            if let repository = store.selectedProject.repository {
                Label(URL(filePath: repository.rootPath).lastPathComponent, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.callout).foregroundStyle(.secondary).help(repository.rootPath)
            } else {
                Text("Your AI features, their latest checks, and the evidence behind each result.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ id: UUID, run: Bool = false) {
        do {
            if id != store.selectedSuiteID { try store.switchSuite(id: id) }
            store.selection = .suite
            if run { store.startRun() }
        } catch { store.notice = error.localizedDescription }
    }
}

private struct SuiteOverviewRow: View {
    let summary: SuiteOverviewSummary?
    let name: String
    let isRunning: Bool
    let open: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.title2).foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(summary?.name ?? name).font(.headline).foregroundStyle(.primary)
                        if let summary {
                            Text("\(summary.caseCount) cases · \(summary.repetitions) repetitions")
                                .font(.callout).foregroundStyle(.secondary)
                            if let checked = summary.lastCheckedAt {
                                Text("Last run \(checked.formatted(date: .abbreviated, time: .shortened)) · \(summary.passedCount) passed · \(summary.failedCount) failed")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = summary.loadError {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                            if summary.repositoryChanged {
                                Text("The repository definition has changed.").font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Text("Loading saved results…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 10) {
                if isRunning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running…") }.font(.callout)
                } else if let summary {
                    Label(summary.state.title, systemImage: summary.state.symbol)
                        .font(.callout.weight(.medium)).foregroundStyle(summary.state.color)
                    if summary.approvedRunID != nil {
                        Label("Baseline approved", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Run checks", systemImage: "play.fill", action: run)
                        .controlSize(.small).disabled(summary.state == .unavailable)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Suite overview \(name)")
    }
}

extension SuiteCheckState {
    var color: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .changed, .incomplete, .unavailable: .orange
        case .notRun, .collected: .secondary
        }
    }
}
