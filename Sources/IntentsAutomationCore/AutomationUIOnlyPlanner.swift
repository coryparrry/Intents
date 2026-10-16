import Foundation

/// A reviewed, deterministic UI workflow with an independent visible-state check.
public enum AutomationUIOnlyPlanner {
    public static func compile(app: AppIdentity, target: TargetIdentity, program: AutomationUIProgram,
                               description: String = "Run reviewed UI steps", expectedVisibleText: String = "",
                               observationLabel: String = "", observationProperty: String = "text",
                               approval: RunApproval, localeIdentifier: String) throws -> AutomationCase {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.utf16.count <= 4096, !description.contains("\0"),
              app == approval.app, target == approval.target, [.simulator, .nativeMac].contains(target.kind),
              !localeIdentifier.isEmpty, localeIdentifier.utf16.count <= 128,
              expectedVisibleText.utf16.count <= 1024, observationLabel.utf16.count <= 1024,
              ["text", "value", "checked", "selected"].contains(observationProperty),
              approval.maximumActions >= 30 else { throw AutomationContractError.invalidPlan("Invalid UI workflow approval") }
        try program.validate(phase: .subject)
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: description,
            effects: approval.effects, lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = program
        var observers: [AutomationSegment] = [], requirements: [AutomationRequirement] = []
        if !expectedVisibleText.isEmpty {
            let expected: AutomationValue
            if ["checked", "selected"].contains(observationProperty) {
                guard ["true", "false"].contains(expectedVisibleText) else { throw AutomationContractError.invalidPlan("Boolean properties require true or false") }
                expected = .bool(expectedVisibleText == "true")
            } else { expected = .text(expectedVisibleText) }
            var observer = AutomationSegment(id: "visible-state", kind: .ui, phase: .observe, operation: "Read approved visible state",
                effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
            observer.uiProgram = .init(operations: [.init(id: "visible-text", kind: .observeProperty,
                locator: .init(.label, observationLabel.isEmpty ? expectedVisibleText : observationLabel), property: observationProperty)])
            observers = [observer]
            // Both UI route drivers retain verified properties by operation ID.
            requirements = [.init(observationID: observer.id, expected: .object(["visible-text": expected]), proof: .visibleState,
                justification: "Developer approved this property independently of navigation",
                checkID: observationProperty == "text" ? "business.visible-text" : "business.visible-property")]
        }
        var budget = AutomationBudget(); budget.subjectOperations = target.kind == .nativeMac ? (program.steps?.count ?? program.operations.count) + 2 : 1; budget.attempts = 1
        budget.uiActions = 30; budget.controllerCalls = 0; budget.wallClockSeconds = 180
        var plan = AutomationCase(id: "ui-workflow", app: app, target: target, environmentID: approval.environmentID,
            execution: subject, observations: observers, requirements: requirements, budget: budget)
        plan.provenance = ["ui.locale": localeIdentifier, "inputs": "native approval", "expectation": requirements.isEmpty ? "navigation only; unassessed" : "independent visible-state check"]
        plan.id = "ui." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        var validationApproval = approval
        validationApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: validationApproval, capabilities: .init())
        try subject.uiProgram!.validate(phase: .subject)
        for observer in observers { try observer.uiProgram!.validate(phase: .observe) }
        return plan
    }
}
