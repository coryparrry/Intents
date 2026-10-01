import SwiftUI

struct IntentLabView: View {
    @Bindable var coordinator: ScenarioCoordinator
    let projects: [EvaluationProject]
    @State private var section: IntentLabSection = .setup

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                IntentLabHeader(coordinator: coordinator, section: section)
                switch section {
                case .setup:
                    ScrollView {
                        AppleTestConnectionView(coordinator: coordinator, onContinue: { section = .scenario })
                            .frame(maxWidth: 960, alignment: .leading).workspacePage()
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .scenario:
                    ScrollView {
                        ScenarioEditorView(coordinator: coordinator, projects: projects)
                            .frame(maxWidth: 960, alignment: .leading).workspacePage()
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .results:
                    ScenarioReportView(coordinator: coordinator, onSetup: { section = .setup }, onCreateTest: { section = .scenario })
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
                    Button { section = .results; Task { await coordinator.run() } } label: {
                        Label("Run test", systemImage: "play.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.preflight?.isReady != true)
                    .help(coordinator.preflight?.isReady == true ? "Save and run this test" : "Finish setup to run a test")
                }
            }
        }
        .task { await coordinator.load() }
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
    case results = "Results"

    var id: Self { self }

    var subtitle: String {
        switch self {
        case .setup: "Choose your app and the device you want to test on."
        case .scenario: "Describe an action and the result you expect."
        case .results: "See what worked, what was checked, and what to do next."
        }
    }
}

private struct IntentLabHeader: View {
    @Bindable var coordinator: ScenarioCoordinator
    let section: IntentLabSection

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            WorkspaceIcon(symbol: "intent-lab", size: 40, presentation: .header)
            VStack(alignment: .leading, spacing: 3) {
                Text("Intent Lab")
                    .font(.system(size: 22, weight: .bold)).tracking(-0.2)
                    .accessibilityIdentifier("Intent Lab page title")
                Text(section.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if section != .results { IntentLabReadiness(coordinator: coordinator) }
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
                Text("Running on device").font(.callout).foregroundStyle(.secondary)
            }
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
