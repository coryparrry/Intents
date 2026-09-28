import IntentLabContracts

/// Reject routes that this test bundle cannot execute before preparing the app.
enum IntentLabRoutePolicy {
    static func validate(
        scenario: IntentLabScenario,
        directExecutorAvailable: Bool,
        queryOperationsAvailable: Bool
    ) throws {
        let runsDirect = scenario.executionScope == nil
            || scenario.executionScope?.lane == .intentIntegration
        if runsDirect && scenario.coverage.intentIntegration != .notApplicable
            && !directExecutorAvailable {
            throw IntentLabExecutionPathError.directIntentRequired
        }
        if !queryOperationsAvailable,
           (scenario.observationPlan ?? []).contains(where: {
               $0.source == .entityQuery || $0.source == .valueQuery
           }) {
            throw IntentLabExecutionPathError.queryObservationRequired
        }
    }
}
