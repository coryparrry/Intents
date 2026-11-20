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
        if run.failedCount > 0 {
            return run.results.count == 1 ? "The response failed its check" : "Some responses failed their checks"
        }
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

    /// Returns one completed response whose verdict is explained by its text check alone.
    private var singleTextCheck: EvaluationSampleResult? {
        guard run.selectedAssessment == nil, run.selectedAssessmentID == nil,
              !run.cancelled, !run.stoppedEarly, run.plannedResultCount == 1,
              run.scoringMode == .exactMatch || run.scoringMode == .containsExpected,
              run.results.count == 1, let result = run.results.first,
              result.status == .passed || result.status == .failed,
              attentionCount == 0,
              result.fieldAssertionResults?.isEmpty != false,
              !result.expected.isEmpty, result.rationale?.isEmpty == false else { return nil }
        return result
    }

    /// Keeps a single short text check readable at the top of a completed report.
    var shortTextCheck: EvaluationSampleResult? {
        guard let result = singleTextCheck, !result.response.isEmpty,
              result.expected.count <= 120, result.response.count <= 120 else { return nil }
        return result
    }

    /// Links a text mismatch to its case only if it still exists in the suite that produced the run.
    func editableFailedCase(in suite: EvaluationSuite) -> UUID? {
        guard suite.id == run.suiteID, suite.scoringMode == run.scoringMode,
              let result = singleTextCheck, result.status == .failed,
              suite.cases.contains(where: { $0.id == result.caseID }) else { return nil }
        return result.caseID
    }
}

struct RunReportSummary: View {
    let run: EvaluationRun
    let editCase: (() -> Void)?
    @State private var shown = false

    private var isIncomplete: Bool {
        run.cancelled || run.results.isEmpty || run.results.count < run.plannedResultCount
    }

    var body: some View {
        let presentation = RunReportPresentation(run: run)
        let shortCheck = presentation.shortTextCheck
        VStack(alignment: .leading, spacing: 12) {
            overview(presentation, showsNextStep: shortCheck == nil)
            if let result = shortCheck, let explanation = result.rationale {
                Divider()
                LabeledText(label: "Expected answer", text: result.expected)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("Short check expected answer")
                LabeledText(label: "Response", text: result.response)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("Short check response")
                LabeledText(label: result.status == .passed ? "Why it passed" : "Why it failed", text: explanation)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("Short check explanation")
            }
            if let editCase {
                Text(run.scoringMode == .exactMatch
                     ? "Exact text checks the whole response, including punctuation. Correct the expected answer if it’s wrong. Otherwise, clarify the prompt. Then select Run again."
                     : "Correct the required text if it’s wrong. Otherwise, clarify what the prompt should include. Then select Run again.")
                    .font(.callout)
                    .foregroundStyle(WorkspaceStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Failed check next step")
                Button("Edit case", systemImage: "pencil", action: editCase)
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .task(id: run.id) {
            shown = false
            try? await Task.sleep(for: .milliseconds(150))
            shown = true
        }
    }

    /// Shows the run outcome and counts alongside the evidence the reader can inspect.
    private func overview(_ presentation: RunReportPresentation, showsNextStep: Bool) -> some View {
        let mark: WorkspaceStatusMark.State = run.failedCount > 0 ? .failed
            : isIncomplete || presentation.attentionCount > 0 ? .attention : .passed
        return HStack(alignment: .center, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                WorkspaceStatusMark(state: shown ? mark : .running, size: 30)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 }
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.headline)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("Evaluation result headline")
                    if showsNextStep {
                        Text(presentation.nextStep).font(.callout).foregroundStyle(WorkspaceStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WorkspaceProportionBar(segments: [
                        WorkspaceRingSegment(count: run.passedCount, color: WorkspaceStyle.success),
                        WorkspaceRingSegment(count: run.failedCount, color: WorkspaceStyle.failure),
                        WorkspaceRingSegment(count: presentation.attentionCount, color: WorkspaceStyle.warning),
                        WorkspaceRingSegment(count: max(0, run.plannedResultCount - run.results.count), color: Color.secondary.opacity(0.25))
                    ], height: 6)
                    .frame(maxWidth: 320)
                    .padding(.top, 4)
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
    }
}
