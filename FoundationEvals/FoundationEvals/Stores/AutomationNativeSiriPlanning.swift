#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeSiriOracle: Equatable {
    var enabled = false
    var entityType = "", nameProperty = "", recordName = "", stateProperty = ""
    var initialState = "", expectedState = ""
}

extension AppAutomationStore {
    var siriEntity: ApplicationSurfaceCatalog.Entity? { catalog?.entities?.first { $0.typeID == siriOracle.entityType } }
    var siriOracleIsValid: Bool {
        effectChoice == "fixture" && siriCapabilities.supports(["apple.entity.query"]) && siriEntity?.properties[siriOracle.nameProperty] == "text" &&
            siriEntity?.properties[siriOracle.stateProperty] == "bool" &&
            !siriOracle.recordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            siriOracle.recordName.utf16.count <= 1024 && !siriOracle.recordName.contains("\0") &&
            ["true", "false"].contains(siriOracle.initialState) && ["true", "false"].contains(siriOracle.expectedState) &&
            siriOracle.initialState != siriOracle.expectedState
    }
    func runNativePreparedRequest(_ request: AutomationNativeRunRequest, runner: AutomationApplicationRunner, attemptID: String) async throws -> AutomationAttemptReport {
        if request.siriQualification, case .prepared(let prepared) = request.subject {
            return try await runner.qualifySiriWorkflow(prepared: prepared, plan: request.plan, approval: request.approval,
                capabilities: request.capabilities, attemptID: attemptID, allowInstall: request.installApproved)
        }
        return try await runner.run(subject: request.subject, plan: request.plan, approval: request.approval,
            capabilities: request.capabilities, attemptID: attemptID, allowBootAndInstall: request.installApproved, uiRuntime: request.uiRuntime)
    }

    var isSiriWorkflow: Bool { candidate?.kind == .sourceTarget && workflowRoute == "siri" }
    var canRunSiriSubmission: Bool {
        !busy && preparationDestination == .physical && prepared?.host.target.kind == .physical &&
            prepared?.generatedHost.includesSiri == true &&
            prepared?.host.target == sourcePreparationTarget && prepared?.host.app.logicalID == candidateID &&
            prepared?.host.app.configuration == configuration && prepared?.generatedHost.configuration == configuration &&
            siriCapabilities.supports(["siri.recognizedText.api"]) && !siriRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            siriRequest.utf16.count <= 2048 && !siriRequest.contains("\0") && effectsConfirmed &&
            ["navigation", "fixture", "external"].contains(effectChoice) && disposable && installApproved &&
            report?.result.subjectDispatchUncertain != true && report?.resourcesReleased != false && (!siriOracle.enabled || siriOracleIsValid)
    }
    func makeSiriRunRequest(runID: String) throws -> AutomationNativeRunRequest {
        guard isSiriWorkflow, canRun, let prepared, prepared.host.target == sourcePreparationTarget else { throw AutomationContractError.invalidIdentity }
        var effects: Set<AutomationEffect> = [.observe, .navigate]
        if effectChoice == "fixture" { effects.insert(.fixtureWrite) }
        if effectChoice == "external" { effects.insert(.externalWrite) }
        var segment = AutomationSegment(id: "siri", kind: .siriText, phase: .subject, operation: "submitRecognizedText",
            requiredCapabilities: ["siri.recognizedText.api"], effects: effects, lifecycle: .persistedStateAcrossSegments)
        let program = AutomationSiriTextProgram(request: siriRequest); segment.siriProgram = program
        var plan = AutomationCase(id: "siri-submission", app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-physical:" + physicalDeviceID, execution: segment)
        if siriOracle.enabled {
            guard let catalog else { throw AutomationContractError.invalidIdentity }
            let proposal = RunApproval(runID: runID, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                effects: effects, maximumActions: 20, disposable: disposable)
            plan = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: siriOracle.entityType,
                nameProperty: siriOracle.nameProperty, recordName: siriOracle.recordName, stateProperty: siriOracle.stateProperty,
                initialState: siriOracle.initialState == "true", expectedState: siriOracle.expectedState == "true",
                request: siriRequest, approval: proposal, capabilities: siriCapabilities)
        }
        plan.provenance.merge(try AutomationNativeUIRuntime.preparedProvenance(prepared)) { _, prepared in prepared }
        plan.provenance["siri.evidenceScope"] = siriOracle.enabled ? "controlledExistingRecordState" : "recognizedTextSubmissionOnly"
        plan.provenance["physical.installedBytesVerified"] = "false"
        plan.id = "siri-" + (try AutomationFrozenCase.planDigest(plan))
        var approval = RunApproval(runID: runID, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            effects: effects, maximumActions: 20, disposable: disposable)
        let digest = try AutomationFrozenCase.planDigest(plan); approval.approvedCaseDigest = digest
        try PlanValidator.validate(plan, approval: approval, capabilities: siriCapabilities, purpose: siriOracle.enabled ? .review : .execution)
        let fields = ["plan": digest, "host": prepared.host.hostProductDigest, "xctestrun": prepared.host.xctestrunDigest,
            "install": String(installApproved), "disposable": String(disposable)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(subject: .prepared(prepared), uiRuntime: nil, plan: plan, approval: approval, capabilities: siriCapabilities,
            installApproved: installApproved, digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: digest, siriQualification: siriOracle.enabled)
    }
}
#endif
