import SwiftUI

struct IntentLabView: View {
    @Bindable var coordinator: ScenarioCoordinator
    let projects: [EvaluationProject]
    @State private var section: IntentLabSection = .setup

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                IntentLabHeader(coordinator: coordinator, section: $section)
                Divider()
                switch section {
                case .setup:
                    ScrollView {
                        AppleTestConnectionView(coordinator: coordinator)
                            .frame(maxWidth: 1_080)
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .scenario:
                    ScrollView {
                        ScenarioEditorView(coordinator: coordinator, projects: projects)
                            .frame(maxWidth: 1_080)
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                case .results:
                    ScenarioReportView(coordinator: coordinator)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(WorkspaceStyle.canvas)
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
    case setup = "Setup"
    case scenario = "Scenario"
    case results = "Results"

    var id: Self { self }
}

private struct IntentLabHeader: View {
    @Bindable var coordinator: ScenarioCoordinator
    @Binding var section: IntentLabSection

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Intent Lab")
                            .font(.system(size: 26, weight: .semibold))
                            .accessibilityIdentifier("Intent Lab page title")
                        Text("An App Intent makes an app action available to system features such as Shortcuts. With Siri support configured, you can test requests too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if coordinator.isRunning {
                        Button("Cancel", role: .destructive) { Task { await coordinator.cancel() } }
                    } else {
                        Button("Run scenario", systemImage: "play.fill") { Task { await coordinator.run() } }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .disabled(coordinator.preflight?.isReady != true)
                    }
                }
                Label("Setup: connect your app · Scenario: define a test · Results: see what passed", systemImage: "checklist")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 26) {
                ForEach(IntentLabSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        VStack(spacing: 13) {
                            Text(item.rawValue)
                                .font(.callout.weight(section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? Color.primary : .secondary)
                            Capsule().fill(section == item ? Color.accentColor : .clear).frame(height: 2)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Intent Lab section")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .background(WorkspaceStyle.surface)
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
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
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
        case .passed: .green
        case .failed: .red
        case .needsReview: .orange
        case .notObserved, .notApplicable: .secondary
        }
    }
}

protocol IntentLabEditorPage: CaseIterable, Identifiable, Hashable {
    var title: String { get }
    var subtitle: String { get }
    var symbol: String { get }
}

/// Mirrors the suite setup navigation and editor pane, including its compact layout.
struct IntentLabEditorLayout<Page: IntentLabEditorPage, Content: View>: View {
    let heading: String
    @Binding var selection: Page
    @ViewBuilder var content: Content
    @State private var availableWidth: CGFloat = 900

    var body: some View {
        let wide = availableWidth >= 824
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        layout {
            if wide {
                VStack(alignment: .leading, spacing: 5) {
                    Text(heading)
                        .font(.system(size: 9, weight: .semibold)).tracking(1.3)
                        .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 9)
                    ForEach(Array(Page.allCases)) { page in
                        Button { selection = page } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol).frame(width: 17)
                                Text(page.title)
                                Spacer(minLength: 0)
                                if page == selection {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: 15)
                                }
                            }
                            .font(.callout.weight(page == selection ? .semibold : .regular))
                            .foregroundStyle(page == selection ? Color.accentColor : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 11)
                            .background(page == selection ? Color.accentColor.opacity(0.07) : .clear,
                                        in: .rect(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == selection ? .isSelected : [])
                        .accessibilityHint(page.subtitle)
                    }
                }
                .frame(width: 175)
            } else {
                Picker(heading, selection: $selection) {
                    ForEach(Array(Page.allCases)) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.title).font(.title2.weight(.bold))
                    Text(selection.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}
