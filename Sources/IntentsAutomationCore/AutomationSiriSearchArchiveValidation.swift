import Foundation

extension AutomationUIFailureSearchRecord {
    /// Verifies historical reset and outcome facts only. Decoding cannot mint Siri authority.
    func validateSiriQualification() throws {
        let population = [baseline] + mutations.map(\.frozen)
        guard let qualification = report.qualificationAttempts, qualification.count <= population.count * 2,
              !mutations.isEmpty, mutations.allSatisfy({ $0.subjectPhraseSlot == .siriRecognizedText }),
              reductions?.isEmpty != false else { throw AutomationContractError.conflictingOperation }
        var counts: [String: Int] = [:]
        for (index, attempt) in qualification.enumerated() {
            guard let frozen = population.first(where: { $0.digest == attempt.caseDigest }),
                  counts[attempt.caseDigest, default: 0] < 2,
                  population.prefix(while: { $0.digest != frozen.digest }).allSatisfy({ counts[$0.digest] == 2 }) else {
                throw AutomationContractError.conflictingOperation
            }
            let approval = RunApproval(runID: runID, app: frozen.plan.app, target: frozen.plan.target,
                environmentID: frozen.plan.environmentID, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
            try AutomationSiriRepeatableQualification.validateStructure(plan: frozen.plan, approval: approval)
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: frozen.plan, expectedRunID: runID)
            counts[attempt.caseDigest, default: 0] += 1
            if (try? AutomationSiriSubmissionQualification.validate(report: attempt.report, plan: frozen.plan, approval: approval)) == nil {
                guard index == qualification.count - 1, report.attempts.isEmpty, report.stopReason != nil else {
                    throw AutomationContractError.conflictingOperation
                }
            }
        }
        if !report.attempts.isEmpty { guard population.allSatisfy({ counts[$0.digest] == 2 }) else { throw AutomationContractError.conflictingOperation } }
    }
}
