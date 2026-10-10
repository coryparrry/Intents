import SwiftUI

struct RunReportPresentation {
    let run: EvaluationRun

    var attentionCount: Int {
        run.effectiveResults.count {
            $0.status == .error || $0.status == .unscored
                || $0.errorCategory != nil || $0.errorMessage != nil
                || $0.judgeErrorCategory != nil || $0.judgeErrorMessage != nil
        }
    }

    var headline: String {
        if run.cancelled { return "This run was cancelled" }
        if run.results.isEmpty { return "No responses were collected" }
        if run.results.count < run.plannedResultCount { return "This run is incomplete" }
        if run.failedCount > 0 { return "Some responses failed their checks" }
        if attentionCount > 0 { return "Some responses need attention" }
        return "All responses passed their checks"
    }

    var nextStep: String {
        if run.cancelled || run.results.count < run.plannedResultCount || run.results.isEmpty {
            return "Review any collected responses below, then start a new run to complete the check."
        }
        if run.failedCount > 0 { return "Select a failed response below to see what did not match." }
        if attentionCount > 0 { return "Select a response with an issue below to see what needs attention." }
        return "Select a response below to read it and see why it passed."
    }
}

struct RunReportSummary: View {
    let run: EvaluationRun
    @State private var shown = false

    private var isIncomplete: Bool {
        run.cancelled || run.results.isEmpty || run.results.count < run.plannedResultCount
    }

    var body: some View {
        let presentation = RunReportPresentation(run: run)
        let mark: WorkspaceStatusMark.State = run.failedCount > 0 ? .failed
            : isIncomplete || presentation.attentionCount > 0 ? .attention : .passed
        HStack(alignment: .center, spacing: 32) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                WorkspaceStatusMark(state: shown ? mark : .running, size: 30)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 }
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.headline)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("Evaluation result headline")
                    Text(presentation.nextStep).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WorkspaceProportionBar(segments: [
                        WorkspaceRingSegment(count: run.passedCount, color: WorkspaceStyle.success),
                        WorkspaceRingSegment(count: run.failedCount, color: WorkspaceStyle.failure),
                        WorkspaceRingSegment(count: presentation.attentionCount, color: WorkspaceStyle.warning),
                        WorkspaceRingSegment(count: max(0, run.plannedResultCount - run.results.count), color: Color.secondary.opacity(0.25))
                    ], height: 6)
                    .frame(maxWidth: 320)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 30) {
                WorkspaceFigure(title: "Passed", value: run.passedCount.formatted())
                WorkspaceFigure(title: "Failed", value: run.failedCount.formatted())
                if presentation.attentionCount > 0 {
                    WorkspaceFigure(title: "To review", value: presentation.attentionCount.formatted())
                }
                WorkspaceFigure(title: "Collected", value: "\(run.results.count)/\(run.plannedResultCount)")
            }
            .fixedSize()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .task(id: run.id) {
            shown = false
            try? await Task.sleep(for: .milliseconds(150))
            shown = true
        }
    }
}
