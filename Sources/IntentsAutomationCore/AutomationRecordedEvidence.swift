import Foundation

public enum AutomationRecordedEvidence {
    /// Validate canonical facts and derive assertion outcomes. This does not
    /// promote external facts to trusted live execution or release evidence.
    public static func validate(report: AutomationAttemptReport, plan: AutomationCase, expectedRunID: String? = nil) throws {
        try AutomationRequirementValidator.validate(plan: plan)
        guard report.schemaVersion == 1, report.receipt == nil, !report.attemptID.isEmpty,
              report.result.policyDenial == nil || [.invalidFixture, .unresolved].contains(report.result.summary),
              Set(report.receipts.map(\.segmentID)).count == report.receipts.count else { throw AutomationContractError.invalidIdentity }
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        var runID: String?
        for receipt in report.receipts {
            try receipt.scope.validate()
            guard let segment = segments.first(where: { $0.id == receipt.segmentID }), receipt.route == segment.kind,
                  receipt.app == plan.app, receipt.target == plan.target, receipt.scope.segmentId == receipt.segmentID,
                  receipt.environmentID == nil || receipt.environmentID == plan.environmentID,
                  receipt.scope.attemptId == report.attemptID, !receipt.completed || receipt.dispatched,
                  runID == nil || runID == receipt.scope.runId else { throw AutomationContractError.conflictingOperation }
            guard expectedRunID == nil || expectedRunID == receipt.scope.runId else { throw AutomationContractError.conflictingOperation }
            runID = receipt.scope.runId
            for observation in receipt.observations {
                try observation.value.validate()
                guard segment.phase == .observe, observation.app == plan.app, observation.target == plan.target,
                      observation.environmentID == plan.environmentID, observation.attemptID == report.attemptID,
                      observation.stepID == receipt.segmentID, observation.id == receipt.segmentID, observation.route == receipt.route else { throw AutomationContractError.conflictingOperation }
            }
            for value in receipt.verifiedOutputs?.values ?? Dictionary<String, AutomationValue>().values { try value.validate() }
        }
        let subject = report.receipts.first { $0.segmentID == plan.execution.id }
        guard report.result.subjectDispatched == (subject?.dispatched ?? false), report.result.subjectCompleted == (subject?.completed ?? false),
              !(report.result.subjectCompleted && report.result.subjectDispatchUncertain) else { throw AutomationContractError.conflictingOperation }
        let observationFacts = report.receipts.filter { receipt in plan.observations.contains(where: { $0.id == receipt.segmentID }) }.flatMap(\.observations)
        let derived = AutomationAssessment.assess(plan: plan, attemptID: report.attemptID, subjectDispatched: report.result.subjectDispatched,
            subjectCompleted: report.result.subjectCompleted, observations: observationFacts, receipts: report.receipts, runID: runID)
        if [.passed, .assertionFailed, .executedUnassessed, .needsReview].contains(report.result.summary) {
            guard report.receipts.map(\.segmentID) == segments.map(\.id),
                  report.receipts.allSatisfy({ $0.dispatched && $0.completed }),
                  report.resourcesReleased else { throw AutomationContractError.conflictingOperation }
            for setup in plan.setup {
                guard let receipt = report.receipts.first(where: { $0.segmentID == setup.id }), let runID,
                      AutomationFixtureValidator.validates(receipt: receipt, segment: setup, plan: plan, runID: runID, attemptID: report.attemptID) else {
                    throw AutomationContractError.conflictingOperation
                }
            }
            guard report.result.summary == derived.summary, report.result.assessed == derived.assessed,
                  report.result.evidenceComplete == derived.evidenceComplete,
                  report.result.failedObservations == derived.failedObservations, report.result.missingObservations == derived.missingObservations else {
                throw AutomationContractError.conflictingOperation
            }
        } else {
            guard !report.result.assessed, !report.result.evidenceComplete, report.result.summary != .passed else { throw AutomationContractError.conflictingOperation }
        }
    }
}
