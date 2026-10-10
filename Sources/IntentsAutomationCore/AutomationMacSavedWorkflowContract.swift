#if os(macOS)
import Foundation

/// Reviews saved Mac data against current selection/session/runtime facts. It does not enable execution.
public enum AutomationMacSavedWorkflowContract {
    public struct Reproduction: Sendable {
        public let frozen: AutomationFrozenCase
        public let originalAttemptID: String
        public let approval: RunApproval
        public let runtimeEvidence: AutomationPrivateMacDaemonUnit.Evidence
        public var capabilities = CapabilityProfile()
    }
    public struct Comparison: Sendable {
        public let baseline: AutomationFrozenCase
        public let candidate: AutomationFrozenCase
        public let beforeApproval: RunApproval
        public let afterApproval: RunApproval
        public let runtimeEvidence: AutomationPrivateMacDaemonUnit.Evidence
        public var beforeCapabilities = CapabilityProfile()
        public var afterCapabilities = CapabilityProfile()
    }
    struct Dependencies: Sendable {
        var currentTarget: @Sendable () throws -> TargetIdentity = { try AutomationMacGUIIdentity.currentTarget() }
        var runtime: @Sendable (URL) throws -> AutomationPrivateMacDaemonUnit.Evidence = { try AutomationPrivateMacDaemonUnit.verify(root: $0) }
        var locale: @Sendable () -> String = { Locale.current.identifier }
    }
    public static func reproduction(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                    selected: AutomationInstalledMacUIApplication, runtimeRoot: URL, runID: String) throws -> Reproduction {
        try reproduction(frozen: frozen, original: original, selected: selected, runtimeRoot: runtimeRoot, runID: runID, dependencies: .init())
    }
    static func reproduction(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                             selected: AutomationInstalledMacUIApplication, runtimeRoot: URL, runID: String, dependencies: Dependencies) throws -> Reproduction {
        guard AutomationUIFailureSearchRecord.identifier(runID) else { throw AutomationContractError.invalidIdentity }
        try frozen.validate(); try AutomationRecordedEvidence.validate(report: original, plan: frozen.plan)
        try selected.verifySelectedProduct()
        let current = try dependencies.currentTarget(), evidence = try dependencies.runtime(runtimeRoot)
        guard current == selected.target, frozen.plan.app == selected.app, frozen.plan.target == current,
              frozen.plan.environmentID == "selected-mac-session:" + (current.loginSession ?? ""),
              frozen.plan.provenance["ui.locale"] == dependencies.locale(),
              frozen.plan.provenance["ui.privateMacReceiptSHA256"] == evidence.receiptSHA256,
              let inputs = AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: evidence.receiptSHA256),
              original.result.summary == .assertionFailed, original.result.assessed, original.result.evidenceComplete,
              original.resourcesReleased, !original.result.subjectDispatchUncertain else {
            throw AutomationContractError.missingEvidence("Select the exact app, Mac session and runtime of a released assessed failure")
        }
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        for segment in segments {
            try AutomationMacUIProgramPreflight.validateReadOnly(segment, capabilities: inputs)
        }
        let approval = RunApproval(runID: runID, app: selected.app, target: selected.target, environmentID: frozen.plan.environmentID,
            effects: [.observe, .navigate], maximumActions: 30, disposable: false, approvedCaseDigest: frozen.digest)
        try PlanValidator.validate(frozen.plan, approval: approval, capabilities: .init())
        // Session can change while the independent runtime tree is being read.
        guard try dependencies.currentTarget() == current else { throw AutomationContractError.conflictingOperation }
        try selected.verifySelectedProduct()
        return .init(frozen: frozen, originalAttemptID: original.attemptID, approval: approval, runtimeEvidence: evidence)
    }
    public static func comparison(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                  before: AutomationInstalledMacUIApplication, after: AutomationInstalledMacUIApplication,
                                  runtimeRoot: URL, runID: String) throws -> Comparison {
        try comparison(frozen: frozen, original: original, before: before, after: after, runtimeRoot: runtimeRoot, runID: runID, dependencies: .init())
    }
    static func comparison(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                           before: AutomationInstalledMacUIApplication, after: AutomationInstalledMacUIApplication,
                           runtimeRoot: URL, runID: String, dependencies: Dependencies) throws -> Comparison {
        let reviewed = try reproduction(frozen: frozen, original: original, selected: before, runtimeRoot: runtimeRoot, runID: runID + ".before", dependencies: dependencies)
        guard after.target == before.target else { throw AutomationContractError.conflictingOperation }
        try after.verifySelectedProduct()
        let candidate = try AutomationFixContract.candidate(from: frozen, app: after.app)
        let afterApproval = RunApproval(runID: runID + ".after", app: after.app, target: after.target,
            environmentID: candidate.plan.environmentID, effects: [.observe, .navigate], maximumActions: 30,
            disposable: false, approvedCaseDigest: candidate.digest)
        try PlanValidator.validate(candidate.plan, approval: afterApproval, capabilities: .init())
        guard try dependencies.currentTarget() == after.target else { throw AutomationContractError.conflictingOperation }
        try before.verifySelectedProduct(); try after.verifySelectedProduct()
        return .init(baseline: frozen, candidate: candidate, beforeApproval: reviewed.approval, afterApproval: afterApproval, runtimeEvidence: reviewed.runtimeEvidence)
    }
}
#endif
