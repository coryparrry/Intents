import Foundation

/// Native-authored disposable fixture workflow. Every repeat creates a uniquely
/// named record in the UI and binds only an independently queried entity ID.
/// A developer-approved existing owner/list property distinguishes two records
/// with the same generated name. The protected record must keep its initial state.
public struct AutomationFreshEntityContext: Codable, Equatable, Sendable {
    public let property: String
    public let selectedValue: String
    public let protectedValue: String
    public init(property: String, selectedValue: String, protectedValue: String) {
        self.property = property; self.selectedValue = selectedValue; self.protectedValue = protectedValue
    }
    public func setupInstruction(_ instruction: String) -> String {
        instruction + " Create two records with the same approvedText name. Use selectedContext (\(selectedValue)) for the selected record's \(property), and protectedContext (\(protectedValue)) for the other record's \(property). Save both records."
    }
    public func validate(entity: ApplicationSurfaceCatalog.Entity, nameProperty: String) throws {
        guard property != nameProperty, entity.properties[property] == "text", selectedValue != protectedValue,
              [selectedValue, protectedValue].allSatisfy({ value in
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 128 &&
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else { throw AutomationContractError.invalidPlan("Choose distinct existing owner or list values for the selected and protected records") }
    }
}

public enum AutomationFreshEntityPlanner {
    public enum Purpose: Equatable, Sendable { case execution, nativeMacDraft, simulatorDraft }
    public static func compile(catalog: ApplicationSurfaceCatalog, actionID: String,
                               instruction: String, endpoint: String, namePrefix: String,
                               nameProperty: String, stateProperty: String, initialState: Bool, expectedState: Bool,
                               approval: RunApproval, capabilities: CapabilityProfile, localeIdentifier: String,
                               context: AutomationFreshEntityContext? = nil, purpose: Purpose = .execution,
                               saveControl: AutomationUIProgram.Locator? = nil) throws -> AutomationCase {
        switch purpose {
        case .execution, .simulatorDraft:
            guard approval.target.kind == .simulator else { throw AutomationContractError.invalidIdentity }
        case .nativeMacDraft:
            guard catalog.app.platform == "macos", catalog.app.productDigestVersion == 2,
                  catalog.app.productDigest != nil, catalog.app.canonicalBundlePath != nil,
                  approval.target.kind == .nativeMac, approval.target.id == "host-macos-local",
                  let session = approval.target.loginSession, !session.isEmpty, session.utf8.count <= 256,
                  !session.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  approval.environmentID == "selected-mac-session:" + session else {
                throw AutomationContractError.invalidIdentity
            }
        }
        guard catalog.app == approval.app, approval.disposable,
              approval.effects == [.observe, .navigate, .fixtureWrite], approval.maximumActions >= 30,
              let action = catalog.systemActions.first(where: { $0.id == actionID }), action.compiled, action.parametersComplete,
              action.parameters.count == 1, let parameter = action.parameters.first, parameter.family == "entity",
              let entity = catalog.entities?.first(where: { $0.typeID == parameter.typeID }),
              entity.properties[nameProperty] == "text", entity.properties[stateProperty] == "bool",
              !localeIdentifier.isEmpty, localeIdentifier.utf16.count <= 128 else {
            throw AutomationContractError.missingEvidence("Choose a single-record action, readable name and state, and a disposable test environment")
        }
        try AutomationAttemptText.validatePrefix(namePrefix)
        try context?.validate(entity: entity, nameProperty: nameProperty)
        // A form may retain its name after saving. Require approved input activity,
        // while the independent queries below prove both records and their owners.
        var goal = AutomationNavigationGoal(id: "create", instruction: context?.setupInstruction(instruction) ?? instruction,
            endpoint: .init(.label, endpoint), maximumCalls: 12, maximumActions: 30, minimumBindingUses: ["approvedText": 1], allowedFillBindings: ["approvedText"])
        goal.saveControl = saveControl
        try goal.validate()
        var create = AutomationSegment(id: "fixture.create", kind: .ui, phase: .setup, operation: instruction,
            effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        create.uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal, goal: goal)])
        create.attemptTextBindings = ["approvedText": namePrefix]
        if let context {
            create.uiProgram?.bindings = ["selectedContext": context.selectedValue, "protectedContext": context.protectedValue]
            // Both declared values are also in the goal so current visible list
            // controls can be chosen; query evidence decides whether setup worked.
        }
        var creationSteps = [create]
        if let context {
            // One bounded goal per record keeps completion of the first UI
            // task from being mistaken for completion of the whole fixture.
            // Neither goal is record evidence: the same query checks both.
            creationSteps = [("fixture.create", "selectedContext", context.selectedValue),
                             ("fixture.create.protected", "protectedContext", context.protectedValue)].enumerated().map { index, item in
                let (segmentID, binding, value) = item
                let stepInstruction = "Approved overall setup: " + instruction +
                    " Current step \(index + 1) of 2: create and save exactly one new record with the approvedText name and \(context.property) \(binding) (\(value)). Select that existing context using its controls; never type the context into the name field. Finish this step after saving this one record. The other record is handled by a separate step. Preserve existing records and settings."
                var stepGoal = AutomationNavigationGoal(id: "create", instruction: stepInstruction,
                    endpoint: goal.endpoint, maximumCalls: 6, maximumActions: 15,
                    minimumBindingUses: ["approvedText": 1], allowedFillBindings: ["approvedText"], selectionBindings: [binding])
                stepGoal.saveControl = saveControl
                var step = create; step.id = segmentID; step.operation = stepInstruction
                step.uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal, goal: stepGoal)], bindings: [binding: value])
                return step
            }
        }
        let query = AutomationHostProgram.Operation(id: "record", kind: .query, typeID: entity.typeID,
            attemptQueryPrefix: namePrefix, properties: entity.properties)
        var lookup = AutomationSegment(id: "fixture.lookup", kind: .systemQuery, phase: .setup, operation: entity.queryIdentifier,
            requiredCapabilities: ["apple.entity.query"], lifecycle: .persistedStateAcrossSegments)
        lookup.hostProgram = .init(operations: [query])
        let selection = AutomationEntitySelection(typeID: entity.typeID, matchingProperties: context.map { [$0.property: .text($0.selectedValue)] } ?? [:], attemptProperties: [nameProperty: namePrefix])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: action.id,
            requiredCapabilities: ["apple.intent.invoke"], effects: [.observe, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: action.id, resultCodec: action.resultFamily ?? "noValue")])
        subject.inputBindings = [.init(producerSegmentID: lookup.id, outputID: query.id, destination: .hostParameter,
            operationID: "invoke", name: parameter.name, uniqueEntity: selection)]
        var observer = lookup; observer.id = "state"; observer.phase = .observe
        observer.hostProgram = .init(operations: [.init(id: query.id, kind: .query, typeID: entity.typeID, properties: entity.properties)])
        observer.inputBindings = [.init(producerSegmentID: lookup.id, outputID: query.id, destination: .hostQueryIDs,
            operationID: query.id, name: "queryIDs", uniqueEntity: selection)]
        let predicate = AutomationEntityPropertyPredicate(operationID: query.id, selection: selection, property: stateProperty)
        var budget = AutomationBudget(); budget.subjectOperations = 1; budget.attempts = 100
        budget.uiActions = 30; budget.controllerCalls = 12; budget.wallClockSeconds = 600
        var plan = AutomationCase(id: "fresh-record", app: catalog.app, target: approval.target, environmentID: approval.environmentID,
            execution: subject, setup: creationSteps + [lookup], observations: [observer],
            requirements: [.init(observationID: observer.id, expected: .bool(expectedState), proof: .appState,
                justification: "Developer-approved state of the actual UI-created record after the system action",
                checkID: "business.state", entityProperty: predicate)], budget: budget,
            setupChecks: [.init(observationID: lookup.id, expected: .bool(initialState), proof: .appState,
                justification: "Developer-approved state of the new fixture before the system action",
                checkID: "fixture.state", entityProperty: predicate)])
        if let context {
            let protectedSelection = AutomationEntitySelection(typeID: entity.typeID,
                matchingProperties: [context.property: .text(context.protectedValue)], attemptProperties: [nameProperty: namePrefix])
            let protectedPredicate = AutomationEntityPropertyPredicate(operationID: query.id, selection: protectedSelection, property: stateProperty)
            var protectedObserver = observer; protectedObserver.id = "protected.state"
            protectedObserver.inputBindings = [.init(producerSegmentID: lookup.id, outputID: query.id, destination: .hostQueryIDs,
                operationID: query.id, name: "queryIDs", uniqueEntity: protectedSelection)]
            plan.observations.append(protectedObserver)
            plan.setupChecks?.append(.init(observationID: lookup.id, expected: .bool(initialState), proof: .appState,
                justification: "Developer-approved initial state of the other same-name record", checkID: "fixture.protected.state", entityProperty: protectedPredicate))
            plan.requirements.append(.init(observationID: protectedObserver.id, expected: .bool(initialState), proof: .appState,
                justification: "Developer-approved other same-name record remains unchanged", checkID: "business.protected.state", entityProperty: protectedPredicate))
        }
        plan.provenance = ["catalog": try AutomationRecipeContext.catalogDigest(catalog), "ui.locale": localeIdentifier,
            "fixture": "UI-created unique name per attempt; actual entity identity from independent query",
            "expectation": "developer-approved before and after states; positive query evidence only"]
        if purpose == .nativeMacDraft {
            plan.provenance["ui.backend"] = "nativeMac"
            plan.provenance["ui.executionAvailability"] = "unqualified"
        }
        if purpose == .simulatorDraft { plan.provenance["ui.executionAvailability"] = "unqualified" }
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        plan.id = "fresh." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        var validationApproval = approval; validationApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: validationApproval, capabilities: capabilities,
            purpose: purpose == .execution ? .execution : .review)
        return plan
    }

    public static func bindings(plan: AutomationCase) throws -> [AutomationFreshFixtureBinding] {
        let creationSteps = plan.setup.dropLast()
        guard (2...3).contains(plan.setup.count),
              creationSteps.allSatisfy({ $0.kind == .ui && $0.attemptTextBindings?.count == 1 }),
              creationSteps.allSatisfy({ $0.attemptTextBindings == plan.setup[0].attemptTextBindings }),
              let binding = plan.execution.inputBindings?.first, plan.execution.inputBindings?.count == 1,
              plan.setup.last?.id == binding.producerSegmentID, plan.setup.last?.kind == .systemQuery,
              let selection = binding.uniqueEntity, selection.attemptProperties?.count == 1 else {
            throw AutomationContractError.missingEvidence("No native fresh-record fixture in this case")
        }
        guard let checks = plan.setupChecks, (1...2).contains(checks.count),
              checks.first?.entityProperty?.selection == selection, plan.requirements.count == checks.count,
              plan.requirements.allSatisfy({ requirement in checks.contains(where: {
                  $0.entityProperty?.selection == requirement.entityProperty?.selection && $0.entityProperty?.property == requirement.entityProperty?.property
              }) }),
              checks.allSatisfy({ $0.observationID == binding.producerSegmentID && $0.entityProperty?.operationID == binding.outputID }) else {
            throw AutomationContractError.missingEvidence("Fresh fixture checks must cover every selected and protected record")
        }
        return try checks.map { check in
            guard let predicate = check.entityProperty else { throw AutomationContractError.invalidIdentity }
            return .init(producerSegmentID: check.observationID, outputID: predicate.operationID, selection: predicate.selection)
        }
    }
}
