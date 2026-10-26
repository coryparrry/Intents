import Foundation

struct EvaluationExperimentRunResult: Sendable {
    var current: EvaluationRun
    var candidate: EvaluationRun
}

actor EvaluationExperimentRunner {
    typealias PartRunner = @Sendable (
        UUID,
        String,
        Date,
        EvaluationSuite,
        [ImageEvaluationInput],
        EvaluationResolvedJudgeConnection?,
        @Sendable (EvaluationSampleResult, Int, Int) async -> Void
    ) async -> EvaluationRun

    private let runPart: PartRunner

    /// Creates an experiment runner that executes each trial through the native evaluation runner.
    init() {
        let runner = EvaluationRunner()
        runPart = { id, suiteRevision, startedAt, suite, images, externalJudge, progress in
            await runner.run(
                id: id,
                suiteRevision: suiteRevision,
                startedAt: startedAt,
                suite: suite,
                images: images,
                externalJudge: externalJudge,
                progress: progress
            )
        }
    }

    /// Injects execution of one case and repetition for controlled experiment runs.
    init(runPart: @escaping PartRunner) {
        self.runPart = runPart
    }

    /// Executes the frozen paired order, remaps progress to experiment positions and combines evidence by variant.
    /// Throws for invalid plans or cancellation; batch-stopping failures preserve partial runs with interruption reasons.
    func run(
        suite: EvaluationSuite,
        experiment: EvaluationExperiment,
        images: [ImageEvaluationInput],
        externalJudge: EvaluationResolvedJudgeConnection?,
        progress: @Sendable (EvaluationSampleResult, Int, Int) async -> Void
    ) async throws -> EvaluationExperimentRunResult {
        try validatePlan(suite: suite, experiment: experiment)
        let currentRunID = UUID()
        let candidateRunID = UUID()
        let startedAt = Date()
        var currentParts: [EvaluationRun] = []
        var candidateParts: [EvaluationRun] = []
        var terminationReason: String?

        for (position, variantID) in experiment.executionOrder.enumerated() {
            try Task.checkCancellation()
            let pairIndex = position / 2
            let caseIndex = pairIndex % suite.cases.count
            let repetition = pairIndex / suite.cases.count + 1
            let completedPosition = position + 1
            let variant = variantID == experiment.current.id ? experiment.current : experiment.candidate
            var one = suite
            one.instructions = variant.instructions
            one.cases = [suite.cases[caseIndex]]
            one.repetitions = 1
            var part = await runPart(
                variantID == experiment.current.id ? currentRunID : candidateRunID,
                variant.suiteRevision ?? experiment.suiteRevision,
                startedAt,
                one,
                images,
                externalJudge
            ) { result, _, _ in
                var adjusted = result
                adjusted.repetition = repetition
                await progress(adjusted, completedPosition, experiment.executionOrder.count)
            }
            if Task.isCancelled || part.cancelled { throw CancellationError() }
            part.results = part.results.map { result in
                var adjusted = result
                adjusted.repetition = repetition
                return adjusted
            }
            if variantID == experiment.current.id { currentParts.append(part) }
            else { candidateParts.append(part) }

            if EvaluationRunner.stopsBatch(for: part.terminationReason) {
                terminationReason = part.terminationReason
                break
            }
        }

        let fallbackPart = currentParts.first ?? candidateParts.first
        return .init(
            current: try combined(
                parts: currentParts, id: currentRunID, suite: suite,
                instructions: experiment.current.instructions,
                suiteRevision: experiment.current.suiteRevision ?? experiment.suiteRevision,
                startedAt: startedAt,
                fallback: fallbackPart,
                interruptionReason: terminationReason
            ),
            candidate: try combined(
                parts: candidateParts, id: candidateRunID, suite: suite,
                instructions: experiment.candidate.instructions,
                suiteRevision: experiment.candidate.suiteRevision ?? experiment.suiteRevision,
                startedAt: startedAt,
                fallback: fallbackPart,
                interruptionReason: terminationReason
            )
        )
    }

    /// Requires unique cases, positive sample counts without overflow and exactly one execution of each variant per trial pair.
    /// Throws a resource conflict when the frozen execution plan cannot satisfy those conditions.
    private func validatePlan(suite: EvaluationSuite, experiment: EvaluationExperiment) throws {
        let samples = suite.cases.count.multipliedReportingOverflow(by: suite.repetitions)
        let positions = samples.partialValue.multipliedReportingOverflow(by: 2)
        guard !suite.cases.isEmpty, suite.repetitions > 0,
              !samples.overflow, !positions.overflow,
              Set(suite.cases.map(\.id)).count == suite.cases.count,
              experiment.current.id != experiment.candidate.id,
              experiment.executionOrder.count == positions.partialValue else {
            throw EvaluationStoreError.resourceConflict("The experiment execution plan is invalid. Create a new experiment.")
        }
        let variants = Set([experiment.current.id, experiment.candidate.id])
        for index in stride(from: 0, to: experiment.executionOrder.count, by: 2) {
            guard Set(experiment.executionOrder[index...(index + 1)]) == variants else {
                throw EvaluationStoreError.resourceConflict("Each experiment trial must execute both variants exactly once. Create a new experiment.")
            }
        }
    }

    /// Combines trial results and assessments into one variant run, preserving partial coverage and observed judge identities.
    /// Uses fallback metadata when this variant never ran, but throws if neither variant produced evidence.
    private func combined(
        parts: [EvaluationRun],
        id: UUID,
        suite: EvaluationSuite,
        instructions: String,
        suiteRevision: String,
        startedAt: Date,
        fallback: EvaluationRun?,
        interruptionReason: String?
    ) throws -> EvaluationRun {
        guard var run = parts.first ?? fallback else {
            throw EvaluationStoreError.resourceConflict("The experiment produced no samples.")
        }
        run.id = id
        run.suiteID = suite.id
        run.suiteName = suite.name
        run.suiteVersion = suite.version
        run.instructions = instructions
        run.suiteRevision = suiteRevision
        run.repetitions = suite.repetitions
        run.plannedSampleCount = suite.cases.count * suite.repetitions
        run.plannedCases = suite.cases
        run.startedAt = startedAt
        run.completedAt = Date()
        run.results = parts.flatMap(\.results)
        run.cancelled = false
        run.terminationReason = parts.compactMap(\.terminationReason).first
        if run.terminationReason == nil, run.results.count < run.plannedResultCount {
            run.terminationReason = interruptionReason ?? "incomplete"
        }
        run.assessments = nil
        run.selectedAssessmentID = nil
        var variantSuite = suite
        variantSuite.instructions = instructions
        run.suiteDefinition = EvaluationSuiteDefinition(suite: variantSuite)
        let assessments = parts.flatMap { $0.assessments ?? [] }
        if var assessment = assessments.first {
            assessment.id = UUID()
            assessment.runID = id
            assessment.samples = assessments.flatMap(\.samples)
            assessment.durationMilliseconds = EvaluationAssessment.summedJudgeDurationMilliseconds(assessment.samples)
            let usage = assessments.compactMap(\.totalUsage)
            assessment.totalUsage = usage.count == assessments.count
                ? usage.reduce(into: EvaluationUsage()) { $0.add($1) } : nil
            assessment.cost = combinedCost(assessments.map(\.cost))
            let rawIdentities = assessments.flatMap { $0.observedJudgeIdentities ?? [$0.judge] }
            let modelIdentities = rawIdentities.filter { $0.requestedModelID != "none" }
            let identityCandidates = modelIdentities.isEmpty ? rawIdentities : modelIdentities
            let observedIdentities = identityCandidates.reduce(into: [EvaluationJudgeIdentity]()) { unique, identity in
                if !unique.contains(identity) { unique.append(identity) }
            }
            if let first = observedIdentities.first { assessment.judge = first }
            assessment.observedJudgeIdentities = observedIdentities
            assessment.scoringContract = try? EvaluationScoringContract(suite: variantSuite)
            run.assessments = [assessment]
            run.selectedAssessmentID = assessment.id
        }
        return run
    }

    /// Sums judgment costs only when every part reports a value; propagates unavailable or estimated cost status.
    private func combinedCost(_ costs: [EvaluationCost]) -> EvaluationCost {
        guard costs.allSatisfy({ $0.usd != nil }) else {
            return .init(availability: .unavailable, usd: nil, explanation: "At least one experiment judgment cost was unavailable.")
        }
        let availability: EvaluationCostAvailability = costs.contains { $0.availability == .estimated } ? .estimated : .known
        return .init(
            availability: availability,
            usd: costs.compactMap(\.usd).reduce(0, +),
            explanation: availability == .known ? "Reported by the judge endpoint." : "Estimated from configured token prices."
        )
    }
}
