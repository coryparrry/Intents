import Foundation

extension AutomationFixComparisonReport {
    public var complete: Bool {
        before.count == requestedAttemptsPerBuild && after.count == requestedAttemptsPerBuild && stopReason == nil && interruption == nil &&
            (before + after).allSatisfy { $0.resourcesReleased && !$0.result.subjectDispatchUncertain && ![.cancelled, .invalidFixture].contains($0.result.summary) }
    }
    public func validate() throws {
        try AutomationFixContract.validate(baseline: baseline, candidate: candidate)
        guard schemaVersion == 1, contractDigest == baseline.contractDigest, (1...100).contains(requestedAttemptsPerBuild),
              AutomationUIFailureSearchRecord.identifier(beforeRunID), AutomationUIFailureSearchRecord.identifier(afterRunID), beforeRunID != afterRunID,
              before.count <= requestedAttemptsPerBuild, after.count <= requestedAttemptsPerBuild,
              after.isEmpty || before.count == requestedAttemptsPerBuild, !environmentQualificationComplete,
              comparisonScope == "Same frozen declared contract and environment; observed counts, not guaranteed reliability",
              stopReason.map({ !$0.isEmpty && $0.utf16.count <= 4096 }) ?? true else { throw AutomationContractError.conflictingOperation }
        let ids = (before + after).map(\.attemptID) + (interruption.map { [$0.attemptID] } ?? [])
        guard ids.allSatisfy(AutomationUIFailureSearchRecord.identifier), Set(ids).count == ids.count else { throw AutomationContractError.conflictingOperation }
        var beforeComputed = ScopeCounters(), afterComputed = ScopeCounters(), seen = Set<String>()
        let segments = baseline.plan.setup + [baseline.plan.execution] + baseline.plan.observations + baseline.plan.cleanup
        let mutating = !segments.allSatisfy { $0.effects.isSubset(of: [.observe, .navigate]) }
        for (frozen, reports, runID, isBefore) in [(baseline, before, beforeRunID, true), (candidate, after, afterRunID, false)] {
            for (index, report) in reports.enumerated() {
                try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan, expectedRunID: runID)
                if mutating && (report.result.subjectDispatched || report.result.subjectDispatchUncertain) {
                    let identities = try AutomationQualifiedFreshFixture.recordedIdentities(report: report, plan: frozen.plan)
                    guard seen.isDisjoint(with: identities) else { throw AutomationFixtureFreshnessError.invalidFixture }
                    seen.formUnion(identities)
                }
                if isBefore { beforeComputed.record(report.result) } else { afterComputed.record(report.result) }
                if !report.resourcesReleased || report.result.subjectDispatchUncertain || [.cancelled, .invalidFixture].contains(report.result.summary) {
                    guard index == reports.count - 1, interruption == nil, stopReason != nil,
                          !isBefore || after.isEmpty else { throw AutomationContractError.conflictingOperation }
                }
            }
        }
        var beforeInterrupted = 0, afterInterrupted = 0
        if let value = interruption {
            guard value.stage == .baseline, !value.reason.isEmpty, value.reason.utf16.count <= 4096, stopReason != nil else { throw AutomationContractError.conflictingOperation }
            if value.caseDigest == baseline.digest {
                guard after.isEmpty, before.count < requestedAttemptsPerBuild else { throw AutomationContractError.conflictingOperation }
                beforeInterrupted = 1; beforeComputed.planned += 1
                if value.dispatchMayHaveOccurred { beforeComputed.unresolved += 1 } else { beforeComputed.notRun += 1 }
            } else {
                guard value.caseDigest == candidate.digest, before.count == requestedAttemptsPerBuild, after.count < requestedAttemptsPerBuild else { throw AutomationContractError.conflictingOperation }
                afterInterrupted = 1; afterComputed.planned += 1
                if value.dispatchMayHaveOccurred { afterComputed.unresolved += 1 } else { afterComputed.notRun += 1 }
            }
        }
        for (usage, count) in [(beforeUsage, before.count + beforeInterrupted), (afterUsage, after.count + afterInterrupted)] {
            let values = [usage.attempts, usage.reservedSubjectOperations, usage.reservedSetupOperations, usage.reservedObserverOperations,
                usage.reservedCleanupOperations, usage.reservedUIActions, usage.controllerCalls, usage.reservedResourceReleaseOperations]
            guard usage.attempts == count, usage.appModelRequests == nil, values.allSatisfy({ (0...100_000).contains($0) }) else { throw AutomationContractError.conflictingOperation }
        }
        guard complete || stopReason != nil, beforeCounters == beforeComputed, afterCounters == afterComputed else { throw AutomationContractError.conflictingOperation }
    }
}
