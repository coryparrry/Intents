#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    var canReviewPreparedMacFreshWorkflow: Bool {
        isFreshRecordWorkflow && preparationDestination == .macOS && canSelectApplicationFromCommand &&
        effectChoice == "fixture" && effectsConfirmed && disposable && !useLearnedSetup &&
        prepared?.host.target == sourcePreparationTarget && prepared?.host.target.kind == .nativeMac &&
        prepared?.host.app.logicalID == candidateID && prepared?.host.app.configuration == configuration &&
        prepared?.generatedHost.configuration == configuration &&
        ["true", "false"].contains(freshInitialState) && ["true", "false"].contains(freshExpectedState) &&
        freshContextValid && freshGoalValid && report?.resourcesReleased != false && report?.result.subjectDispatchUncertain != true
    }

    /// Build-only provenance supports review, never an execution capability or approval.
    func reviewPreparedMacFreshWorkflow() throws -> AutomationNativeMacWorkflowReview {
        guard canReviewPreparedMacFreshWorkflow, let prepared, let candidate,
              let target = sourcePreparationTarget else { throw AutomationContractError.missingEvidence("Prepare this Mac app and complete the disposable record workflow") }
        try validatePreparedSelection(prepared, candidate: candidate,
            approval: .init(sourceRoot: prepared.source.sourceRoot, candidateID: candidateID, configuration: configuration, target: target, additionalSourceRoots: prepared.source.capturedRoots?.dropFirst().map(\.inputPath) ?? []))
        var capabilities = AutomationEntityQuery.capabilities(prepared)
        capabilities.records["apple.intent.invoke"] = .init(state: .available,
            reason: "Draft validation from associated-host build only; execution is unqualified", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])
        var approval = RunApproval(runID: "mac-fresh-record-draft", app: prepared.host.app, target: target,
            environmentID: "selected-mac-session:" + target.loginSession!, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: actionID,
            instruction: uiInstruction, endpoint: uiEndpoint, namePrefix: freshNamePrefix, nameProperty: freshNameProperty,
            stateProperty: freshStateProperty, initialState: freshInitialState == "true", expectedState: freshExpectedState == "true",
            approval: approval, capabilities: capabilities, localeIdentifier: Locale.current.identifier, context: freshContext, purpose: .nativeMacDraft,
            saveControl: freshSaveControl.isEmpty ? nil : .init(.label, freshSaveControl))
        try AutomationNativeUIRuntime.attachPreparedEvidence(to: &plan, prepared: prepared)
        plan.id = "fresh." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        let digest = try AutomationFrozenCase.planDigest(plan); approval.approvedCaseDigest = digest
        guard try nativeMacTargetReader() == target else { throw AutomationContractError.conflictingOperation }
        return .init(plan: plan, approval: approval, bundlePath: prepared.host.subjectProductPath,
            visibleCheck: "\(freshStateProperty): \(freshInitialState) before → \(freshExpectedState) after" +
                (freshContext == nil ? "" : "; the other same-name record remains \(freshInitialState)."), id: digest, kind: .freshRecord)
    }
}
#endif
