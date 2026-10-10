import Foundation

/// Native-authored UI workflow. Its business observer never enters the controller payload.
public enum AutomationUIOnlyPlanner {
    public static func compile(app: AppIdentity, target: TargetIdentity, instruction: String, endpoint: String,
                               approvedText: String = "", expectedVisibleText: String = "",
                               observationLabel: String = "", observationProperty: String = "text",
                               approval: RunApproval, localeIdentifier: String) throws -> AutomationCase {
        guard app == approval.app, target == approval.target, [.simulator, .nativeMac].contains(target.kind),
              !localeIdentifier.isEmpty, localeIdentifier.utf16.count <= 128,
              expectedVisibleText.utf16.count <= 1024, observationLabel.utf16.count <= 1024,
              ["text", "value", "checked", "selected"].contains(observationProperty), approvedText.utf16.count <= 32768,
              approval.maximumActions >= 30 else { throw AutomationContractError.invalidPlan("Invalid UI workflow approval") }
        if target.kind == .nativeMac {
            guard app.platform == "macos", app.productDigestVersion == 2, app.productDigest != nil,
                  app.canonicalBundlePath != nil, target.id == "host-macos-local", target.loginSession?.isEmpty == false,
                  approvedText.isEmpty else { throw AutomationContractError.missingEvidence("Mac workflow draft requires an exact app, current session and supported inputs") }
        }
        let goal = AutomationNavigationGoal(id: "navigate", instruction: instruction,
            endpoint: .init(.label, endpoint), maximumCalls: 12, maximumActions: 30)
        try goal.validate()
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: instruction,
            effects: approval.effects, lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: goal.id, kind: .navigateGoal, goal: goal)],
            bindings: approvedText.isEmpty ? [:] : ["approvedText": approvedText])
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
            requirements = [.init(observationID: observer.id, expected: expected, proof: .visibleState,
                justification: "Developer approved this property independently of navigation",
                checkID: observationProperty == "text" ? "business.visible-text" : "business.visible-property")]
        }
        var budget = AutomationBudget(); budget.subjectOperations = 1; budget.attempts = 1
        budget.uiActions = 30; budget.controllerCalls = 12; budget.wallClockSeconds = 180
        var plan = AutomationCase(id: "ui-workflow", app: app, target: target, environmentID: approval.environmentID,
            execution: subject, observations: observers, requirements: requirements, budget: budget)
        plan.provenance = ["ui.locale": localeIdentifier, "inputs": "native approval", "expectation": requirements.isEmpty ? "navigation only; unassessed" : "independent visible-state check"]
        if target.kind == .nativeMac {
            plan.provenance["ui.backend"] = "nativeMac"
            plan.provenance["ui.executionAvailability"] = "unqualified"
            try AutomationMacUIProgramPreflight.validate(subject)
            for observer in observers { try AutomationMacUIProgramPreflight.validate(observer) }
        }
        plan.id = "ui." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        var validationApproval = approval
        validationApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: validationApproval, capabilities: .init())
        try subject.uiProgram!.validate(phase: .subject)
        for observer in observers { try observer.uiProgram!.validate(phase: .observe) }
        return plan
    }
}
