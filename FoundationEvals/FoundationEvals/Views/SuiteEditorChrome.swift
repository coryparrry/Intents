import SwiftUI

enum SuiteSetupPage: String, WorkspacePane {
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
        case .scoring: "checkmark.seal.fill"
        case .model: "cpu"
        case .tools: "wrench.and.screwdriver.fill"
        case .output: "curlybraces"
        case .profile: "arrow.triangle.branch"
        case .performance: "gauge.with.dots.needle.50percent"
        }
    }
    var tint: Color {
        switch self {
        case .instructions: .blue
        case .scoring: .green
        case .model: .purple
        case .tools: .gray
        case .output: .pink
        case .profile: .teal
        case .performance: .orange
        }
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
            HStack(spacing: 12) {
                WorkspaceSymbolBadge(symbol: symbol, tint: .secondary, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .disclosureGroupStyle(.automatic)
        .padding(16)
        .workspaceSurface()
    }
}
