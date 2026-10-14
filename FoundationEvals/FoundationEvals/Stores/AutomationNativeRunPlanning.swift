#if os(macOS)
import Foundation
import IntentsAutomationCore

/// A synchronous verifier must not inherit the native window's executor.
/// Cancellation is checked on both sides of the immutable, read-only work.
enum AutomationNativeOffMainVerification {
    @concurrent static func run<Value: Sendable>(_ verify: @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try verify()
        try Task.checkCancellation()
        return value
    }
}

extension AppAutomationStore {
    var preparedUISelectionMatches: Bool {
        prepared?.host.app.logicalID == candidateID && prepared?.host.app.platform == "ios" &&
        prepared?.host.app.configuration == configuration && prepared?.generatedHost.configuration == configuration &&
        prepared?.host.target.kind == .simulator && prepared?.host.target.id == simulatorID && prepared?.host.app.productDigest != nil
    }
    func makeFreshRecordRequest(runID: String) throws -> AutomationNativeRunRequest {
        guard let prepared, preparedUISelectionMatches, ["true", "false"].contains(freshInitialState),
              ["true", "false"].contains(freshExpectedState) else { throw AutomationContractError.invalidIdentity }
        let capabilities = AutomationPreparedCapabilities.base(prepared)
        var approval = RunApproval(runID: runID, app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + simulatorID, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: disposable)
        var plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: actionID,
            instruction: uiInstruction, endpoint: uiEndpoint, namePrefix: freshNamePrefix, nameProperty: freshNameProperty,
            stateProperty: freshStateProperty, initialState: freshInitialState == "true", expectedState: freshExpectedState == "true",
            approval: approval, capabilities: capabilities, localeIdentifier: Locale.current.identifier, context: freshContext, purpose: .simulatorDraft,
            saveControl: try AutomationNativeWorkflowSteps.locator(freshSaveControl),
            createControl: try AutomationNativeWorkflowSteps.optionalLocator(freshCreateControl),
            nameEntry: try AutomationNativeWorkflowSteps.locator(freshNameEntryControl),
            contextEntry: try AutomationNativeWorkflowSteps.optionalLocator(freshContextEntryControl))
        try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: prepared)
        for index in plan.setup.indices {
            guard var program = plan.setup[index].uiProgram else { continue }
            for operation in program.operations.indices where program.operations[operation].kind == .assertEndpoint {
                program.operations[operation].locator = try AutomationNativeWorkflowSteps.locator(uiEndpoint)
            }
            plan.setup[index].uiProgram = program
        }
        try AutomationNativeWorkflowSteps.applyBudget(to: &plan, approval: approval)
        plan.id = "fresh." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        let digest = try AutomationFrozenCase.planDigest(plan); approval.approvedCaseDigest = digest
        let fields = ["plan": digest,
            "host": prepared.host.hostProductDigest, "xctestrun": prepared.host.xctestrunDigest,
            "catalog": try AutomationRecipeContext.catalogDigest(prepared.catalog), "install": String(installApproved),
            "disposable": String(disposable), "maximumActions": String(approval.maximumActions)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities,
            installApproved: installApproved, digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: digest)
    }
    func makeNativeRunRequest(runID: String) throws -> AutomationNativeRunRequest {
        guard canRun else { throw AutomationContractError.missingEvidence("Select a workflow with inputs and permitted effects in the native app") }
        if isSiriWorkflow { return try makeSiriRunRequest(runID: runID) }
        if isUIWorkflow { return try makeUIRunRequest(runID: runID) }
        if isFreshRecordWorkflow { return try makeFreshRecordRequest(runID: runID) }
        guard let prepared, let action else { throw AutomationContractError.missingEvidence("Prepare and select a system action") }
        var effects: Set<AutomationEffect> = [.observe, .navigate]
        if effectChoice == "fixture" { effects.insert(.fixtureWrite) }
        if effectChoice == "external" { effects.insert(.externalWrite) }
        let approval = RunApproval(runID: runID, app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + prepared.host.target.id, effects: effects, maximumActions: 20, disposable: disposable)
        let capabilities = AutomationPreparedCapabilities.base(prepared)
        var values: [String: AutomationActionInput] = [:]
        for parameter in action.parameters where parameter.family != "entity" {
            if let raw = inputs[parameter.name] { values[parameter.name] = try AutomationCodecRegistry.input(raw, parameter: parameter, catalog: prepared.catalog) }
        }
        let declaration = AutomationActionEffectDeclaration(app: prepared.host.app, actionID: action.id, effects: effects,
            developerConfirmation: "Developer confirmed the selected action stays within " + effectChoice + " effects in the approval view")
        let plan: AutomationCase
        if action.parameters.contains(where: { $0.family == "entity" }) {
            var selections: [String: AutomationQueryEntityChoice] = [:], protected: [String: [AutomationQueryEntityChoice]] = [:], expectations: [String: [String: AutomationValue]] = [:]
            for parameter in action.parameters where parameter.family == "entity" {
                if let selected = selectedEntity(parameter.name) { selections[parameter.name] = selected }
                let protectedIDs = protectedEntityIDs[parameter.name] ?? []
                let records = (entityChoices[parameter.name] ?? []).filter { protectedIDs.contains($0.id) }.sorted(by: { $0.id < $1.id })
                guard records.count == protectedIDs.count else { throw AutomationContractError.conflictingOperation }
                protected[parameter.name] = records
                if let entity = entityDefinition(parameter) {
                    for (name, codec) in entity.properties where codec == "bool" {
                        if let choice = entityExpectedBooleans[parameter.name + "." + name], ["true", "false"].contains(choice) {
                            expectations[parameter.name, default: [:]][name] = .bool(choice == "true")
                        }
                    }
                }
            }
            plan = try AutomationEntityActionPlanner.compile(catalog: prepared.catalog, actionID: action.id, textInputs: values,
                selections: selections, protectedSelections: protected, expectations: expectations, declaredEffects: declaration, approval: approval, capabilities: capabilities, purpose: .review)
        } else {
            plan = try AutomationTemplatePlanner.compile(catalog: prepared.catalog, actionID: action.id, inputs: values,
                declaredEffects: declaration, approval: approval, capabilities: capabilities, purpose: .review)
        }
        let caseDigest = try AutomationFrozenCase.planDigest(plan)
        let fields = ["plan": caseDigest, "host": prepared.host.hostProductDigest,
            "xctestrun": prepared.host.xctestrunDigest, "catalog": try AutomationRecipeContext.catalogDigest(prepared.catalog),
            "install": String(installApproved), "disposable": String(disposable), "maximumActions": String(approval.maximumActions)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities, installApproved: installApproved,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: caseDigest)
    }
    func makeUIRunRequest(runID: String) throws -> AutomationNativeRunRequest {
        guard let candidate else { throw AutomationContractError.invalidIdentity }
        guard candidate.kind == .sourceTarget, workflowRoute == "ui", preparedUISelectionMatches, let prepared else {
            throw AutomationContractError.missingEvidence("Prepare this source app for the selected configuration and simulator")
        }
        let subject = AutomationApplicationSubject.prepared(prepared)
        var effects: Set<AutomationEffect> = [.observe, .navigate]
        if effectChoice == "fixture" { effects.insert(.fixtureWrite) }
        if effectChoice == "external" { effects.insert(.externalWrite) }
        var approval = RunApproval(runID: runID, app: subject.app, target: subject.target,
            environmentID: "selected-simulator:" + simulatorID, effects: effects, maximumActions: 30, disposable: disposable)
        var plan = try AutomationUIOnlyPlanner.compile(app: subject.app, target: subject.target, instruction: uiInstruction,
            endpoint: uiEndpoint, approvedText: uiApprovedText, expectedVisibleText: uiExpectedText,
            observationLabel: uiObservationProperty == "text" ? "" : uiObservationLabel,
            observationProperty: uiObservationProperty, approval: approval, localeIdentifier: Locale.current.identifier)
        if case .prepared(let prepared) = subject { try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: prepared) }
        plan.execution.uiProgram = try AutomationNativeWorkflowSteps.program(tapControls: uiTapControls, textEntry: uiTextEntryControl,
            approvedText: uiApprovedText, submitControl: uiSubmitControl, endpoint: uiEndpoint)
        plan.provenance["ui.backend"] = "xcuitest"
        try AutomationNativeWorkflowSteps.applyBudget(to: &plan, approval: approval)
        plan.id = "ui." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        let caseDigest = try AutomationFrozenCase.planDigest(plan)
        approval.approvedCaseDigest = caseDigest
        let fields = ["plan": caseDigest,
            "install": String(installApproved), "disposable": String(disposable), "maximumActions": String(approval.maximumActions)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(subject: subject, plan: plan, approval: approval, capabilities: .init(),
            installApproved: installApproved, digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: caseDigest)
    }
}
#endif
