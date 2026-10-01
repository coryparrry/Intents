import SwiftUI

enum SuiteSetupPage: String, CaseIterable, Identifiable {
    case instructions, scoring, model, tools, output, profile, performance
    var id: Self { self }
    var title: String {
        switch self {
        case .instructions: "Instructions"
        case .scoring: "Scoring"
        case .model: "Model"
        case .tools: "Tools"
        case .output: "Structured output"
        case .profile: "Session profile"
        case .performance: "Performance"
        }
    }
    var subtitle: String {
        switch self {
        case .instructions: "Prompt & shared context"
        case .scoring: "What a good answer means"
        case .model: "Provider & generation"
        case .tools: "Functions the model can call"
        case .output: "Response shape & fields"
        case .profile: "Instructions between turns"
        case .performance: "Streaming & prewarming"
        }
    }
    var symbol: String {
        switch self {
        case .instructions: "text.alignleft"
        case .scoring: "checkmark.seal"
        case .model: "cpu"
        case .tools: "wrench.and.screwdriver"
        case .output: "curlybraces"
        case .profile: "arrow.triangle.branch"
        case .performance: "gauge.with.dots.needle.50percent"
        }
    }
}

struct SuiteSetupNavigation: View {
    @Binding var selection: SuiteSetupPage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SUITE SETUP")
                .font(.system(size: 9, weight: .semibold)).tracking(1.3)
                .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 9)
            ForEach(SuiteSetupPage.allCases) { page in
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
                .accessibilityIdentifier("Setup \(page.rawValue)")
            }
        }
        .frame(width: 175)
    }
}

struct SuiteOptionalSection<Content: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content.padding(.top, 16)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        }
        .disclosureGroupStyle(.automatic)
        .padding(18)
        .workspaceSurface()
    }
}
