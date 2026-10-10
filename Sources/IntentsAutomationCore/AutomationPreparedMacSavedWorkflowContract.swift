#if os(macOS)
import Foundation

extension AutomationMacSavedWorkflowContract {
    public static func reproduction(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                    prepared: AutomationPreparedApplication, runtimeRoot: URL, runID: String, disposable: Bool) throws -> Reproduction {
        try reproduction(frozen: frozen, original: original, prepared: prepared, runtimeRoot: runtimeRoot,
            runID: runID, disposable: disposable, dependencies: .init())
    }
    static func reproduction(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                             prepared: AutomationPreparedApplication, runtimeRoot: URL, runID: String, disposable: Bool,
                             dependencies: Dependencies) throws -> Reproduction {
        guard AutomationUIFailureSearchRecord.identifier(runID), frozen.plan.preparedMacBuildArtifacts != nil else {
            throw AutomationContractError.missingEvidence("Select a versioned prepared Mac failure for review")
        }
        try frozen.validate(); try AutomationRecordedEvidence.validate(report: original, plan: frozen.plan)
        try AutomationPreparedMacBuildArtifacts.validateSelection(prepared, plan: frozen.plan)
        let target = try dependencies.currentTarget(), runtime = try dependencies.runtime(runtimeRoot)
        guard target == prepared.host.target, frozen.plan.environmentID == "selected-mac-session:" + (target.loginSession ?? ""),
              frozen.plan.provenance["ui.locale"] == dependencies.locale(),
              frozen.plan.provenance["ui.privateMacReceiptSHA256"] == runtime.receiptSHA256,
              let inputs = AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: runtime.receiptSHA256),
              original.result.summary == .assertionFailed, original.result.assessed, original.result.evidenceComplete,
              original.resourcesReleased, !original.result.subjectDispatchUncertain else {
            throw AutomationContractError.missingEvidence("Review the exact retained prepared Mac build, session, runtime and released assessed failure")
        }
        let fresh = (try? AutomationFreshEntityPlanner.bindings(plan: frozen.plan)) != nil
        let capabilities = fresh ? preparedMacCapabilities(prepared) : CapabilityProfile()
        let effects: Set<AutomationEffect> = fresh ? [.observe, .navigate, .fixtureWrite] : [.observe, .navigate]
        let approval = RunApproval(runID: runID, app: prepared.host.app, target: target, environmentID: frozen.plan.environmentID,
            effects: effects, maximumActions: 30, disposable: disposable, approvedCaseDigest: frozen.digest)
        try AutomationPreparedProgramContract.validate(frozen.plan, catalog: prepared.catalog)
        try PlanValidator.validate(frozen.plan, approval: approval, capabilities: capabilities, purpose: .review)
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        if fresh {
            try AutomationQualifiedFreshFixture.validateProposal(bindings: AutomationFreshEntityPlanner.bindings(plan: frozen.plan),
                plan: frozen.plan, approval: approval, capabilities: capabilities, purpose: .review)
        } else {
            guard segments.allSatisfy({ $0.kind == .ui && $0.effects.isSubset(of: [.observe, .navigate]) }) else {
                throw AutomationContractError.invalidPlan("Prepared Mac saved review requires UI-only checks or a disposable fresh-record workflow")
            }
            for segment in segments { try AutomationMacUIProgramPreflight.validateReadOnly(segment, capabilities: inputs, allowNavigationGoals: true) }
        }
        for segment in segments where segment.kind == .ui {
            try AutomationMacUIProgramPreflight.validateDeferred(segment, capabilities: inputs, attemptID: original.attemptID)
        }
        guard try dependencies.currentTarget() == target else { throw AutomationContractError.conflictingOperation }
        try AutomationPreparedMacBuildArtifacts.validateSelection(prepared, plan: frozen.plan)
        // Review data cannot restore imported fixture authority or enable a runtime owner.
        return .init(frozen: frozen, originalAttemptID: original.attemptID, approval: approval, runtimeEvidence: runtime, capabilities: capabilities)
    }
    public static func comparison(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                  before: AutomationPreparedApplication, after: AutomationPreparedApplication,
                                  runtimeRoot: URL, runID: String, disposable: Bool) throws -> Comparison {
        try comparison(frozen: frozen, original: original, before: before, after: after, runtimeRoot: runtimeRoot,
            runID: runID, disposable: disposable, dependencies: .init())
    }
    static func comparison(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                           before: AutomationPreparedApplication, after: AutomationPreparedApplication,
                           runtimeRoot: URL, runID: String, disposable: Bool, dependencies: Dependencies) throws -> Comparison {
        let reviewed = try reproduction(frozen: frozen, original: original, prepared: before, runtimeRoot: runtimeRoot,
            runID: runID + ".before", disposable: disposable, dependencies: dependencies)
        let candidate = try AutomationFixContract.candidate(from: frozen, prepared: after)
        try AutomationPreparedMacBuildArtifacts.validateSelection(after, plan: candidate.plan)
        let capabilities = (try? AutomationFreshEntityPlanner.bindings(plan: candidate.plan)) != nil ? preparedMacCapabilities(after) : CapabilityProfile()
        let approval = RunApproval(runID: runID + ".after", app: after.host.app, target: after.host.target,
            environmentID: candidate.plan.environmentID, effects: reviewed.approval.effects, maximumActions: 30,
            disposable: disposable, approvedCaseDigest: candidate.digest)
        try AutomationPreparedProgramContract.validate(candidate.plan, catalog: after.catalog)
        try PlanValidator.validate(candidate.plan, approval: approval, capabilities: capabilities, purpose: .review)
        guard try dependencies.currentTarget() == after.host.target else { throw AutomationContractError.conflictingOperation }
        try AutomationPreparedMacBuildArtifacts.validateSelection(before, plan: frozen.plan)
        try AutomationPreparedMacBuildArtifacts.validateSelection(after, plan: candidate.plan)
        return .init(baseline: frozen, candidate: candidate, beforeApproval: reviewed.approval, afterApproval: approval,
            runtimeEvidence: reviewed.runtimeEvidence, beforeCapabilities: reviewed.capabilities, afterCapabilities: capabilities)
    }
    private static func preparedMacCapabilities(_ prepared: AutomationPreparedApplication) -> CapabilityProfile {
        var value = AutomationEntityQuery.capabilities(prepared)
        value.records["apple.intent.invoke"] = .init(state: .available,
            reason: "Associated host build; registration is checked during invocation", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])
        return value
    }
}
#endif
