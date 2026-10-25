import Foundation

enum EvaluationPromptImprovementStatus: String, Codable, Sendable {
    case running, completed, noImprovement, failed, cancelled
}

struct EvaluationPromptCandidate: Identifiable, Codable, Sendable {
    var id = UUID()
    var instructions: String
    var developmentRun: EvaluationRun?
}

struct EvaluationPromptImprovement: Identifiable, Codable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var source: EvaluationSuite
    var heldOutCaseIDs: Set<UUID>
    var status = EvaluationPromptImprovementStatus.running
    var message = "Preparing Development baseline"
    var candidates: [EvaluationPromptCandidate] = []
    var developmentBaseline: EvaluationRun?
    var heldOutBaseline: EvaluationRun?
    var heldOutCandidate: EvaluationRun?
    var selectedCandidateID: UUID?
    var appliedAt: Date?

    var developmentSuite: EvaluationSuite { partition(heldOut: false) }
    var heldOutSuite: EvaluationSuite { partition(heldOut: true) }
    var selectedCandidate: EvaluationPromptCandidate? { candidates.first { $0.id == selectedCandidateID } }
    var maximumSamples: Int { (developmentSuite.cases.count * 3 + heldOutCaseIDs.count * 2) * source.repetitions }
    var runs: [EvaluationRun] {
        [developmentBaseline].compactMap { $0 } + candidates.compactMap(\.developmentRun)
            + [heldOutBaseline, heldOutCandidate].compactMap { $0 }
    }

    var canApply: Bool {
        guard EvaluationPromptImprovementRules.validationIssue(suite: source, heldOutCaseIDs: heldOutCaseIDs) == nil,
              status == .completed, let selectedCandidate else { return false }
        var candidateDevelopment = developmentSuite
        candidateDevelopment.instructions = selectedCandidate.instructions
        var candidateHeldOut = heldOutSuite
        candidateHeldOut.instructions = selectedCandidate.instructions
        guard
              let baseline = developmentBaseline, let development = selectedCandidate.developmentRun,
              let heldBaseline = heldOutBaseline, let heldCandidate = heldOutCandidate,
              EvaluationPromptImprovementRules.isComplete(baseline, for: developmentSuite),
              EvaluationPromptImprovementRules.isComplete(development, for: candidateDevelopment),
              EvaluationPromptImprovementRules.isComplete(heldBaseline, for: heldOutSuite),
              EvaluationPromptImprovementRules.isComplete(heldCandidate, for: candidateHeldOut),
              development.instructions == selectedCandidate.instructions,
              heldCandidate.instructions == selectedCandidate.instructions,
              baseline.instructions == source.instructions, heldBaseline.instructions == source.instructions,
              development.passedCount > baseline.passedCount else { return false }
        return heldOutSuite.cases.allSatisfy { test in
            heldCandidate.effectiveResults.count { $0.caseID == test.id && $0.status == .passed }
                >= heldBaseline.effectiveResults.count { $0.caseID == test.id && $0.status == .passed }
        }
    }

    private func partition(heldOut: Bool) -> EvaluationSuite {
        var suite = source
        suite.cases = source.cases.filter { heldOutCaseIDs.contains($0.id) == heldOut }
        let caseIDs = Set(suite.cases.map(\.id))
        suite.releasePolicy.criticalCaseIDs = source.releasePolicy.criticalCaseIDs.filter { caseIDs.contains($0) }
        return suite
    }
}

enum EvaluationPromptImprovementRules {
    static func validationIssue(suite: EvaluationSuite, heldOutCaseIDs: Set<UUID>) -> String? {
        let caseIDs = Set(suite.cases.map(\.id))
        guard suite.cases.count >= 2, caseIDs.count == suite.cases.count else {
            return "Add at least two distinct cases before improving instructions."
        }
        guard !heldOutCaseIDs.isEmpty, heldOutCaseIDs.isSubset(of: caseIDs), heldOutCaseIDs.count < caseIDs.count else {
            return "Reserve at least one Held-out case and keep at least one Development case."
        }
        guard suite.scoringMode != .review else { return "Choose a scoring method before improving instructions." }
        guard (1...100).contains(suite.repetitions), suite.cases.count <= 100 / suite.repetitions else {
            return "Use a suite with at most 100 planned samples."
        }
        return nil
    }

    static func isComplete(_ run: EvaluationRun, for suite: EvaluationSuite) -> Bool {
        guard !suite.cases.isEmpty, (1...100).contains(suite.repetitions),
              suite.cases.count <= 100 / suite.repetitions,
              !run.cancelled, run.terminationReason == nil, run.errorCount == 0,
              run.suiteID == suite.id, run.scoringMode == suite.scoringMode,
              run.criteria == suite.criteria, run.repetitions == suite.repetitions,
              run.instructions == suite.instructions, run.plannedCases == suite.cases,
              run.plannedSampleCount == suite.cases.count * suite.repetitions,
              run.suiteDefinition == EvaluationSuiteDefinition(suite: suite),
              run.results.count == suite.cases.count * suite.repetitions,
              run.scoredCount == run.results.count,
              Set(run.results.map(\.id)).count == run.results.count else { return false }
        for test in suite.cases {
            let samples = run.effectiveResults.filter { $0.caseID == test.id }
            guard samples.count == suite.repetitions,
                  Set(samples.map(\.repetition)) == Set(1...suite.repetitions),
                  samples.allSatisfy({ $0.prompt == test.prompt && $0.expected == test.expected
                      && $0.judgeErrorCategory == nil && $0.judgeErrorMessage == nil }) else { return false }
        }
        return true
    }
}
