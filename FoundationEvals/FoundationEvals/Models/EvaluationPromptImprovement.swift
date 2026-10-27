import Foundation

enum EvaluationPromptImprovementStatus: String, Codable, Sendable {
    case running, completed, noImprovement, failed, cancelled
}

struct EvaluationPromptCandidate: Identifiable, Codable, Sendable {
    var id = UUID()
    var instructions: String
    var developmentRun: EvaluationRun?
}

/// Frozen source suite, partition, candidate instructions, and comparison evidence retained before an instruction change can be applied.
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

    /// Removes matching saved run references and invalidates the comparison so deleted evidence cannot authorize applying instructions.
    mutating func removeRun(id: UUID) {
        guard runs.contains(where: { $0.id == id }) else { return }
        if developmentBaseline?.id == id { developmentBaseline = nil }
        if heldOutBaseline?.id == id { heldOutBaseline = nil }
        if heldOutCandidate?.id == id { heldOutCandidate = nil }
        for index in candidates.indices where candidates[index].developmentRun?.id == id {
            candidates[index].developmentRun = nil
        }
        status = .failed
        message = "Saved comparison evidence was deleted. Start a new comparison before applying instructions."
    }

    /// Requires complete matching development and held-out runs, a development gain, and no held-out case losing passed samples.
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

    /// Copies the source suite for one partition and retains only its applicable critical-case IDs.
    private func partition(heldOut: Bool) -> EvaluationSuite {
        var suite = source
        suite.cases = source.cases.filter { heldOutCaseIDs.contains($0.id) == heldOut }
        let caseIDs = Set(suite.cases.map(\.id))
        suite.releasePolicy.criticalCaseIDs = source.releasePolicy.criticalCaseIDs.filter { caseIDs.contains($0) }
        return suite
    }
}

enum EvaluationPromptImprovementRules {
    /// Requires distinct development and held-out cases, an automated scoring mode, and at most 100 planned samples.
    static func validationIssue(suite: EvaluationSuite, heldOutCaseIDs: Set<UUID>) -> String? {
        guard !suite.hasDocumentCases else {
            return "Automatic improvement does not yet support document suites. Their shared source passages need a source-aware held-out split."
        }
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

    /// Checks complete, uniquely identified scoring coverage against the supplied suite, including instructions, saved definition, and case/repetition coordinates.
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
