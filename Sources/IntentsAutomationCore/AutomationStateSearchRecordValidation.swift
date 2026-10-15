import Foundation

extension AutomationUIFailureSearchRecord {
    /// Historical facts only. Even a valid archive cannot restore a live fixture token.
    func validateStateSearch() throws {
        let qualification = report.qualificationAttempts ?? []
        guard Self.identifier(id), Self.identifier(runID), report.schemaVersion == 1,
              report.baselineDigest == baseline.digest, (1...3).contains(mutations.count), qualification.count <= 8,
              report.attempts.count + qualification.count + report.interruptions.count <= 100,
              report.interruptions.count <= 1, report.confirmations.count <= 8,
              report.capabilityGaps.count <= 20, report.capabilityGaps.allSatisfy({ $0.utf16.count <= 4096 }),
              report.stopReason.map({ !$0.isEmpty && $0.utf16.count <= 4096 }) == true else { throw AutomationContractError.invalidIdentity }
        try baseline.validate(); _ = try AutomationFreshEntityPlanner.bindings(plan: baseline.plan)
        let all = [baseline] + mutations.map(\.frozen)
        guard Set(all.map(\.digest)).count == all.count else { throw AutomationContractError.conflictingOperation }
        let definitions = Dictionary(uniqueKeysWithValues: all.map { ($0.digest, $0) })
        let recipeCounts = Dictionary(uniqueKeysWithValues: mutations.map { ($0.frozen.digest, $0.recipeIDs.count) })
        for mutation in mutations {
            try mutation.frozen.validate(); _ = try AutomationStateMutationPlanner.bindings(plan: mutation.frozen.plan)
            guard mutation.frozen.oracleDigest == baseline.oracleDigest, mutation.frozen.plan.execution == baseline.plan.execution,
                  mutation.frozen.plan.observations == baseline.plan.observations, mutation.frozen.plan.app == baseline.plan.app,
                  mutation.frozen.plan.target == baseline.plan.target, mutation.frozen.plan.environmentID == baseline.plan.environmentID,
                  (1...2).contains(mutation.recipeIDs.count), Set(mutation.recipeIDs).count == mutation.recipeIDs.count,
                  Set(mutation.kinds).isSubset(of: [.duplicateLabel, .unrelatedData]), !mutation.kinds.isEmpty,
                  mutation.semanticJustification.utf16.count <= 4096, !mutation.semanticJustification.isEmpty else { throw AutomationContractError.conflictingOperation }
        }
        let edges = reductions ?? []
        guard edges.count <= 5 else { throw AutomationContractError.invalidIdentity }
        for edge in edges {
            guard definitions[edge.parentDigest] != nil, definitions[edge.childDigest] != nil,
                  (recipeCounts[edge.childDigest] ?? 0) < (recipeCounts[edge.parentDigest] ?? 0),
                  !edge.semanticJustification.isEmpty, edge.semanticJustification.utf16.count <= 4096 else { throw AutomationContractError.conflictingOperation }
        }
        let identifiers = qualification.map { $0.report.attemptID } + report.attempts.map { $0.report.attemptID } + report.interruptions.map(\.attemptID)
        guard identifiers.allSatisfy(Self.identifier), Set(identifiers).count == identifiers.count else { throw AutomationContractError.conflictingOperation }
        let expectedQualification = all.flatMap { [$0.digest, $0.digest] }
        guard qualification.map(\.caseDigest) == Array(expectedQualification.prefix(qualification.count)) else { throw AutomationContractError.conflictingOperation }
        for (index, attempt) in qualification.enumerated() {
            guard let frozen = definitions[attempt.caseDigest] else { throw AutomationContractError.conflictingOperation }
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: frozen.plan, expectedRunID: runID)
            if !attempt.report.resourcesReleased || attempt.report.result.subjectDispatchUncertain || !attempt.report.result.subjectCompleted {
                guard index == qualification.count - 1, report.attempts.isEmpty else { throw AutomationContractError.conflictingOperation }
            }
        }
        if !report.attempts.isEmpty { guard qualification.count == expectedQualification.count else { throw AutomationContractError.conflictingOperation } }
        let baselines = report.attempts.filter { $0.stage == .baseline }
        try validateDiscoveryOrder()
        guard baselines.count <= 3, baselines.allSatisfy({ $0.caseDigest == baseline.digest }),
              report.attempts.allSatisfy({ $0.stage == .baseline }) || baselines.count == 3 else { throw AutomationContractError.conflictingOperation }
        let stages: [AutomationSearchAttempt.Stage: Int] = [.baseline: 0, .discovery: 1, .confirmation: 2, .reduction: 3, .finalConfirmation: 4]
        var previous = 0, counters = ScopeCounters(), candidates: [(String, [String])] = []
        for (index, attempt) in report.attempts.enumerated() {
            guard let stage = stages[attempt.stage], stage >= previous, let frozen = definitions[attempt.caseDigest] else { throw AutomationContractError.conflictingOperation }
            previous = stage
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: frozen.plan, expectedRunID: runID)
            counters.record(attempt.report.result)
            if !attempt.report.resourcesReleased || attempt.report.result.subjectDispatchUncertain {
                guard index == report.attempts.count - 1 else { throw AutomationContractError.conflictingOperation }
            }
            let result = attempt.report.result
            if (attempt.stage == .baseline || attempt.stage == .discovery), result.summary == .assertionFailed, result.assessed, result.evidenceComplete,
               !candidates.contains(where: { $0.0 == attempt.caseDigest }) { candidates.append((attempt.caseDigest, result.failedObservations.sorted())) }
        }
        let initial = Array(candidates.prefix(2))
        guard report.confirmations.count >= initial.count else { throw AutomationContractError.conflictingOperation }
        var best: String?, signature: [String] = [], used: [String] = []
        for (index, confirmation) in report.confirmations.enumerated() {
            let stage: AutomationSearchAttempt.Stage = index < initial.count ? .confirmation : .reduction
            if stage == .confirmation {
                guard confirmation.caseDigest == initial[index].0, confirmation.signature == initial[index].1 else { throw AutomationContractError.conflictingOperation }
                if best == nil && confirmation.confirmed { best = confirmation.caseDigest; signature = confirmation.signature }
            } else {
                guard let parent = best, confirmation.signature == signature,
                      edges.contains(where: { $0.parentDigest == parent && $0.childDigest == confirmation.caseDigest }) else { throw AutomationContractError.conflictingOperation }
                if confirmation.confirmed { best = confirmation.caseDigest }
            }
            try validate(confirmation, stage: stage, byDigest: definitions); used += confirmation.attempts
        }
        guard used == report.attempts.filter({ $0.stage == .confirmation || $0.stage == .reduction }).map({ $0.report.attemptID }), best == report.bestConfirmedCaseDigest else { throw AutomationContractError.conflictingOperation }
        let finals = report.attempts.filter { $0.stage == .finalConfirmation }.map { $0.report.attemptID }
        if let best {
            guard let final = report.finalReproduction, final.caseDigest == best, final.signature == signature, final.attempts == finals else { throw AutomationContractError.conflictingOperation }
            try validate(final, stage: .finalConfirmation, byDigest: definitions)
        } else { guard report.finalReproduction == nil, finals.isEmpty else { throw AutomationContractError.conflictingOperation } }
        for interrupted in report.interruptions {
            guard definitions[interrupted.caseDigest] != nil, !interrupted.reason.isEmpty, interrupted.reason.utf16.count <= 4096 else { throw AutomationContractError.conflictingOperation }
            counters.planned += 1
            if interrupted.dispatchMayHaveOccurred { counters.unresolved += 1 } else { counters.notRun += 1 }
        }
        let usage = report.usage
        guard counters == report.counters, usage.attempts == identifiers.count,
              (0...100).contains(usage.reservedSubjectOperations), (0...1000).contains(usage.reservedUIActions), (0...300).contains(usage.controllerCalls),
              [usage.reservedSetupOperations, usage.reservedObserverOperations, usage.reservedCleanupOperations, usage.reservedResourceReleaseOperations].allSatisfy({ (0...100_000).contains($0) }),
              usage.appModelRequests == nil else { throw AutomationContractError.conflictingOperation }
    }
}
