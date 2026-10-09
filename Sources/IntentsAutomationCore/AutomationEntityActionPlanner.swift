#if os(macOS)
import Foundation

/// Bind a developer-selected live query result through a new lookup in each attempt.
/// Optional business expectations are explicit choices; invocation alone remains unassessed.
public enum AutomationEntityActionPlanner {
    public static func compile(catalog: ApplicationSurfaceCatalog, actionID: String,
                               textInputs: [String: AutomationActionInput], selections: [String: AutomationQueryEntityChoice],
                               protectedSelections: [String: [AutomationQueryEntityChoice]] = [:], expectations: [String: [String: AutomationValue]], declaredEffects: AutomationActionEffectDeclaration,
                               approval: RunApproval, capabilities: CapabilityProfile,
                               purpose: AutomationPlanValidationPurpose = .execution) throws -> AutomationCase {
        guard catalog.app == approval.app, let action = catalog.systemActions.first(where: { $0.id == actionID }),
              action.compiled, action.parametersComplete,
              declaredEffects.app == catalog.app, declaredEffects.actionID == actionID,
              !declaredEffects.effects.isEmpty, declaredEffects.effects.isSubset(of: approval.effects),
              !declaredEffects.developerConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(textInputs.keys).isDisjoint(with: Set(selections.keys)),
              Set(selections.keys).isSubset(of: Set(action.parameters.filter { $0.family == "entity" }.map(\.name))),
              Set(textInputs.keys).union(selections.keys).isSubset(of: Set(action.parameters.map(\.name))),
              Set(expectations.keys).isSubset(of: Set(selections.keys)),
              Set(protectedSelections.keys).isSubset(of: Set(selections.keys)), selections.count <= 3 else {
            throw AutomationContractError.missingEvidence("The selected inputs, declarations and effects are incomplete")
        }
        let catalogDigest = try AutomationRecipeContext.catalogDigest(catalog)
        var values: [String: AutomationValue] = [:], bindings: [AutomationInputBinding] = []
        var setup: [AutomationSegment] = [], observers: [AutomationSegment] = [], checks: [AutomationRequirement] = [], setupChecks: [AutomationRequirement] = []
        var provenance = ["catalog": catalogDigest, "effects": declaredEffects.developerConfirmation,
            "expectation": expectations.values.allSatisfy(\.isEmpty) && protectedSelections.values.allSatisfy(\.isEmpty) ? "invocation only; no business assessment" : "developer-approved entity property checks"]
        for parameter in action.parameters {
            if let text = try textInputs[parameter.name] ?? AutomationCodecRegistry.declaredDefault(parameter, catalog: catalog) {
                guard !text.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationContractError.missingEvidence(parameter.name) }
                try AutomationCodecRegistry.validate(text.value, parameter: parameter, catalog: catalog)
                if text.origin == .declaredDefault && text.value != parameter.defaultValue { throw AutomationContractError.conflictingOperation }
                try text.value.validate(); values[parameter.name] = text.value
                provenance["input." + parameter.name] = text.origin.rawValue + ": " + text.evidence
            } else if let choice = selections[parameter.name] {
                guard parameter.family == "entity", parameter.typeID == choice.typeID,
                      let entity = catalog.entities?.first(where: { $0.typeID == choice.typeID }),
                      choice.app == catalog.app, choice.target == approval.target, choice.environmentID == approval.environmentID,
                      choice.catalogDigest == catalogDigest, AutomationUIFailureSearchRecord.identifier(choice.sourceAttemptID),
                      Set(choice.properties.keys) == Set(entity.properties.keys),
                      choice.properties.allSatisfy({ AutomationEntitySelection.matchesCodec($0.value, entity.properties[$0.key]) }) else {
                    throw AutomationContractError.conflictingOperation
                }
                try AutomationValue.entity(typeID: choice.typeID, value: choice.id).validate()
                let matching = choice.properties.filter { entity.properties[$0.key] == "text" }
                let selection = AutomationEntitySelection(typeID: choice.typeID, matchingProperties: matching)
                let query = AutomationHostProgram.Operation(id: "records", kind: .query, typeID: choice.typeID,
                    queryIDs: [choice.id], properties: entity.properties)
                try selection.validate(query: query)
                var lookup = AutomationSegment(id: "lookup." + parameter.name, kind: .systemQuery, phase: .setup, operation: "Resolve selected " + entity.title,
                    requiredCapabilities: ["apple.entity.query"], effects: [.observe], lifecycle: .persistedStateAcrossSegments)
                var queries = [query]
                let protected = protectedSelections[parameter.name] ?? []
                guard protected.count <= 2, Set(protected.map(\.id)).count == protected.count,
                      !protected.contains(where: { $0.id == choice.id }) else { throw AutomationContractError.invalidPlan("Choose up to two distinct other records to preserve") }
                for (index, other) in protected.enumerated() {
                    guard other.typeID == choice.typeID, other.app == choice.app, other.target == choice.target,
                          other.environmentID == choice.environmentID, other.catalogDigest == catalogDigest,
                          other.sourceAttemptID == choice.sourceAttemptID, Set(other.properties.keys) == Set(entity.properties.keys),
                          other.properties.allSatisfy({ AutomationEntitySelection.matchesCodec($0.value, entity.properties[$0.key]) }) else { throw AutomationContractError.conflictingOperation }
                    try AutomationValue.entity(typeID: other.typeID, value: other.id).validate()
                    queries.append(.init(id: "protected." + String(index), kind: .query, typeID: other.typeID,
                        queryIDs: [other.id], properties: entity.properties))
                }
                lookup.hostProgram = .init(operations: queries); setup.append(lookup)
                bindings.append(.init(producerSegmentID: lookup.id, outputID: query.id, destination: .hostParameter,
                    operationID: "invoke", name: parameter.name, uniqueEntity: selection))
                var observer = lookup; observer.id = "state." + parameter.name; observer.phase = .observe
                observers.append(observer)
                for (name, expected) in (expectations[parameter.name] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard entity.properties[name] == "bool", case .bool = expected else { throw AutomationContractError.invalidPlan("Select an independently readable declared Boolean property") }
                    checks.append(.init(observationID: observer.id, expected: expected, proof: .appState,
                        justification: "Developer-approved expected state of the actual selected record",
                        checkID: "business." + parameter.name + "." + name,
                        entityProperty: .init(operationID: query.id, selection: selection, property: name)))
                }
                for (record, query, label) in [(choice, query, "selected")] + protected.enumerated().map({ ($0.element, queries[$0.offset + 1], "protected." + String($0.offset)) }) {
                    let recordSelection = AutomationEntitySelection(typeID: record.typeID,
                        matchingProperties: record.properties.filter { entity.properties[$0.key] == "text" })
                    for (name, actual) in record.properties.sorted(by: { $0.key < $1.key }) where entity.properties[name] == "bool" {
                        setupChecks.append(.init(observationID: lookup.id, expected: actual, proof: .appState,
                            justification: "The selected record must still have its observed pre-action state",
                            checkID: "fixture." + parameter.name + "." + label + "." + name,
                            entityProperty: .init(operationID: query.id, selection: recordSelection, property: name)))
                        if label != "selected" {
                            checks.append(.init(observationID: observer.id, expected: actual, proof: .appState,
                                justification: "Developer explicitly chose to keep this other record unchanged",
                                checkID: "business." + parameter.name + "." + label + "." + name,
                                entityProperty: .init(operationID: query.id, selection: recordSelection, property: name)))
                        }
                    }
                }
                provenance["input." + parameter.name] = "live query selection from " + choice.sourceAttemptID + "; fresh lookup before subject"
            } else if parameter.optional { values[parameter.name] = .omission }
            else { throw AutomationContractError.missingEvidence("Choose a real record for " + parameter.name) }
        }
        let parameterCodecs = Dictionary(uniqueKeysWithValues: action.parameters.compactMap { parameter -> (String, String)? in
            guard let family = parameter.family, AutomationCodecRegistry.explicitParameterFamilies.contains(family), values[parameter.name] != nil else { return nil }
            return (parameter.name, family)
        })
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: action.id,
            inputs: values, requiredCapabilities: ["apple.intent.invoke"], effects: declaredEffects.effects, lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: action.id, parameters: values, resultCodec: action.resultFamily ?? "noValue", parameterCodecs: parameterCodecs.isEmpty ? nil : parameterCodecs)])
        subject.requiredCapabilities += subject.hostProgram?.requiredCodecCapabilities ?? []
        subject.inputBindings = bindings
        var budget = AutomationBudget(); budget.wallClockSeconds = 300
        var plan = AutomationCase(id: "entity." + action.id, app: catalog.app, target: approval.target, environmentID: approval.environmentID,
            execution: subject, setup: setup, observations: observers, requirements: checks, budget: budget)
        plan.setupChecks = setupChecks
        plan.provenance = provenance
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        plan.id = "entity." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        let digest = try AutomationFrozenCase.planDigest(plan)
        guard approval.approvedCaseDigest == nil || approval.approvedCaseDigest == digest else { throw AutomationContractError.conflictingOperation }
        var validationApproval = approval
        validationApproval.approvedCaseDigest = digest
        try PlanValidator.validate(plan, approval: validationApproval, capabilities: capabilities, purpose: purpose)
        return plan
    }
}
#endif
