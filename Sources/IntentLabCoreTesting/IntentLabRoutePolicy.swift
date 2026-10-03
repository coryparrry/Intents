import Foundation
import IntentLabContracts

/// Reject routes that this test bundle cannot execute before preparing the app.
enum IntentLabRoutePolicy {
    static func validate(
        scenario: IntentLabScenario,
        directExecutorAvailable: Bool,
        queryOperationsAvailable: Bool,
        featureExecutorAvailable: Bool = false
    ) throws {
        if scenario.executionScope?.lane == .appFeature && !featureExecutorAvailable {
            throw IntentLabLocalFeatureExecutionError.executorRequired
        }
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

public enum IntentLabLocalFeatureExecutionError: LocalizedError {
    case executorRequired
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case .executorRequired:
            "This app-feature scenario requires the IntentLabTesting project-local feature executor."
        case .invalidResult:
            "The project-local feature executor returned observations outside its declared typed contract."
        }
    }
}
