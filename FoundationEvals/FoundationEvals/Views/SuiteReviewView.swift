import SwiftUI

enum SuiteReviewPage: String, WorkspacePane {
    case samples, patterns, judges
    var id: Self { self }
    var title: String { switch self { case .samples: "Samples"; case .patterns: "Patterns"; case .judges: "Judge checks" } }
    var subtitle: String {
        switch self {
        case .samples: "Review captured outputs and explain what matters."
        case .patterns: "Find recurring problems in confirmed human reviews."
        case .judges: "Check judging against reviewed development and held-out examples."
        }
    }
    var symbol: String { switch self { case .samples: "text.bubble"; case .patterns: "square.stack.3d.up"; case .judges: "checkmark.seal" } }
}

struct SuiteReviewView: View {
    @Bindable var store: EvaluationStore
    let showCases: (UUID) -> Void
    let showCompare: () -> Void
    @State private var page = SuiteReviewPage.samples
    @State private var selectedSampleID: String?
    @State private var selectedTag: String?

    var body: some View {
        WorkspacePaneLayout(heading: "Review", selection: $page) {
            switch page {
            case .samples:
                ReviewSamplesPane(store: store, selectedID: $selectedSampleID, selectedTag: $selectedTag,
                                  showCases: showCases, showCompare: showCompare)
            case .patterns:
                ReviewPatternsPane(store: store) { tag, sample in
                    selectedTag = tag; selectedSampleID = sample.id; page = .samples
                }
            case .judges:
                ReviewJudgeChecksPane(store: store)
            }
        }
        .accessibilityIdentifier("Suite review")
    }
}

private enum ReviewSampleFilter: String, CaseIterable, Identifiable {
    case all, unreviewed, failed, needsEvidence
    var id: Self { self }
    var title: String {
        switch self { case .all: "All samples"; case .unreviewed: "Not reviewed"; case .failed: "Human failures"; case .needsEvidence: "Needs more evidence" }
    }
}

private struct ReviewSamplesPane: View {
    @Bindable var store: EvaluationStore
    @Binding var selectedID: String?
    @Binding var selectedTag: String?
    let showCases: (UUID) -> Void
    let showCompare: () -> Void
    @State private var search = ""
    @State private var filter = ReviewSampleFilter.all
    @State private var diverse = true
    @State private var availableWidth: CGFloat = 900

    private var samples: [EvaluationReviewSample] {
        let ordered = diverse ? EvaluationReviewWorkflow.diverseQueue(store.reviewSamples) : store.reviewSamples
        return ordered.filter { sample in
            let annotation = store.suiteLocalState.review.annotation(runID: sample.run.id, sampleID: sample.sample.id)
            let current = annotation.flatMap { EvaluationReviewWorkflow.isCurrent($0, sample: sample) ? $0 : nil }
            let matchesFilter = switch filter {
            case .all: true
            case .unreviewed: current == nil
            case .failed: current?.verdict == .failed
            case .needsEvidence: current?.verdict == .needsEvidence || !sample.sample.hasCompleteSubjectEvidenceForJudging
            }
            return matchesFilter && (selectedTag == nil || current?.tags.contains(selectedTag!) == true)
                && (search.isEmpty || [sample.sample.caseName, sample.sample.prompt, sample.sample.response,
                                      current?.note ?? "", current?.tags.joined(separator: " ") ?? ""].contains {
                    $0.localizedCaseInsensitiveContains(search)
                })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Review filter", selection: $filter) { ForEach(ReviewSampleFilter.allCases) { Text($0.title).tag($0) } }
                    .fixedSize().accessibilityIdentifier("Review filter")
                Toggle("Diverse order", isOn: $diverse).toggleStyle(.checkbox)
                Spacer()
            }
            Text("This discovery queue mixes coverage across cases, models and locales with shuffled examples. It does not estimate a production failure rate.")
                .font(.caption).foregroundStyle(.secondary)
            if let selectedTag {
                HStack {
                    WorkspacePill(selectedTag, color: WorkspaceStyle.failure)
                    Button("Clear tag filter") { self.selectedTag = nil }
                }
            }
            let layout = availableWidth >= 680
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            layout {
                sampleList.frame(width: availableWidth >= 680 ? 250 : nil)
                if let sample = samples.first(where: { $0.id == selectedID }) {
                    ReviewSampleEditor(store: store, sample: sample, showCases: showCases, showCompare: showCompare)
                        .id(sample.id + sample.sourceDigest)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WorkspaceEmptyState(symbol: "text.bubble", title: "Choose a saved output",
                                        detail: store.reviewSamples.isEmpty ? "Run a suite or collect app feature responses to start reviewing." : "Select a sample to review its output and captured evidence.")
                        .frame(maxWidth: .infinity).workspaceSurface()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: samples.map(\.id), initial: true) { _, ids in
            if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
        }
    }

    private var sampleList: some View {
        VStack(spacing: 0) {
            WorkspacePanelHeader("Saved outputs", count: samples.count)
            WorkspaceSearchField(prompt: "Find an output", text: $search, identifier: "Search review samples")
                .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(samples) { sample in
                        let annotation = store.suiteLocalState.review.annotation(runID: sample.run.id, sampleID: sample.sample.id)
                        let current = annotation.flatMap { EvaluationReviewWorkflow.isCurrent($0, sample: sample) ? $0 : nil }
                        Button { selectedID = sample.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sample.sample.caseName).font(.callout.weight(sample.id == selectedID ? .semibold : .medium)).lineLimit(1)
                                Text(sample.sample.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(current?.verdict.title ?? (annotation == nil ? "Not reviewed" : "Source changed"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(sample.id == selectedID ? Color.accentColor.opacity(0.12) : .clear,
                                        in: .rect(cornerRadius: WorkspaceStyle.controlRadius))
                            .overlay(alignment: .leading) {
                                if sample.id == selectedID { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 9) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(sample.sample.caseName), repetition \(sample.sample.repetition), \(current?.verdict.title ?? "not reviewed")")
                        .accessibilityIdentifier("Review sample \(sample.sample.id)")
                        .accessibilityAddTraits(sample.id == selectedID ? .isSelected : [])
                    }
                }.padding(6)
            }.frame(maxHeight: 480)
        }.workspaceSurface()
    }
}
