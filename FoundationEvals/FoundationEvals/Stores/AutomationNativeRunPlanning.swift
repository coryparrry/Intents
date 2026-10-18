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

struct AutomationNativeRunSelection: Equatable, Sendable {
    let epoch: Int
    let candidateID: String
    let workflowRoute: String
    let simulatorID: String
    let installApproved: Bool
    let candidate: AutomationApplicationCandidate?
    let prepared: AutomationPreparedApplication?
    let target: TargetIdentity?
    let configuration: String
    let instruction: String, endpoint: String, approvedText: String, expectedText: String
    let observationLabel: String, observationProperty: String, effectChoice: String
    let disposable: Bool, effectsConfirmed: Bool
    let tapControls: String, textEntry: String, submitControl: String
}

extension AppAutomationStore {
    var nativeRunSelection: AutomationNativeRunSelection {
        .init(epoch: selectionEpoch, candidateID: candidateID, workflowRoute: workflowRoute,
            simulatorID: simulatorID, installApproved: installApproved, candidate: candidate, prepared: prepared,
            target: prepared?.host.target, configuration: configuration,
            instruction: uiInstruction, endpoint: uiEndpoint, approvedText: uiApprovedText, expectedText: uiExpectedText,
            observationLabel: uiObservationLabel, observationProperty: uiObservationProperty, effectChoice: effectChoice,
            disposable: disposable, effectsConfirmed: effectsConfirmed, tapControls: uiTapControls, textEntry: uiTextEntryControl, submitControl: uiSubmitControl)
    }
    /// Capture value snapshots on the main actor; verify retained prepared artifacts off it.
    func nativeRunVerificationWork(runID: String) throws -> @Sendable () throws -> AutomationNativeRunRequest {
        guard canRun else { throw AutomationContractError.targetBusy }
        guard !isMacWorkflowUnavailable else {
            throw AutomationContractError.missingEvidence("Native Mac workflow execution is unavailable")
        }
        if isUIWorkflow { return try preparedUIRunVerificationWork(runID: runID) }
        let request = try makeNativeRunRequest(runID: runID)
        return { request }
    }
    private func preparedUIRunVerificationWork(runID: String) throws -> @Sendable () throws -> AutomationNativeRunRequest {
        guard let candidate else { throw AutomationContractError.invalidIdentity }
        let retainedPrepared = prepared, selection = nativeRunSelection
        let locale = Locale.current.identifier
        guard candidate.kind == .sourceTarget && workflowRoute == "ui" && preparedUISelectionMatches && retainedPrepared != nil else {
            throw AutomationContractError.missingEvidence("Prepare this source app for the selected configuration and destination")
        }
        return {
            guard let prepared = retainedPrepared else { throw AutomationContractError.invalidIdentity }
            let subject = AutomationApplicationSubject.prepared(prepared)
            var effects: Set<AutomationEffect> = [.observe, .navigate]
            if selection.effectChoice == "fixture" { effects.insert(.fixtureWrite) }
            if selection.effectChoice == "external" { effects.insert(.externalWrite) }
            let install = subject.target.kind == .simulator && selection.installApproved
            var approval = RunApproval(runID: runID, app: subject.app, target: subject.target,
                environmentID: Self.preparedEnvironmentID(prepared), effects: effects, maximumActions: 30, disposable: selection.disposable)
            var plan = try AutomationUIOnlyPlanner.compile(app: subject.app, target: subject.target, program: try AutomationNativeWorkflowSteps.program(tapControls: selection.tapControls,
                    textEntry: selection.textEntry, approvedText: selection.approvedText, submitControl: selection.submitControl, endpoint: selection.endpoint),
                description: selection.instruction, expectedVisibleText: selection.expectedText,
                observationLabel: selection.observationProperty == "text" ? "" : selection.observationLabel,
                observationProperty: selection.observationProperty, approval: approval, localeIdentifier: locale)
            plan.provenance["ui.backend"] = "xcuitest"
            try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: prepared)
            try AutomationNativeWorkflowSteps.applyBudget(to: &plan, approval: approval)
            plan.id = "ui." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
            let digest = try AutomationFrozenCase.planDigest(plan); approval.approvedCaseDigest = digest
            try PlanValidator.validate(plan, approval: approval, capabilities: .init(), purpose: .review)
            let fields = ["plan": digest,
                "install": String(install), "disposable": String(selection.disposable), "maximumActions": String(approval.maximumActions)]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return .init(subject: subject, plan: plan, approval: approval, capabilities: .init(),
                installApproved: install, digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: digest)
        }
    }
    func verifiedNativeRunRequest(runID: String) async throws -> AutomationNativeRunRequest {
        let epoch = selectionEpoch, selection = nativeRunSelection, pending = pendingCommandStatus
        let cancellationID = requestVerificationCancellationID
        let verify = try nativeRunVerificationWork(runID: runID)
        let request = try await AutomationNativeOffMainVerification.run(verify)
        try Task.checkCancellation()
        try validateRequestVerificationCancellation(cancellationID)
        guard canRun, selectionEpoch == epoch, nativeRunSelection == selection,
              pendingCommandStatus?.requestID == pending?.requestID,
              pendingCommandStatus?.state == pending?.state else { throw AutomationContractError.conflictingOperation }
        if !isUIWorkflow {
            guard try makeNativeRunRequest(runID: runID).digest == request.digest else { throw AutomationContractError.conflictingOperation }
        }
        return request
    }

    nonisolated static func preparedEnvironmentID(_ prepared: AutomationPreparedApplication) -> String {
        prepared.host.target.kind == .nativeMac
            ? "selected-mac-session:" + (prepared.host.target.loginSession ?? "")
            : "selected-simulator:" + prepared.host.target.id
    }
    var preparedUISelectionMatches: Bool {
        guard let prepared, candidate?.kind == .sourceTarget,
              prepared.host.app.logicalID == candidateID,
              prepared.host.app.configuration == configuration, prepared.generatedHost.configuration == configuration,
              prepared.host.app.productDigest != nil, prepared.host.target == sourcePreparationTarget else { return false }
        switch prepared.host.target.kind {
        case .simulator: return prepared.host.app.platform == "ios"
        case .nativeMac: return prepared.host.app.platform == "macos"
        case .physical, .pairedRunner: return false
        }
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
            saveControl: try AutomationNativeWorkflowSteps.locator(freshSaveControl), includeProtectedRecord: true,
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
        var approval = RunApproval(runID: runID, app: prepared.host.app, target: prepared.host.target,
            environmentID: Self.preparedEnvironmentID(prepared), effects: effects, maximumActions: 20, disposable: disposable)
        let capabilities = AutomationPreparedCapabilities.base(prepared)
        var values: [String: AutomationActionInput] = [:]
        for parameter in action.parameters where parameter.family != "entity" {
            if let raw = inputs[parameter.name] { values[parameter.name] = try AutomationCodecRegistry.input(raw, parameter: parameter, catalog: prepared.catalog) }
        }
        let declaration = AutomationActionEffectDeclaration(app: prepared.host.app, actionID: action.id, effects: effects,
            developerConfirmation: "Developer confirmed the selected action stays within " + effectChoice + " effects in the approval view")
        var plan: AutomationCase
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
        if prepared.host.target.kind == .nativeMac {
            try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: prepared)
        }
        let install = prepared.host.target.kind == .simulator && installApproved
        let caseDigest = try AutomationFrozenCase.planDigest(plan)
        approval.approvedCaseDigest = caseDigest
        let fields = ["plan": caseDigest, "host": prepared.host.hostProductDigest,
            "xctestrun": prepared.host.xctestrunDigest, "catalog": try AutomationRecipeContext.catalogDigest(prepared.catalog),
            "install": String(install), "disposable": String(disposable), "maximumActions": String(approval.maximumActions)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities, installApproved: install,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), caseDigest: caseDigest)
    }
    func makeUIRunRequest(runID: String) throws -> AutomationNativeRunRequest {
        try preparedUIRunVerificationWork(runID: runID)()
    }
}
#endif
