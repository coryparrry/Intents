import Foundation

public enum IntentLabAssertionEvaluator {
    public static func evaluate(
        _ assertion: IntentLabAssertion,
        observed: IntentLabValue?,
        before: IntentLabValue?
    ) -> IntentLabAssertionResult {
        if assertion.kind == .noMutation {
            guard let before, let observed else {
                return .init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: "Unchanged state requires both before and after observations."
                )
            }
            guard observed == before else {
                return .init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: "The selected state changed from its observed baseline."
                )
            }
            guard assertion.expectedValue == nil || assertion.expectedValue == before else {
                return .init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: "The observed baseline did not match the frozen starting value."
                )
            }
            return .init(
                assertionID: assertion.id,
                passed: true,
                observedValue: observed,
                message: "The selected state was unchanged after the completed action."
            )
        }
        let passed = observed != nil && observed == assertion.expectedValue
        return .init(
            assertionID: assertion.id,
            passed: passed,
            observedValue: observed,
            message: passed ? "Matched the frozen expectation." : "Observed value did not match."
        )
    }
}
