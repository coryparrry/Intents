import Foundation

public enum AutomationSiriWorkflowContract {
    public static func validate(plan: AutomationCase, approval: RunApproval) throws {
        if plan.provenance["siri.repeatableReset"] != nil {
            try AutomationSiriResetPlan.validateStructure(plan: plan, approval: approval); return
        }
        try validateSingle(plan: plan, approval: approval)
    }
    static func validateSingle(plan: AutomationCase, approval: RunApproval) throws {
        guard plan.target.kind == .physical, plan.app == approval.app, plan.target == approval.target,
              plan.environmentID == approval.environmentID, approval.disposable,
              plan.execution.kind == .siriText, plan.execution.siriProgram != nil,
              plan.execution.effects == [.observe, .navigate, .fixtureWrite],
              plan.setup.count == 1, plan.observations.count == 1, plan.cleanup.isEmpty,
              plan.setupChecks?.count == 1, plan.requirements.count == 1,
              let before = plan.setupChecks?.first, let after = plan.requirements.first,
              before.entityProperty == after.entityProperty, let predicate = before.entityProperty,
              before.proof == .appState, after.proof == .appState,
              case .bool(let initial) = before.expected, case .bool(let expected) = after.expected,
              initial != expected, before.observationID == plan.setup[0].id,
              after.observationID == plan.observations[0].id else {
            throw AutomationContractError.invalidPlan("Siri workflow needs an approved disposable record with different before and after states")
        }
        let baseline = plan.setup[0], observer = plan.observations[0]
        guard baseline.kind == .systemQuery, baseline.effects == [.observe], baseline.requiredCapabilities == ["apple.entity.query"],
              observer.kind == .systemQuery, observer.effects == [.observe], observer.requiredCapabilities == ["apple.entity.query"],
              baseline.hostProgram?.operations.count == 1, observer.hostProgram?.operations.count == 1,
              let query = baseline.hostProgram?.operations.first, let readback = observer.hostProgram?.operations.first,
              query.kind == .query, readback.kind == .query, query.id == predicate.operationID,
              query.id == readback.id, query.typeID == readback.typeID, query.properties == readback.properties,
              let text = query.queryText, !text.isEmpty, query.queryIDs == nil, query.attemptQueryPrefix == nil,
              readback.queryText == nil, readback.queryIDs == nil, readback.attemptQueryPrefix == nil,
              predicate.selection.attemptProperties == nil,
              predicate.selection.matchingProperties.values.contains(.text(text)),
              baseline.inputBindings?.isEmpty != false, baseline.attemptTextBindings?.isEmpty != false,
              observer.attemptTextBindings?.isEmpty != false,
              observer.inputBindings == [.init(producerSegmentID: baseline.id, outputID: query.id,
                destination: .hostQueryIDs, operationID: query.id, name: "queryIDs", uniqueEntity: predicate.selection)],
              query.properties?[predicate.property] == "bool" else {
            throw AutomationContractError.invalidPlan("Siri workflow must independently query the same uniquely selected real record before and after submission")
        }
        try AutomationRequirementValidator.validate(plan: plan)
    }
}
