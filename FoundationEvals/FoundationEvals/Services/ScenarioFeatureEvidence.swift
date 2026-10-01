import Foundation

enum ScenarioFeatureEvidence {
    private struct SampleCoordinate: Hashable {
        var caseID: UUID
        var repetition: Int
    }

    static func isEligible(_ run: EvaluationRun, for definition: ScenarioDefinition) -> Bool {
        guard let projectID = definition.projectID,
              run.projectID == projectID,
              let execution = run.developerExecution,
              execution.appBundleIdentifier == definition.target.bundleIdentifier,
              !definition.directControl.linkedFeatureID.isEmpty,
              execution.featureID == definition.directControl.linkedFeatureID,
              !definition.directControl.linkedFeatureSubjectDigest.isEmpty,
              let evidence = run.subjectEvidence,
              evidence.hasValidDigest,
              evidence.digest == definition.directControl.linkedFeatureSubjectDigest,
              !run.cancelled,
              run.terminationReason == nil,
              run.repetitions > 0,
              run.plannedResultCount > 0,
              run.effectiveResults.count == run.plannedResultCount,
              run.scoredCount == run.plannedResultCount,
              run.errorCount == 0 else { return false }
        let expected = Set(evidence.cases.flatMap { evaluationCase in
            (1...run.repetitions).map { SampleCoordinate(caseID: evaluationCase.id, repetition: $0) }
        })
        let observed = Set(run.effectiveResults.map {
            SampleCoordinate(caseID: $0.caseID, repetition: $0.repetition)
        })
        return expected.count == evidence.cases.count * run.repetitions
            && expected.count == run.plannedResultCount
            && observed.count == run.effectiveResults.count
            && observed == expected
    }

    static func laneResult(
        from run: EvaluationRun,
        definition: ScenarioDefinition
    ) -> ScenarioLaneResult {
        let status: ScenarioExecutionStatus
        if !isEligible(run, for: definition) {
            status = .invalidEvidence
        } else if run.cancelled {
            status = .cancelled
        } else if run.terminationReason != nil {
            status = .crashed
        } else {
            status = .completed
        }

        var observations: [String: ScenarioValue] = [
            "feature.runID": .string(run.id.uuidString),
            "feature.resultCount": .integer(Int64(run.results.count)),
        ]
        if let passRate = run.passRate {
            observations["feature.passRate"] = .number(passRate)
        }
        if run.results.count == 1, let result = run.results.first {
            observations["feature.response"] = .string(result.response)
            for (key, value) in result.structuredFeatureEvidence?.metadata ?? [:] {
                observations["feature.metadata.\(key)"] = .string(value)
            }
            if let encoded = result.structuredFeatureEvidence?.encodedValue {
                observations["feature.encodedValue"] = .string(encoded.base64EncodedString())
            }
            if let typeName = result.structuredFeatureEvidence?.encodedValueTypeName {
                observations["feature.encodedValueType"] = .string(typeName)
            }
        }

        let evaluated = ScenarioResultEvaluator.evaluate(
            definition: definition,
            lane: .appFeature,
            observations: observations,
            executionStatus: status
        )
        let hasSubjectFailure = run.failedCount > 0 || run.errorCount > 0
        let outcome: ScenarioOutcome
        if status != .completed {
            outcome = .notObserved
        } else if hasSubjectFailure || evaluated.0 == .failed {
            outcome = .failed
        } else if run.scoredCount == 0 || evaluated.0 == .needsReview {
            outcome = .needsReview
        } else {
            outcome = .passed
        }

        return ScenarioLaneResult(
            caseID: definition.id,
            attempt: 1,
            lane: .appFeature,
            executionStatus: status,
            outcome: outcome,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            observations: observations,
            assertionResults: evaluated.1,
            diagnostic: run.terminationSummary,
            proposedCause: nil
        )
    }
}
