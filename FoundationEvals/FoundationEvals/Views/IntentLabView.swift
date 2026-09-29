import SwiftUI

struct IntentLabView: View {
    @Bindable var coordinator: ScenarioCoordinator
    @Bindable var store: EvaluationStore
    let projects: [EvaluationProject]
    @Environment(DeveloperRunnerStore.self) private var runnerStore
    @State private var section: IntentLabSection = .setup
    @State private var diagnosticLanes: Set<ScenarioLane> = []

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                IntentLabHeader(coordinator: coordinator)
                switch section {
                case .setup:
                    ScrollView {
                        AppleTestConnectionView(coordinator: coordinator, onContinue: { section = .scenario }).workspacePage()
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .scenario:
                    ScrollView {
                        ScenarioEditorView(
                            coordinator: coordinator, projects: projects,
                            diagnosticLanes: $diagnosticLanes
                        ).workspacePage()
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .collections:
                    ScenarioCollectionView(coordinator: coordinator)
                case .results:
                    ScenarioReportView(coordinator: coordinator, store: store, onSetup: { section = .setup })
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(WorkspaceStyle.canvas)
        .disclosureGroupStyle(IntentLabDisclosureStyle())
        .navigationTitle("Intent Lab")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Intent Lab section", selection: $section) {
                    ForEach(IntentLabSection.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Intent Lab section")
            }
            ToolbarItem(placement: .primaryAction) {
                if coordinator.isRunning {
                    Button("Cancel", systemImage: "stop.fill", role: .destructive) { Task { await coordinator.cancel() } }
                        .labelStyle(.titleAndIcon)
                        .help("Cancel the running scenario")
                } else {
                    if coordinator.draft.schemaVersion == ScenarioDefinition.stableSchemaVersion {
                        Button { section = .results; Task { await coordinator.checkThisFix(on: diagnosticLanes) } } label: {
                            Label("Check this fix", systemImage: "play.circle")
                        }
                        .disabled(diagnosticLanes.isEmpty || !coordinator.hasLoaded)
                        .help("Run selected routes as a partial diagnostic on the candidate app build")
                        Button { section = .results; Task { await coordinator.run() } } label: {
                            Label("Verify complete requirement", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.hasLoaded)
                        .help("Check every required route and attempt before qualification")
                    } else {
                        Button { section = .results; Task { await coordinator.run() } } label: {
                            Label("Run test", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.preflight?.isReady != true)
                    }
                }
            }
        }
        .task {
            coordinator.bindRunnerStore(runnerStore)
            await coordinator.load()
        }
        .onChange(of: coordinator.draft.id) { _, _ in diagnosticLanes.removeAll() }
        .onChange(of: coordinator.draft.coverage) { _, coverage in
            diagnosticLanes = diagnosticLanes.filter { coverage[$0] != .notApplicable }
        }
        .alert(
            "Intent Lab",
            isPresented: Binding(
                get: { coordinator.notice != nil },
                set: { if !$0 { coordinator.notice = nil } }
            )
        ) {
            Button("OK") { coordinator.notice = nil }
        } message: {
            Text(coordinator.notice ?? "")
        }
    }
}

private enum IntentLabSection: String, CaseIterable, Identifiable {
    case setup = "Connect app"
    case scenario = "Create test"
    case collections = "Collections"
    case results = "Results"

    var id: Self { self }
}

private struct IntentLabHeader: View {
    @Bindable var coordinator: ScenarioCoordinator

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            WorkspaceIcon(symbol: "intent-lab", size: 40, presentation: .header)
            VStack(alignment: .leading, spacing: 3) {
                Text("Intent Lab")
                    .font(.system(size: 22, weight: .bold)).tracking(-0.2)
                    .accessibilityIdentifier("Intent Lab page title")
                Text("Connect your app, choose an action, and check that it works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            IntentLabReadiness(coordinator: coordinator)
        }
        .padding(.horizontal, WorkspaceStyle.pagePadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct IntentLabReadiness: View {
    let coordinator: ScenarioCoordinator

    var body: some View {
        if coordinator.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(coordinator.executionStage ?? "Running on device")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if coordinator.routeReadiness.values.contains(where: { $0.state == .ready }) {
            WorkspacePill("Route ready", symbol: "checkmark.circle.fill", color: WorkspaceStyle.success)
        } else if coordinator.preflight?.isReady == true {
            WorkspacePill("Ready to run", symbol: "checkmark.circle.fill", color: WorkspaceStyle.success)
        } else {
            WorkspacePill("Setup needed", symbol: "circle.dashed", color: .secondary)
        }
    }
}

struct IntentLabCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        EditorSection(
            LocalizedStringResource(stringLiteral: title),
            systemImage: "checklist",
            description: LocalizedStringResource(stringLiteral: subtitle ?? "")
        ) {
            content
        }
    }
}

struct ScenarioOutcomeBadge: View {
    let outcome: ScenarioOutcome

    var body: some View {
        WorkspacePill(title, symbol: symbol, color: color)
    }

    private var title: String {
        switch outcome {
        case .passed: "Passed"
        case .failed: "Failed"
        case .needsReview: "Needs review"
        case .notObserved: "Not observed"
        case .notApplicable: "Not applicable"
        }
    }

    private var symbol: String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .needsReview: "person.crop.circle.badge.questionmark"
        case .notObserved: "questionmark.circle"
        case .notApplicable: "minus.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .passed: WorkspaceStyle.success
        case .failed: WorkspaceStyle.failure
        case .needsReview: WorkspaceStyle.warning
        case .notObserved, .notApplicable: .secondary
        }
    }
}

/// Makes the full heading a keyboard-accessible toggle, with a clear expanded state.
private struct IntentLabDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
