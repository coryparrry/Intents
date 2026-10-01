import Foundation

/// Freezes assertion results and proof claims while the action's completion
/// and observation-source callbacks still describe its active fixture.
package enum IntentLabResultCapture {
    package static func capture(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        observations: [String: IntentLabValue],
        baseline: [String: IntentLabValue]?,
        completion: () -> Bool,
        source: (String) -> String,
        declaration: IntentLabIntegrationDeclaration?,
        startedAt: Date,
        attempt: Int = 1,
        artifacts: [IntentLabArtifactReference] = []
    ) -> IntentLabLaneResult {
        let assertions = scenario.assertions.filter {
            $0.applicableLanes?.contains(lane) ?? (lane != .appFeature)
        }
        let checks = assertions.map { assertion in
            let observed = observations[assertion.observationKey]
            if assertion.kind == .semanticRubric {
                return IntentLabAssertionResult(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: observed == nil
                        ? "Required semantic evidence was not captured."
                        : "Semantic evidence requires host assessment."
                )
            }
            return IntentLabAssertionResult(
                assertionID: assertion.id,
                passed: observed != nil && observed == assertion.expectedValue,
                observedValue: observed,
                message: observed != nil && observed == assertion.expectedValue ? "Matched the frozen expectation." : "Observed value did not match."
            )
        }
        let required = assertions.filter(\.required)
        let semanticIDs = Set(required.filter { $0.kind == .semanticRubric }.map(\.id))
        let missingSemantic = required.contains {
            $0.kind == .semanticRubric && observations[$0.observationKey] == nil
        }
        let deterministicFailure = checks.contains { check in
            !semanticIDs.contains(check.assertionID)
                && required.contains(where: { $0.id == check.assertionID })
                && !check.passed
        }
        let outcome: IntentLabOutcome
        let planned = scenario.observationPlan ?? []
        let resultKeys = Set(scenario.directControl.outputFields.map(\.name))
        func observationSource(_ key: String) -> String {
            if let observer = declaration?.observers.first(where: { $0.id == key }),
               (observer.source == .entityQuery || observer.source == .valueQuery),
               (declaration?.queryOperations ?? []).contains(where: {
                   $0.id == observer.operationID && $0.source == observer.source
               }) {
                return observer.source.rawValue
            }
            return source(key)
        }
        let returnedChecked = assertions.contains {
            $0.kind == .returnedField && observations[$0.observationKey] != nil
                && resultKeys.contains($0.observationKey)
        }
        let stateChecked = assertions.contains { assertion in
            guard assertion.required, let observed = observations[assertion.observationKey],
                  let plan = planned.first(where: { $0.id == assertion.observationKey }),
                  plan.source != .intentResult,
                  let observer = declaration?.observers.first(where: { $0.id == plan.id }),
                  observer.type.accepts(observed) else { return false }
            let freshCompletion = completion()
                || (assertion.kind != .noMutation && lane == .intentIntegration
                    && baseline?[assertion.observationKey] != nil
                    && baseline?[assertion.observationKey] != observed)
            guard freshCompletion else { return false }
            let actual = observationSource(assertion.observationKey)
            let expected = plan.source == .uiElement ? "accessibleUI" : plan.source.rawValue
            return actual == expected
        }
        var claims: [IntentLabProofClaim] = [.executionCompleted]
        if lane == .intentIntegration && returnedChecked { claims.append(.returnedValueChecked) }
        if stateChecked { claims.append(.applicationStateChecked) }
        let missingClaim = scenario.schemaVersion == 2
            && (scenario.requiredClaims ?? []).contains(where: {
                !($0 == .returnedValueChecked && lane == .siri) && !claims.contains($0)
            })
        if deterministicFailure || missingSemantic {
            outcome = .failed
        } else if missingClaim || (scenario.schemaVersion == 2 && lane == .siri && !stateChecked) {
            outcome = .notObserved
        } else if !semanticIDs.isEmpty {
            outcome = .needsReview
        } else {
            outcome = .passed
        }
        return .init(
            caseID: scenario.id, attempt: attempt, lane: lane, executionStatus: .completed,
            outcome: outcome, startedAt: startedAt, completedAt: Date(),
            observations: observations, assertionResults: checks,
            diagnostic: nil, proposedCause: nil, artifacts: artifacts,
            observationSources: Dictionary(uniqueKeysWithValues: observations.keys.map {
                ($0, resultKeys.contains($0) && lane == .intentIntegration
                    ? "appIntentsTesting"
                    : $0 == "recognizedRequest" ? "siriRecognizedText" : observationSource($0))
            }),
            claims: scenario.schemaVersion == 2 ? claims : nil
        )
    }
}
