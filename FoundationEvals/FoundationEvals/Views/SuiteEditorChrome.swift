import SwiftUI

enum SuiteSetupPage: String, CaseIterable, Identifiable, Hashable {
    case instructions, scoring, model, tools, output, profile, performance

    static let basics: [Self] = [.instructions, .scoring, .model]
    static let advanced: [Self] = [.tools, .output, .profile, .performance]

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
        case .instructions: "What the model is told before every case"
        case .scoring: "How each response is marked pass or fail"
        case .model: "Which model answers, and its limits"
        case .tools: "Functions the model can call"
        case .output: "Ask for a fixed response shape"
        case .profile: "Change instructions between turns"
        case .performance: "Streaming and prewarming"
        }
    }
}

/// An optional group of settings that stays collapsed until needed.
struct SuiteOptionalSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .workspaceSurface()
    }
}
