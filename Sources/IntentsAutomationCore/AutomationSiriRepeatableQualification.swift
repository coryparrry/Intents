import Foundation

/// One approved reset of the independently selected disposable record, followed
/// by an independent initial-state query and the original frozen Siri outcome.
public enum AutomationSiriRepeatableQualification {
    public static func restoring(_ baseline: AutomationCase, catalog: ApplicationSurfaceCatalog,
                                 actionID: String, approval: RunApproval, capabilities: CapabilityProfile) throws -> AutomationCase {
        try AutomationSiriQualificationProposal.validate(plan: baseline, approval: approval)
        guard catalog.app == baseline.app, let action = catalog.systemActions.first(where: { $0.id == actionID }),
              action.compiled, action.registered, action.parametersComplete, action.parameters.count == 2,
              action.resultFamily == nil || action.resultFamily == "noValue",
              let entity = action.parameters.first(where: { $0.family == "entity" }),
              let boolean = action.parameters.first(where: { $0.family == "bool" }),
              entity.typeID == baseline.setup[0].hostProgram?.operations[0].typeID,
              let predicate = baseline.setupChecks?[0].entityProperty,
              let initial = baseline.setupChecks?[0].expected else {
            throw AutomationContractError.invalidPlan("Choose a registered reset action with exactly one matching record and one Boolean state parameter")
        }
        var plan = baseline
        var selection = baseline.setup[0]; selection.id = "siri.select"
        var reset = AutomationSegment(id: "siri.restore", kind: .systemIntent, phase: .setup, operation: action.id,
            requiredCapabilities: ["apple.intent.invoke"], effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        reset.hostProgram = .init(operations: [.init(id: "restore", kind: .invoke, typeID: action.id,
            parameters: [boolean.name: initial], resultCodec: "noValue")])
        reset.inputBindings = [.init(producerSegmentID: selection.id, outputID: predicate.operationID,
            destination: .hostParameter, operationID: "restore", name: entity.name, uniqueEntity: predicate.selection)]
        var before = baseline.setup[0]
        before.hostProgram?.operations[0].queryText = nil
        before.inputBindings = [.init(producerSegmentID: selection.id, outputID: predicate.operationID,
            destination: .hostQueryIDs, operationID: predicate.operationID, name: "queryIDs", uniqueEntity: predicate.selection)]
        plan.setup = [selection, reset, before]
        plan.provenance["siri.repeatableReset"] = action.id
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        plan.id = "siri-repeatable-" + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        try validateStructure(plan: plan, approval: approval)
        var scoped = approval; scoped.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: scoped, capabilities: capabilities, purpose: .review)
        return plan
    }

    public static func validate(plan: AutomationCase, approval: RunApproval, authority: AutomationSiriRouteAuthority?) throws {
        try validateStructure(plan: plan, approval: approval)
        guard let authority, !authority.isQualification, authority.isRepeatableQualification else {
            throw AutomationContractError.missingEvidence("Repeated Siri search requires two fresh released submission-channel qualifications of each exact approved phrase")
        }
        try authority.validate(plan: plan, approval: approval)
    }

    static func validateStructure(plan: AutomationCase, approval: RunApproval) throws {
        guard plan.setup.count == 3, let action = plan.provenance["siri.repeatableReset"],
              plan.setup[0].id == "siri.select", plan.setup[1].id == "siri.restore",
              let predicate = plan.setupChecks?.first?.entityProperty,
              let initial = plan.setupChecks?.first?.expected else { throw AutomationContractError.invalidPlan("Missing scoped Siri record restoration") }
        let select = plan.setup[0], reset = plan.setup[1], before = plan.setup[2]
        var expectedBefore = select; expectedBefore.id = before.id
        expectedBefore.hostProgram?.operations[0].queryText = nil
        expectedBefore.inputBindings = [.init(producerSegmentID: select.id, outputID: predicate.operationID,
            destination: .hostQueryIDs, operationID: predicate.operationID, name: "queryIDs", uniqueEntity: predicate.selection)]
        guard before == expectedBefore, reset.kind == .systemIntent, reset.phase == .setup,
              reset.operation == action, Set(reset.requiredCapabilities) == ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"],
              reset.requiredCapabilities.count == 3, reset.effects == [.fixtureWrite],
              reset.lifecycle == .persistedStateAcrossSegments, reset.inputs.isEmpty,
              reset.uiProgram == nil, reset.siriProgram == nil, reset.attemptTextBindings?.isEmpty != false,
              reset.hostProgram?.operations.count == 1, let operation = reset.hostProgram?.operations.first,
              operation.id == "restore", operation.kind == .invoke, operation.typeID == action,
              operation.resultCodec == "noValue", operation.parameters.count == 1,
              operation.parameters.values.first == initial,
              let binding = reset.inputBindings?.first, reset.inputBindings?.count == 1,
              binding.producerSegmentID == select.id, binding.outputID == predicate.operationID,
              binding.destination == .hostParameter, binding.operationID == operation.id,
              binding.uniqueEntity == predicate.selection, binding.parameterCodec == nil,
              operation.parameters[binding.name] == nil else { throw AutomationContractError.invalidPlan("Siri reset must restore only the selected record to the approved initial state") }
        var original = plan; var originalBefore = select; originalBefore.id = before.id
        original.setup = [originalBefore]; original.provenance.removeValue(forKey: "siri.repeatableReset")
        try AutomationSiriQualificationProposal.validateSingle(plan: original, approval: approval)
        try AutomationInputResolver.validate(plan: plan)
        try AutomationRequirementValidator.validate(plan: plan)
    }
}
