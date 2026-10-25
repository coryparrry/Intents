import Foundation

/// Plain-language summaries shared by the comparison screens and their regression tests.
struct PromptImprovementPresentation {
    let report: EvaluationPromptImprovement
    var isActive = false
    var isStale = false

    var title: String {
        if isActive { return "Comparing instructions" }
        if report.appliedAt != nil { return "Suggestion applied" }
        switch report.status {
        case .running: return "Comparison interrupted"
        case .cancelled: return "Comparison cancelled"
        case .failed: return "Comparison couldn’t finish"
        case .noImprovement: return "Keep your current instructions"
        case .completed:
            if report.canApply { return isStale ? "Your suite has changed" : "A better suggestion is ready" }
            return "Keep your current instructions"
        }
    }

    var detail: String {
        if isActive { return "You can leave this window open or close it. The comparison will continue while the app is open." }
        if report.appliedAt != nil { return "The suggested instructions are now saved in your suite. Your previous instructions are kept in this comparison." }
        switch report.status {
        case .running: return "The app stopped before the comparison finished. Start a new comparison to get a complete result."
        case .cancelled: return "Your instructions haven’t changed. You can start a new comparison whenever you’re ready."
        case .failed: return "Your instructions haven’t changed. Review the details below, then try again."
        case .noImprovement: return "Neither suggestion passed more practice examples. The examples saved for the final check weren’t used."
        case .completed:
            if report.canApply {
                return isStale
                    ? "This result belongs to an earlier version of your suite. Start a new comparison to protect your recent edits."
                    : "The suggestion passed more practice examples and did at least as well on every final-check example. Review the instructions before using it."
            }
            return "The suggestion didn’t pass the final check. It can’t be applied; your current instructions are still saved."
        }
    }

    var step: Int {
        guard report.developmentBaseline != nil else { return 0 }
        guard !report.candidates.isEmpty else { return 1 }
        guard report.selectedCandidateID != nil else { return 2 }
        return 3
    }

    var progressDetail: String {
        switch step {
        case 0: return "Running your current instructions on the practice examples."
        case 1: return "Writing two suggestions from the practice results. Final-check examples stay private from this step."
        case 2:
            let tested = report.candidates.filter { $0.developmentRun != nil }.count
            return "Testing suggestion \(min(tested + 1, 2)) of 2 on the same practice examples."
        default: return "Checking the best suggestion against your current instructions on the reserved examples."
        }
    }

    static func maximumSamples(suite: EvaluationSuite, heldOutCaseIDs: Set<UUID>) -> Int? {
        guard EvaluationPromptImprovementRules.validationIssue(suite: suite, heldOutCaseIDs: heldOutCaseIDs) == nil else { return nil }
        return EvaluationPromptImprovement(source: suite, heldOutCaseIDs: heldOutCaseIDs).maximumSamples
    }

    static func scoreSummary(_ run: EvaluationRun?) -> String {
        guard let run else { return "Not run" }
        guard !run.cancelled, run.terminationReason == nil, run.errorCount == 0,
              run.results.count == run.plannedResultCount, run.scoredCount == run.plannedResultCount else {
            return "Incomplete"
        }
        return "\(run.passedCount) / \(run.plannedResultCount)"
    }

    static func setupIssue(suite: EvaluationSuite, heldOutCaseIDs: Set<UUID>) -> String? {
        if suite.cases.count < 2 { return "Add at least two cases: one to practice with and one for the final check." }
        if suite.scoringMode == .review { return "Choose a scoring method so Intents can compare which instructions work better." }
        if heldOutCaseIDs.isEmpty || heldOutCaseIDs.count == suite.cases.count {
            return "Keep at least one practice example and one final-check example."
        }
        return EvaluationPromptImprovementRules.validationIssue(suite: suite, heldOutCaseIDs: heldOutCaseIDs)
    }
}
