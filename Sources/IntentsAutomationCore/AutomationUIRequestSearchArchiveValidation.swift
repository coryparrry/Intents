import Foundation

extension AutomationUIFailureSearchRecord {
    /// Historical reset facts do not restore a live UI fixture token or tracker.
    func validateUIRequestQualification() throws {
        guard let fixture = baseline.plan.uiRequestFixture, let qualification = report.qualificationAttempts,
              qualification.count <= 2, report.usage.reservedSubjectOperations <= 5500,
              report.usage.reservedUIActions <= 1000, report.usage.controllerCalls <= 300,
              report.usage.reservedSetupOperations <= 1000, report.usage.reservedObserverOperations <= 1000,
              mutations.allSatisfy({ $0.subjectPhraseSlot == .uiRequestBinding("approvedText") }),
              !mutations.isEmpty, reductions?.isEmpty != false else { throw AutomationContractError.conflictingOperation }
        try fixture.validate(plan: baseline.plan)
        var identities = Set<String>()
        for (index, attempt) in qualification.enumerated() {
            guard attempt.caseDigest == baseline.digest else { throw AutomationContractError.conflictingOperation }
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: baseline.plan, expectedRunID: runID)
            if attempt.report.result.subjectDispatched {
                let identity = try fixture.identity(receipts: attempt.report.receipts, plan: baseline.plan, runID: runID, attemptID: attempt.report.attemptID)
                guard identities.insert(identity).inserted else { throw AutomationContractError.conflictingOperation }
            }
            if !attempt.report.resourcesReleased || !attempt.report.result.subjectCompleted || attempt.report.result.subjectDispatchUncertain {
                guard index == qualification.count - 1, report.attempts.isEmpty else { throw AutomationContractError.conflictingOperation }
            }
        }
        if !report.attempts.isEmpty { guard qualification.count == 2 else { throw AutomationContractError.conflictingOperation } }
        for attempt in report.attempts where attempt.report.result.subjectDispatched {
            guard let frozen = ([baseline] + mutations.map(\.frozen)).first(where: { $0.digest == attempt.caseDigest }) else { throw AutomationContractError.conflictingOperation }
            let identity = try fixture.identity(receipts: attempt.report.receipts, plan: frozen.plan, runID: runID, attemptID: attempt.report.attemptID)
            guard identities.insert(identity).inserted else { throw AutomationContractError.conflictingOperation }
        }
    }
}
