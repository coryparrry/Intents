import Foundation

struct EvaluationJudgeCheckResult: Identifiable, Sendable {
    var id: UUID { example.id }
    var example: EvaluationReviewedJudgeExample
    var actualStatus: EvaluationResultStatus
    var passed: Bool
    var errorMessage: String?
}

struct EvaluationJudgeCheckReport: Sendable {
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
    private let client = EvaluationCompatibleJudgeClient()

    func reassess(
        run: EvaluationRun,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        resolved: EvaluationResolvedJudgeConnection,
        scoringContract: EvaluationScoringContract? = nil,
        subjectEvidenceDigest: String? = nil
    ) async throws -> EvaluationAssessment {
        var samples: [EvaluationSampleAssessment] = []
        var totalUsage = EvaluationUsage()
        var hasUsage = false
        var totalCost = 0.0
        var costAvailability = EvaluationCostAvailability.known
        var identity = requestedIdentity(resolved.connection)
        var observedIdentities: [EvaluationJudgeIdentity] = []

        for saved in run.results {
            try Task.checkCancellation()
            guard saved.hasCompleteSubjectEvidenceForJudging,
                  let evaluationCase = (run.plannedCases ?? suite.cases).first(where: { $0.id == saved.caseID }) else {
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The saved sample has no complete response or immutable case definition.",
                    trace: nil, errorCategory: "incompleteSavedEvidence",
                    errorMessage: "Reassessment did not rerun generation.", usage: nil, durationMilliseconds: nil
                ))
                continue
            }
            let criteria = suite.rubricCriteria
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
            let judgeStarted = ContinuousClock.now
            do {
                let judged = try await client.judge(
                    response: saved.response,
                    evaluationCase: evaluationCase,
                    effectivePrompt: saved.effectivePrompt ?? saved.prompt,
                    suite: semanticSuite,
                    images: images,
                    toolEvidence: evidence(from: saved),
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
                if let usage = judged.usage { totalUsage.add(usage); hasUsage = true }
                if let cost = judged.cost.usd {
                    totalCost += cost
                    if judged.cost.availability == .estimated { costAvailability = .estimated }
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
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                let errorCategory = EvaluationRunner.externalJudgeErrorCategory(error)
                samples.append(.init(
                    id: UUID(), sampleID: saved.id, status: .unscored, score: nil,
                    rationale: "The independent judge did not produce valid evidence.",
                    trace: EvaluationRunner.externalJudgeFailureTrace(
                        error,
                        completedChecks: objective,
                        judgedCriterionIndexes: semanticIndexes.map { $0 + 1 }
                    ),
                    errorCategory: errorCategory, errorMessage: error.localizedDescription,
                    usage: nil, durationMilliseconds: milliseconds(since: judgeStarted)
                ))
                costAvailability = .unavailable
                if EvaluationRunner.stopsBatch(for: errorCategory) { break }
            }
        }
        let cost = costAvailability == .unavailable
            ? EvaluationCost(availability: .unavailable, usd: nil, explanation: "At least one reassessment cost was unavailable.")
            : EvaluationCost(availability: costAvailability, usd: totalCost,
                             explanation: costAvailability == .known ? "Reported by the judge endpoint." : "Estimated from configured token prices.")
        let assessmentIdentity = observedIdentities.first ?? identity
        return EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: Date(), origin: .reassessment,
            judge: assessmentIdentity, promptVersion: EvaluationRunner.judgePromptVersion,
            rubric: suite.criteria, passingScore: EvaluationSuite.judgePassingScore,
            samples: samples, totalUsage: hasUsage ? totalUsage : nil,
            durationMilliseconds: EvaluationAssessment.summedJudgeDurationMilliseconds(samples), cost: cost,
            supersedesAssessmentID: run.selectedAssessmentID,
            observedJudgeIdentities: observedIdentities.isEmpty ? [assessmentIdentity] : observedIdentities,
            scoringContract: scoringContract ?? (try? EvaluationScoringContract(suite: suite)),
            subjectEvidenceDigest: subjectEvidenceDigest
        )
    }

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
                let criteria = suite.rubricCriteria
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
                        toolEvidence: evidence(from: sample), resolved: resolved
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

    private func requestedIdentity(_ connection: EvaluationJudgeConnection) -> EvaluationJudgeIdentity {
        .init(
            mode: .connection, connectionID: connection.id, connectionName: connection.name,
            endpointKind: connection.kind, baseURL: connection.baseURL,
            requestedModelID: connection.modelID, reportedModelID: nil,
            provider: nil, providerOrder: connection.providerOrder
        )
    }

    private func evidence(from sample: EvaluationSampleResult) -> String? {
        let traces = (sample.toolCalls ?? []).map {
            "tool=\($0.toolName); outcome=\($0.outcome); matchedFiles=\($0.matchedFiles.count); outputCharacters=\($0.outputCharacterCount)"
        }
        return traces.isEmpty ? nil : traces.joined(separator: "\n")
    }

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

    private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - instant
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
