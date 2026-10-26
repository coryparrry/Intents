import Foundation

actor EvaluationPromptImprovementRunner {
    typealias Generator = @Sendable (EvaluationSuite, EvaluationRun) async throws -> [String]
    typealias Run = @Sendable (EvaluationSuite) async throws -> EvaluationRun
    typealias Checkpoint = @Sendable (EvaluationPromptImprovement) async throws -> Void

    private let generate: Generator
    private let evaluate: Run

    /// Injects instruction generation and suite execution so the comparison can be run with controlled dependencies.
    init(generate: @escaping Generator, evaluate: @escaping Run) {
        self.generate = generate
        self.evaluate = evaluate
    }

    /// Checkpoints each comparison stage and selects an alternative using Development pass counts alone.
    /// Held-out execution starts only after selection is frozen; invalid, incomplete or cancelled comparisons and checkpoint failures throw.
    func run(_ initial: EvaluationPromptImprovement, checkpoint: Checkpoint) async throws -> EvaluationPromptImprovement {
        if let issue = EvaluationPromptImprovementRules.validationIssue(suite: initial.source, heldOutCaseIDs: initial.heldOutCaseIDs) {
            throw EvaluationStoreError.invalidSuite(issue)
        }
        var report = initial
        let development = report.developmentSuite
        try Task.checkCancellation()
        report.developmentBaseline = try await evaluateVariant(development, improvementID: report.id)
        try await checkpoint(report)
        try requireComplete(report.developmentBaseline!, suite: development)
        report.message = "Generating two alternatives using Development evidence"
        try await checkpoint(report)
        let suggestions = try await generate(development, report.developmentBaseline!)
        try Task.checkCancellation()
        let normalized = suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.count == 2, Set(normalized).count == 2,
              normalized.allSatisfy({ !$0.isEmpty && $0 != development.instructions
                  && $0.count <= EvaluationStore.maximumFieldCharacters }) else {
            throw EvaluationStoreError.invalidSuite("The model must return two distinct, nonempty instruction alternatives. Try a smaller Development set or clearer instructions.")
        }
        report.candidates = normalized.map { EvaluationPromptCandidate(instructions: $0) }
        for index in report.candidates.indices {
            report.message = "Testing alternative \(index + 1) of 2 on Development cases"
            try await checkpoint(report)
            var variant = development
            variant.instructions = report.candidates[index].instructions
            report.candidates[index].developmentRun = try await evaluateVariant(variant, improvementID: report.id)
            try await checkpoint(report)
            try requireComplete(report.candidates[index].developmentRun!, suite: variant)
        }
        // Selection is frozen before either Held-out run. Held-out outputs never feed generation or selection.
        let baselinePasses = report.developmentBaseline!.passedCount
        let best = report.candidates.max { ($0.developmentRun?.passedCount ?? 0) < ($1.developmentRun?.passedCount ?? 0) }
        guard let best, best.developmentRun!.passedCount > baselinePasses else {
            report.status = .noImprovement
            report.message = "Neither alternative improved the Development pass rate. Current instructions were kept; Held-out cases were not used."
            try await checkpoint(report)
            return report
        }
        report.selectedCandidateID = best.id
        report.message = "Validating current instructions on Held-out cases"
        try await checkpoint(report)
        let heldOut = report.heldOutSuite
        report.heldOutBaseline = try await evaluateVariant(heldOut, improvementID: report.id)
        try await checkpoint(report)
        try requireComplete(report.heldOutBaseline!, suite: heldOut)
        report.message = "Validating the selected alternative on Held-out cases"
        try await checkpoint(report)
        var candidate = heldOut
        candidate.instructions = best.instructions
        report.heldOutCandidate = try await evaluateVariant(candidate, improvementID: report.id)
        try await checkpoint(report)
        try requireComplete(report.heldOutCandidate!, suite: candidate)
        try Task.checkCancellation()
        report.status = .completed
        report.message = report.canApply
            ? "The candidate improved Development results without regressing any Held-out case. Review the evidence before applying it. These samples do not establish statistical significance."
            : "The candidate improved Development results but regressed on Held-out cases. Keep the current instructions."
        try await checkpoint(report)
        return report
    }

    /// Runs a variant and tags its returned evidence with the owning improvement ID.
    private func evaluateVariant(_ suite: EvaluationSuite, improvementID: UUID) async throws -> EvaluationRun {
        var run = try await evaluate(suite)
        run.promptImprovementID = improvementID
        return run
    }

    /// Rejects cancelled, incomplete, unscored or errored comparison runs before their scores can influence a recommendation.
    private func requireComplete(_ run: EvaluationRun, suite: EvaluationSuite) throws {
        try Task.checkCancellation()
        guard EvaluationPromptImprovementRules.isComplete(run, for: suite) else {
            throw EvaluationStoreError.invalidSuite("A comparison run was incomplete, unscored, or contained errors. No instruction change can be recommended.")
        }
    }
}
