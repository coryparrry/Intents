import Foundation

public struct AutomationActionInput: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case approvedExample, verifiedQuery, declaredDefault, userChoice }
    public var value: AutomationValue
    public var origin: Origin
    public var evidence: String
    public init(value: AutomationValue, origin: Origin, evidence: String) { self.value = value; self.origin = origin; self.evidence = evidence }
}

public struct AutomationActionProposal: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var missingInputs: [String]
    public var gaps: [String]
}
public struct AutomationActionEffectDeclaration: Codable, Equatable, Sendable {
    public var app: AppIdentity
    public var actionID: String
    public var effects: Set<AutomationEffect>
    public var developerConfirmation: String
    public init(app: AppIdentity, actionID: String, effects: Set<AutomationEffect>, developerConfirmation: String) {
        self.app = app; self.actionID = actionID; self.effects = effects; self.developerConfirmation = developerConfirmation
    }
}

/// Deterministic templates use real declarations and trusted inputs. Names never establish effects or expectations.
public enum AutomationTemplatePlanner {
    public static func proposals(catalog: ApplicationSurfaceCatalog, inputs: [String: [String: AutomationActionInput]] = [:]) -> [AutomationActionProposal] {
        catalog.systemActions.map { action in
            let known = inputs[action.id] ?? [:]
            return .init(id: action.id, title: action.title,
                missingInputs: action.parameters.filter { !$0.optional && $0.defaultValue == nil && known[$0.name] == nil }.map(\.name),
                gaps: (action.parametersComplete ? [] : ["Input declarations or codecs are incomplete."]) +
                      ["Effects need approval. Runtime registration and behaviour are checked separately."])
        }
    }
    public static func compile(catalog: ApplicationSurfaceCatalog, actionID: String, inputs: [String: AutomationActionInput],
                               declaredEffects: AutomationActionEffectDeclaration, approval: RunApproval, capabilities: CapabilityProfile,
                               purpose: AutomationPlanValidationPurpose = .execution) throws -> AutomationCase {
        try compile(catalog: catalog, actionID: actionID, inputs: inputs, declaredEffects: declaredEffects,
                    approval: approval, capabilities: capabilities, setup: [], deferredInput: nil, recipeEvidence: [:], purpose: purpose)
    }
    public static func compile(catalog: ApplicationSurfaceCatalog, actionID: String, inputs: [String: AutomationActionInput],
                               declaredEffects: AutomationActionEffectDeclaration, approval: RunApproval, capabilities: CapabilityProfile,
                               recipe: AutomationQualifiedSetupRecipe, recipeContext: AutomationRecipeContext,
                               recipeText: String, consumingParameter: String, purpose: AutomationPlanValidationPurpose = .execution) throws -> AutomationCase {
        guard inputs[consumingParameter] == nil, recipeContext.app == catalog.app,
              recipeContext.catalogDigest == (try AutomationRecipeContext.catalogDigest(catalog)),
              recipeContext.target == approval.target, recipeContext.environmentID == approval.environmentID else {
            throw AutomationContractError.missingEvidence("Recipe does not belong to this action environment")
        }
        let setup = try recipe.instantiate(text: recipeText, context: recipeContext, segmentPrefix: "recipe")
        let binding = AutomationInputBinding(producerSegmentID: setup[1].id, outputID: recipe.candidate.outputID,
            destination: .hostParameter, operationID: "invoke", name: consumingParameter)
        return try compile(catalog: catalog, actionID: actionID, inputs: inputs, declaredEffects: declaredEffects,
            approval: approval, capabilities: capabilities, setup: setup, deferredInput: binding,
            recipeEvidence: ["recipe": recipe.candidate.id + ":" + String(recipe.candidate.version),
                             "recipe.qualification": recipe.qualificationReportDigest,
                             "ui.locale": recipeContext.localeIdentifier], purpose: purpose)
    }
    private static func compile(catalog: ApplicationSurfaceCatalog, actionID: String, inputs: [String: AutomationActionInput],
                                declaredEffects: AutomationActionEffectDeclaration, approval: RunApproval, capabilities: CapabilityProfile,
                                setup: [AutomationSegment], deferredInput: AutomationInputBinding?, recipeEvidence: [String: String],
                                purpose: AutomationPlanValidationPurpose) throws -> AutomationCase {
        guard catalog.app == approval.app, let action = catalog.systemActions.first(where: { $0.id == actionID }),
              action.compiled, action.parametersComplete, !approval.effects.isEmpty, approval.maximumActions > 0,
              Set(inputs.keys).isSubset(of: Set(action.parameters.map(\.name))),
              deferredInput == nil || action.parameters.contains(where: { $0.name == deferredInput?.name && $0.family == "text" }) else {
            throw AutomationContractError.missingEvidence("Action declarations, inputs or effects are not approved")
        }
        guard declaredEffects.app == catalog.app, declaredEffects.actionID == actionID, !declaredEffects.effects.isEmpty,
              !declaredEffects.developerConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              declaredEffects.effects.isSubset(of: approval.effects) else { throw AutomationContractError.missingEvidence("The selected action's effects have no scoped developer confirmation") }
        var values: [String: AutomationValue] = [:], evidence: [String: String] = [:]
        for parameter in action.parameters {
            if let input = try inputs[parameter.name] ?? (deferredInput?.name == parameter.name ? nil : AutomationCodecRegistry.declaredDefault(parameter, catalog: catalog)) {
                guard !input.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationContractError.missingEvidence(parameter.name) }
                try AutomationCodecRegistry.validate(input.value, parameter: parameter, catalog: catalog)
                if input.origin == .declaredDefault && input.value != parameter.defaultValue { throw AutomationContractError.conflictingOperation }
                try input.value.validate(); values[parameter.name] = input.value
                evidence["input." + parameter.name] = input.origin.rawValue + ": " + input.evidence
            } else if deferredInput?.name == parameter.name { evidence["input." + parameter.name] = "fresh qualified recipe output" }
            else if parameter.optional { values[parameter.name] = .omission }
            else { throw AutomationContractError.missingEvidence("No trusted input for " + parameter.name) }
        }
        let parameterCodecs = Dictionary(uniqueKeysWithValues: action.parameters.compactMap { parameter -> (String, String)? in
            guard let family = parameter.family, AutomationCodecRegistry.explicitParameterFamilies.contains(family), values[parameter.name] != nil else { return nil }
            return (parameter.name, family)
        })
        var segment = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: action.id,
            inputs: values, requiredCapabilities: ["apple.intent.invoke"], effects: declaredEffects.effects, lifecycle: .persistedStateAcrossSegments)
        // This template tests invocation only. Unsupported result types do not become business observations.
        segment.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: action.id, parameters: values, resultCodec: action.resultFamily ?? "noValue", parameterCodecs: parameterCodecs.isEmpty ? nil : parameterCodecs)])
        segment.requiredCapabilities += segment.hostProgram?.requiredCodecCapabilities ?? []
        if let deferredInput { segment.inputBindings = [deferredInput] }
        var budget = AutomationBudget(); budget.wallClockSeconds = 180
        var plan = AutomationCase(id: "invoke." + action.id, app: catalog.app, target: approval.target, environmentID: approval.environmentID,
                                  execution: segment, setup: setup, budget: budget)
        plan.provenance = evidence.merging(["effects": "developer confirmation: " + declaredEffects.developerConfirmation, "expectation": "invocation only; no business assessment"], uniquingKeysWith: { _, new in new }).merging(recipeEvidence, uniquingKeysWith: { _, new in new })
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        plan.id = "invoke." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: purpose)
        try segment.hostProgram?.validate(route: .systemIntent, phase: .subject)
        return plan
    }
}
