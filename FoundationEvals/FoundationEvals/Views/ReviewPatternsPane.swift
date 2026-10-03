import SwiftUI

struct ReviewPatternsPane: View {
    @Bindable var store: EvaluationStore
    let openSample: (String, EvaluationReviewSample) -> Void
    private var patterns: [EvaluationFailurePattern] {
        EvaluationReviewWorkflow.patterns(samples: store.reviewSamples, state: store.suiteLocalState.review)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Only current, human-confirmed failures appear here. Counts describe these reviewed examples; several repetitions can belong to one case.")
                .font(.callout).foregroundStyle(.secondary)
            if patterns.isEmpty {
                WorkspaceEmptyState(symbol: "square.stack.3d.up", title: "No confirmed patterns yet",
                                    detail: "Review outputs in Samples and add a failure tag to a confirmed failure.")
                    .workspaceSurface()
            }
            ForEach(patterns) { pattern in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        WorkspacePill(pattern.tag, color: WorkspaceStyle.failure)
                        Spacer()
                        Text("\(pattern.samples.count) reviewed examples · \(pattern.caseCount) unique cases")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(pattern.samples.prefix(5)) { sample in
                        Button { openSample(pattern.tag, sample) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sample.sample.caseName).font(.callout.weight(.medium))
                                    Text(store.suiteLocalState.review.annotation(runID: sample.run.id, sampleID: sample.sample.id)?.note ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                    if pattern.samples.count > 5, let first = pattern.samples.first {
                        Button("Show all \(pattern.samples.count) examples") { openSample(pattern.tag, first) }
                            .buttonStyle(.borderless)
                    }
                }.padding(18).workspaceSurface()
            }
        }
    }
}
