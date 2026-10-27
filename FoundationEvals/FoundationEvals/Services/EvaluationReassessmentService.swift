import Foundation

struct EvaluationJudgeCheckResult: Identifiable, Codable, Sendable {
    var id: UUID { example.id }
    var example: EvaluationReviewedJudgeExample
    var actualStatus: EvaluationResultStatus
    var passed: Bool
    var errorMessage: String?
}

struct EvaluationJudgeCheckReport: Codable, Sendable {
    var connectionID: UUID
    var results: [EvaluationJudgeCheckResult]
    var passed: Bool { !results.isEmpty && results.allSatisfy(\.passed) }
}

struct EvaluationJudgeCheckSource: Sendable {
    var example: EvaluationReviewedJudgeExample
    var run: EvaluationRun?
    var assessment: EvaluationAssessment?
    var suite: EvaluationSuite?
    var images: [ImageEvaluationInput]
    var errorMessage: String?
}

actor EvaluationReassessmentService {
    private let client: EvaluationCompatibleJudgeClient

    /// Injects the external judge client used to assess saved responses.
    init(client: EvaluationCompatibleJudgeClient = .init()) { self.client = client }

    /// Creates a new assessment from saved subject outputs and frozen cases without rerunning generation.
    /// Applies deterministic checks locally, requires independent judging for semantic criteria and retains per-sample failures.
    /// Reassessment cancellation throws; initial-run cancellation records the interrupted judgment and returns partial evidence.
    func reassess(
        run: EvaluationRun,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        resolved: EvaluationResolvedJudgeConnection?,
        scoringContract: EvaluationScoringContract? = nil,
        subjectEvidenceDigest: String? = nil,
        origin: EvaluationAssessmentOrigin = .reassessment
    ) async throws -> EvaluationAssessment {
        let savedCases = run.subjectEvidence?.cases ?? run.plannedCases ?? run.suiteDefinition?.cases ?? suite.cases
        var assessmentSuite = suite
        assessmentSuite.cases = savedCases
        var samples: [EvaluationSampleAssessment] = []
        var totalUsage = EvaluationUsage()
        var hasUsage = false
        var usageComplete = true
        var totalCost = 0.0
        var costAvailability = EvaluationCostAvailability.known
        var identity = EvaluationJudgeIdentity(
            mode: .sameModel,
            connectionID: nil,
            connectionName: "Deterministic checks",
            endpointKind: nil,
            baseURL: nil,
            requestedModelID: "none",
            reportedModelID: "none",
            provider: "local",
            providerOrder: []
        )
        var observedIdentities: [EvaluationJudgeIdentity] = []

        for saved in run.results {
            if Task.isCancelled {
                guard origin == .initialRun else { throw CancellationError() }
                samples.append(cancelledInitialAssessment(for: saved))
                break
            }
            guard saved.hasCompleteSubjectEvidenceForJudging,
                  let evaluationCase = savedCases.first(where: { $0.id == saved.caseID }) else {
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The saved sample has no complete response or immutable case definition.",
                    trace: nil, errorCategory: "incompleteSavedEvidence",
                    errorMessage: "Reassessment did not rerun generation.", usage: nil, durationMilliseconds: nil
                ))
                continue
            }
            if suite.scoringMode != .modelJudge {
                let metric = MetricScorer.evaluate(
                    mode: suite.scoringMode, expected: evaluationCase.expected, response: saved.response
                )
                let assertions = EvaluationFieldAssertions.evaluate(
                    response: saved.response, assertions: evaluationCase.fieldAssertions ?? []
                )
                let status = EvaluationFieldAssertions.gatedStatus(
                    baseStatus: metric.status, results: assertions,
                    allowAssertionsToScore: suite.scoringMode == .review
                )
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: status, score: nil,
                    rationale: metric.rationale, trace: nil, errorCategory: nil, errorMessage: nil,
                    usage: nil, durationMilliseconds: 0
                ))
                continue
            }
            let criteria = suite.effectiveCriteria(for: evaluationCase)
            guard (1...4).contains(criteria.count), criteria.allSatisfy({ !$0.contains(where: \.isNewline) }) else {
                samples.append(.init(id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The saved case rubric is invalid.", trace: nil, errorCategory: "invalidJudgeConfiguration",
                    errorMessage: "Each case requirement must occupy one line.", usage: nil, durationMilliseconds: nil))
                continue
            }
            let objective = criteria.enumerated().compactMap { index, criterion in
                EvaluationExactCriterion.check(criterion: criterion, index: index + 1, response: saved.response)
            }
            let semanticIndexes = criteria.indices.filter { index in
                !objective.contains { $0.criterionIndex == index + 1 }
            }
            if semanticIndexes.isEmpty {
                let judgment = EvaluationJudge.aggregate(checks: objective)
                samples.append(.init(
                    id: UUID(), sampleID: saved.id,
                    status: gatedStatus(judgment: judgment, response: saved.response, evaluationCase: evaluationCase),
                    score: judgment.score, rationale: judgment.rationale,
                    trace: .init(instructions: "", prompt: "", checks: judgment.checks, judgedCriterionIndexes: []),
                    errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: 0
                ))
                continue
            }
            var semanticSuite = suite
            semanticSuite.criteria = semanticIndexes.map { criteria[$0] }.joined(separator: "\n")
            guard let resolved else {
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The app feature response needs an independent judge assessment.",
                    trace: nil, errorCategory: "invalidJudgeConfiguration",
                    errorMessage: "Choose an approved independent judge connection for AI-rubric app feature runs.",
                    usage: nil, durationMilliseconds: nil
                ))
                costAvailability = .unavailable
                break
            }
            identity = requestedIdentity(resolved.connection)
            let judgeStarted = ContinuousClock.now
            do {
                let judged = try await client.judge(
                    response: saved.response,
                    evaluationCase: evaluationCase,
                    effectivePrompt: saved.effectivePrompt ?? saved.prompt,
                    suite: semanticSuite,
                    images: images,
                    toolEvidence: try evidence(from: saved, run: run, suite: suite),
                    subjectContext: try EvaluationJudgeSubjectContext.resolved(saved.judgeSubjectContext, evaluationCase: evaluationCase),
                    resolved: resolved
                )
                identity = judged.identity
                if !observedIdentities.contains(judged.identity) { observedIdentities.append(judged.identity) }
                let remapped = judged.judgment.checks.map { check in
                    var result = check
                    result.criterionIndex = semanticIndexes[check.criterionIndex - 1] + 1
                    return result
                }
                let judgment = EvaluationJudge.aggregate(checks: objective + remapped)
                var trace = judged.trace
                trace.checks = judgment.checks
                trace.judgedCriterionIndexes = semanticIndexes.map { $0 + 1 }
                if let usage = judged.usage {
                    totalUsage.add(usage)
                    hasUsage = true
                } else {
                    usageComplete = false
                }
                if let cost = judged.cost.usd {
                    totalCost += cost
                    // A later estimate cannot make an earlier unpriced request complete.
                    if judged.cost.availability == .estimated, costAvailability == .known {
                        costAvailability = .estimated
                    }
                } else {
                    costAvailability = .unavailable
                }
                samples.append(.init(
                    id: UUID(), sampleID: saved.id,
                    status: gatedStatus(judgment: judgment, response: saved.response, evaluationCase: evaluationCase),
                    score: judgment.score, rationale: judgment.rationale, trace: trace,
                    errorCategory: nil, errorMessage: nil, usage: judged.usage,
                    durationMilliseconds: judged.durationMilliseconds
                ))
            } catch is CancellationError {
                guard origin == .initialRun else { throw CancellationError() }
                usageComplete = false
                costAvailability = .unavailable
                samples.append(cancelledInitialAssessment(for: saved))
                break
            } catch let error as URLError where error.code == .cancelled {
                guard origin == .initialRun else { throw CancellationError() }
                usageComplete = false
                costAvailability = .unavailable
                samples.append(cancelledInitialAssessment(for: saved))
                break
            } catch {
                let errorCategory = EvaluationRunner.externalJudgeErrorCategory(error)
                usageComplete = false
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The independent judge did not produce valid evidence.",
                    trace: EvaluationRunner.externalJudgeFailureTrace(
                        error,
                        completedChecks: objective,
                        judgedCriterionIndexes: semanticIndexes.map { $0 + 1 }
                    ),
                    errorCategory: errorCategory, errorMessage: error.localizedDescription,
                    usage: nil, durationMilliseconds: judgeStarted.evaluationMilliseconds(to: .now)
                ))
                costAvailability = .unavailable
                if EvaluationRunner.stopsBatch(for: errorCategory) { break }
            }
        }
        let cost = costAvailability == .unavailable
            ? EvaluationCost(availability: .unavailable, usd: nil, explanation: "At least one judge request cost was unavailable.")
            : EvaluationCost(availability: costAvailability, usd: totalCost,
                             explanation: costAvailability == .known ? "Reported by the judge endpoint." : "Estimated from configured token prices.")
        let assessmentIdentity = observedIdentities.first ?? identity
        return EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: Date(), origin: origin,
            judge: assessmentIdentity, promptVersion: EvaluationRunner.judgePromptVersion,
            rubric: suite.criteria, passingScore: EvaluationSuite.judgePassingScore,
            samples: samples, totalUsage: hasUsage && usageComplete ? totalUsage : nil,
            durationMilliseconds: EvaluationAssessment.summedJudgeDurationMilliseconds(samples), cost: cost,
            supersedesAssessmentID: origin == .reassessment ? run.selectedAssessmentID : nil,
            observedJudgeIdentities: observedIdentities.isEmpty ? [assessmentIdentity] : observedIdentities,
            scoringContract: scoringContract ?? (try? EvaluationScoringContract(suite: assessmentSuite)),
            subjectEvidenceDigest: subjectEvidenceDigest
        )
    }

    /// Records an unscored initial-run sample when its collected response could not finish independent judging.
    private func cancelledInitialAssessment(for sample: EvaluationSampleResult) -> EvaluationSampleAssessment {
        EvaluationSampleAssessment(
            id: UUID(), sampleID: sample.id, status: .unscored, score: nil,
            rationale: "The subject response was collected, but judging was cancelled.",
            trace: nil, errorCategory: "cancelled",
            errorMessage: "The independent judge request was cancelled.",
            usage: nil, durationMilliseconds: nil
        )
    }

    /// Replays reviewed saved responses against a connection and compares the verdict with each human expected status.
    /// Missing or incompatible evidence becomes a failed check; cancellation propagates and subject generation is never rerun.
    func checkJudge(
        sources: [EvaluationJudgeCheckSource],
        resolved: EvaluationResolvedJudgeConnection
    ) async throws -> EvaluationJudgeCheckReport {
        var results: [EvaluationJudgeCheckResult] = []
        for source in sources {
            try Task.checkCancellation()
            let example = source.example
            guard source.errorMessage == nil,
                  let run = source.run,
                  let assessment = source.assessment,
                  let suite = source.suite,
                  let sample = run.results.first(where: { $0.id == example.sampleID }),
                  let evaluationCase = suite.cases.first(where: { $0.id == sample.caseID }) else {
                results.append(.init(
                    example: example, actualStatus: .unscored, passed: false,
                    errorMessage: source.errorMessage ?? "The reviewed example's saved evidence is missing."
                ))
                continue
            }
            guard sample.hasCompleteSubjectEvidenceForJudging else {
                results.append(.init(
                    example: example, actualStatus: .unscored, passed: false,
                    errorMessage: "The reviewed example has no complete subject response to judge."
                ))
                continue
            }
            guard assessment.promptVersion == EvaluationRunner.judgePromptVersion else {
                results.append(.init(
                    example: example, actualStatus: .unscored, passed: false,
                    errorMessage: "The reviewed example used a judge prompt policy that this version cannot replay."
                ))
                continue
            }
            do {
                let criteria = suite.effectiveCriteria(for: evaluationCase)
                guard (1...4).contains(criteria.count), criteria.allSatisfy({ !$0.contains(where: \.isNewline) }) else {
                    throw EvaluationJudgeValidationError.invalidCriteria
                }
                let objective = criteria.enumerated().compactMap { index, criterion in
                    EvaluationExactCriterion.check(criterion: criterion, index: index + 1, response: sample.response)
                }
                let semanticIndexes = criteria.indices.filter { index in
                    !objective.contains { $0.criterionIndex == index + 1 }
                }
                let judgment: EvaluationValidatedJudgment
                if semanticIndexes.isEmpty {
                    judgment = EvaluationJudge.aggregate(checks: objective)
                } else {
                    var semanticSuite = suite
                    semanticSuite.criteria = semanticIndexes.map { criteria[$0] }.joined(separator: "\n")
                    let judged = try await client.judge(
                        response: sample.response, evaluationCase: evaluationCase,
                        effectivePrompt: sample.effectivePrompt ?? sample.prompt,
                        suite: semanticSuite, images: source.images,
                        toolEvidence: try evidence(from: sample, run: run, suite: suite),
                        subjectContext: try EvaluationJudgeSubjectContext.resolved(sample.judgeSubjectContext, evaluationCase: evaluationCase),
                        resolved: resolved
                    )
                    let remapped = judged.judgment.checks.map { check in
                        var result = check
                        result.criterionIndex = semanticIndexes[check.criterionIndex - 1] + 1
                        return result
                    }
                    judgment = EvaluationJudge.aggregate(checks: objective + remapped)
                }
                let status = gatedStatus(
                    judgment: judgment, response: sample.response, evaluationCase: evaluationCase,
                    passingScore: assessment.passingScore
                )
                results.append(.init(example: example, actualStatus: status,
                                     passed: status == example.expectedStatus, errorMessage: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                results.append(.init(example: example, actualStatus: .unscored,
                                     passed: false, errorMessage: error.localizedDescription))
            }
        }
        return EvaluationJudgeCheckReport(connectionID: resolved.connection.id, results: results)
    }

    /// Records the requested external connection identity before any provider-reported identity is available.
    private func requestedIdentity(_ connection: EvaluationJudgeConnection) -> EvaluationJudgeIdentity {
        .init(
            mode: .connection, connectionID: connection.id, connectionName: connection.name,
            endpointKind: connection.kind, baseURL: connection.baseURL,
            requestedModelID: connection.modelID, reportedModelID: nil,
            provider: nil, providerOrder: connection.providerOrder
        )
    }

    /// Returns validated frozen tool evidence, or nil only when neither configured nor observed tools require it.
    /// Throws when historical grounding cannot be reproduced from the saved response.
    private func evidence(from sample: EvaluationSampleResult, run: EvaluationRun, suite: EvaluationSuite) throws -> String? {
        if let captured = sample.judgeToolEvidence { return try captured.validatedText() }
        let configuration = run.execution?.configuration ?? run.suiteDefinition?.modelConfiguration ?? suite.modelConfiguration
        let features = run.execution?.features ?? run.suiteDefinition?.features ?? suite.features
        let usedTools = !(sample.toolCalls ?? []).isEmpty
            || !(sample.featureTrace?.customToolCalls ?? []).isEmpty
            || !(sample.featureTrace?.builtinToolCalls ?? []).isEmpty
        let configuredTools = !(run.execution?.toolNames ?? []).isEmpty
            || configuration.referenceMode == .lookupTool || !features.tools.isEmpty
            || !configuration.customizationSettings.visionSettings.enabledToolNames.isEmpty
            || !features.spotlightSearch.enabledToolNames.isEmpty
        guard !usedTools && !configuredTools else {
            throw EvaluationJudgeToolEvidence.EvidenceError.unavailable(
                "This saved response has no frozen judge tool evidence. Tool summaries and optional transcripts cannot reproduce the original grounding evidence. Run the case again before reassessing it."
            )
        }
        return nil
    }

    /// Converts the rubric score to pass/fail using the requested threshold, then gates it with case field assertions.
    private func gatedStatus(
        judgment: EvaluationValidatedJudgment,
        response: String,
        evaluationCase: EvaluationCase,
        passingScore: Int = EvaluationSuite.judgePassingScore
    ) -> EvaluationResultStatus {
        let base: EvaluationResultStatus = judgment.score >= passingScore ? .passed : .failed
        let assertions = EvaluationFieldAssertions.evaluate(
            response: response, assertions: evaluationCase.fieldAssertions ?? []
        )
        return EvaluationFieldAssertions.gatedStatus(baseStatus: base, results: assertions)
    }
}
