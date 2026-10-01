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

    var body: some View {
        let presentation = RunReportPresentation(run: run)
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.headline)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("Evaluation result headline")
            WorkspaceFlowLayout(spacing: 16, lineSpacing: 8) {
                Label("\(run.passedCount) passed", systemImage: "checkmark.circle")
                    .foregroundStyle(WorkspaceStyle.success)
                Label("\(run.failedCount) failed", systemImage: "xmark.circle")
                    .foregroundStyle(run.failedCount > 0 ? WorkspaceStyle.failure : Color.secondary)
                if presentation.attentionCount > 0 {
                    Label("\(presentation.attentionCount) need attention", systemImage: "exclamationmark.circle")
                        .foregroundStyle(WorkspaceStyle.warning)
                }
                Text("\(run.results.count) of \(run.plannedResultCount) responses collected")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Text(presentation.nextStep).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}
