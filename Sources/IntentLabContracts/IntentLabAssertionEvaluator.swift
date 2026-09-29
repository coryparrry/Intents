import Foundation

public enum IntentLabAssertionEvaluator {
    public static func actionVerdict(
        requirement: IntentLabActionRequirement?,
        receipts: [IntentLabActionReceipt]?,
        lane: IntentLabLane,
        attempt: Int,
        context: String
    ) -> (IntentLabOutcome, IntentLabActionFailureReason?) {
        guard let requirement else { return (.passed, nil) }
        guard let receipts, !receipts.isEmpty else { return (.notObserved, .missingActionEvidence) }
        guard receipts.count <= 16,
              receipts.allSatisfy({
                  $0.attemptContext == context && $0.lane == lane && $0.attempt == attempt
              }) else { return (.notObserved, .staleActionEvidence) }
        let topLevel = receipts.filter(\.isTopLevel)
        guard !topLevel.isEmpty else { return (.notObserved, .missingActionEvidence) }
        guard Set(receipts.map(\.executionID)).count == receipts.count,
              Set(receipts.map(\.sequence)).count == receipts.count,
              receipts.allSatisfy({
                  $0.sequence > 0 && $0.completedAt >= $0.startedAt
                      && !$0.operationID.isEmpty && ($0.kind != .testSupport || !$0.isTopLevel)
                      && ($0.terminalStatus != .succeeded || $0.operationError == nil)
                      && ($0.terminalStatus != .failed || $0.operationError?.isEmpty == false)
              }) else { return (.notObserved, .invalidActionEvidence) }
        guard topLevel.count == requirement.allowedExecutionCount else {
            return (.failed, .unexpectedExecution)
        }
        guard Set(receipts.map(\.appSessionID)).count == 1 else {
            return (.notObserved, .invalidActionEvidence)
        }
        guard topLevel.allSatisfy({
            $0.kind == requirement.kind && $0.operationID == requirement.operationID
        }) else { return (.failed, .wrongAction) }
        guard topLevel.allSatisfy({ $0.resolvedParameters == requirement.resolvedParameters }) else {
            return (.failed, .wrongParameter)
        }
        guard topLevel.allSatisfy({ $0.terminalStatus == .succeeded }) else {
            return (.failed, .operationError)
        }
        return (.passed, nil)
    }

    public static func failureReason(
        action: (IntentLabOutcome, IntentLabActionFailureReason?),
        deterministicFailure: Bool
    ) -> IntentLabActionFailureReason? {
        action.1 ?? (action.0 == .passed && deterministicFailure ? .wrongOutcome : nil)
    }

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
