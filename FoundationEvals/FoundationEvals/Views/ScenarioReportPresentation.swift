import Foundation

/// Presentation of saved evidence only. This never changes a run's recorded outcome.
struct ScenarioReportPresentation {
    let run: ScenarioRun
    let definition: ScenarioDefinition?

    var includedLanes: [ScenarioLane] {
        ScenarioLane.allCases.filter { lane in
            definition?.coverage[lane] != .notApplicable || run.laneResults.contains { $0.lane == lane }
        }
    }

    var omittedLanes: [ScenarioLane] {
        ScenarioLane.allCases.filter { !includedLanes.contains($0) }
    }

    var headline: String {
        switch run.outcome {
        case .passed: "This test passed"
        case .failed: "This test did not pass"
        case .needsReview: "This result needs review"
        case .notObserved: run.executionStatus == .cancelled ? "This test was stopped" : "This test is missing results"
        case .notApplicable: "No required checks were run"
        }
    }

    var nextStep: String {
        switch run.outcome {
        case .passed: "Run this test again after changing your app to check for regressions."
        case .failed: "Review the failed checks below, fix the app or the test, then run it again."
        case .needsReview: "Review the captured evidence before deciding whether the expected result occurred."
        case .notObserved: "Check the app connection and device, then run this test again."
        case .notApplicable: "Include at least one required part in your test, then run it again."
        }
    }

    static func title(for lane: ScenarioLane) -> String {
        switch lane {
        case .appFeature: "App evaluation"
        case .intentIntegration: "App action"
        case .siri: "Siri"
        }
    }

    static func checkScope(for definition: ScenarioDefinition) -> String {
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion, definition.checkMode == .basic {
            return definition.requiredClaims?.contains(.returnedValueChecked) == true
                ? "Checks that the action runs and its returned value matches. Changes inside the app are not verified."
                : "Checks that the action runs. Returned values and changes inside the app are not verified."
        }
        return "Checks the observed result against the expectations you add to this test."
    }

    func outcome(for lane: ScenarioLane) -> ScenarioOutcome {
        let outcomes = run.laneResults.filter { $0.lane == lane }.map(\.outcome)
        if outcomes.isEmpty { return definition?.coverage[lane] == .notApplicable ? .notApplicable : .notObserved }
        // Keep incomplete or mixed attempts visible; one successful attempt is not a complete pass.
        for outcome in [ScenarioOutcome.failed, .notObserved, .needsReview] where outcomes.contains(outcome) {
            return outcome
        }
        if outcomes.allSatisfy({ $0 == .notApplicable }) { return .notApplicable }
        return outcomes.contains(.notApplicable) ? .notObserved : .passed
    }

    func summary(for lane: ScenarioLane) -> String {
        switch outcome(for: lane) {
        case .failed: return "At least one check did not match the expected result."
        case .notObserved: return "There is not enough captured evidence to verify this part."
        case .needsReview: return "Evidence was captured. Review it to assess the result."
        case .notApplicable: return "This part was not tested."
        case .passed:
            if lane == .intentIntegration, let definition,
               definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion, definition.checkMode == .basic {
                return definition.requiredClaims?.contains(.returnedValueChecked) == true
                    ? "The action ran and its returned value matched. Changes inside the app were not verified."
                    : "The action ran. Returned values and changes inside the app were not verified."
            }
            return switch lane {
            case .appFeature: "The linked app evaluation passed its checks."
            case .intentIntegration: "The app action matched this test’s checks."
            case .siri: "The Siri request matched this test’s checks."
            }
        }
    }

    static func executionTitle(_ status: ScenarioExecutionStatus) -> String {
        switch status {
        case .completed: "Finished"
        case .blockedByEnvironment: "Device or setup blocked the test"
        case .timedOut: "The test took too long"
        case .cancelled: "Stopped"
        case .crashed: "The app or test runner crashed"
        case .failedToBuild: "The app could not be built"
        case .invalidEvidence: "Captured evidence could not be verified"
        }
    }
}
