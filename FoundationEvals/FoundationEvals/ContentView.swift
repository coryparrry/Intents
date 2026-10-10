import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: EvaluationStore
    @State private var productionWorkspace: ProductionWorkspaceStore
    @State private var automationStore: AppAutomationStore
    @State private var scenarioCoordinator: ScenarioCoordinator
    @Environment(DeveloperRunnerStore.self) private var runners
    @Environment(\.controlActiveState) private var windowActivity
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(store: EvaluationStore, control: EvaluationAppControl? = nil, automationStore: AppAutomationStore? = nil) {
        self.store = store
        let control = control ?? EvaluationAppControl(store: store)
        _productionWorkspace = State(initialValue: control.production)
        _scenarioCoordinator = State(initialValue: control.scenarios)
        _automationStore = State(initialValue: automationStore ?? AppAutomationStore(supportDirectory: store.overviewStorageDirectory.appendingPathComponent("Automation"), telemetry: store.telemetry))
    }

    var body: some View {
        // Pin the layout to the window so tall pages scroll instead of growing the window past the screen.
        GeometryReader { geometry in
            workspaceNavigation
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(minWidth: 1_000, minHeight: 700)
        .toolbar(removing: .title)
        .background { SuiteAutosaveObserver(store: store) }
        .task {
            await automationStore.migrateEvidenceHistory()
            await scenarioCoordinator.refreshAutomationEvidence()
        }
        .onChange(of: automationStore.evidenceImportRevision) { _, _ in
            Task { await scenarioCoordinator.refreshAutomationEvidence() }
        }
        .onChange(of: store.telemetry?.isEnabled) { _, _ in recordScreen() }
        .onChange(of: store.selection, initial: true) { _, _ in recordScreen() }
        .onChange(of: windowActivity, initial: true) { _, activity in
            if activity == .key { recordScreen() }
        }
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

    private func recordScreen() {
        guard windowActivity == .key else { return }
        store.telemetry?.screen(TelemetryScreen(selection: store.selection))
    }

    private var workspaceNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) { detail }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .workspacePageTransition(value: WorkspacePageLocation(
                        selection: store.selection, suiteID: store.selectedSuiteID
                    ))
            }
                // Pages are dense with text, so bars get a solid edge that keeps their controls legible.
                .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    WorkbenchStatusBar(store: store)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("Workspace status")
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .overview:
            WorkspaceOverviewView(store: store)
        case .intentLab:
            IntentLabView(coordinator: scenarioCoordinator, store: store, projects: store.projects)
        case .evaluations:
            SuiteEditorView(store: store, initialPage: .review)
                .disclosureGroupStyle(FullWidthDisclosureStyle())
        case .batchRuns:
            ProductionWorkspaceView(model: productionWorkspace, store: store)
        case .traces:
            WorkspaceTracesView(store: store)
        case .appAutomation:
            AppAutomationView(model: automationStore)
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
}

private struct WorkspacePageLocation: Equatable {
    let selection: SidebarSelection
    let suiteID: UUID
}
