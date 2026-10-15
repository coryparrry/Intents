import Foundation

public struct AutomationStateMutationProposal: Sendable {
    public var mutations: [AutomationMutationCase]
    public var reductions: [AutomationReductionEdge]
    public var gaps: [String]
}

/// Adds valid, query-checked records. It never changes the subject, observer or oracle.
/// A proposal grants no repeat authority: every setup must qualify through two live attempts.
public enum AutomationStateMutationPlanner {
    public static func propose(baseline: AutomationFrozenCase, context: AutomationFreshEntityContext? = nil) throws -> AutomationStateMutationProposal {
        try baseline.validate()
        _ = try AutomationFreshEntityPlanner.bindings(plan: baseline.plan)
        let plan = baseline.plan
        guard plan.setup.count == 2, let create = plan.setup.first, let lookup = plan.setup.last,
              create.kind == .ui, lookup.kind == .systemQuery, let query = lookup.hostProgram?.operations.first,
              lookup.hostProgram?.operations.count == 1, let check = plan.setupChecks?.first,
              plan.setupChecks?.count == 1, let predicate = check.entityProperty,
              let name = predicate.selection.attemptProperties?.first, predicate.selection.attemptProperties?.count == 1,
              create.attemptTextBindings == ["approvedText": name.value], let goal = create.uiProgram?.operations.first?.goal else {
            throw AutomationContractError.missingEvidence("State search needs one fresh, independently checked target record")
        }
        let extraPrefix = String(name.value.prefix(112)) + "-Extra"
        var kinds: [[AutomationMutationKind]] = [[.unrelatedData]], gaps: [String] = []
        if let context {
            try context.validate(entity: .init(typeID: "fixture", title: "Fixture", queryIdentifier: "fixture", properties: query.properties ?? [:], propertyTitles: [:]), nameProperty: name.key)
            guard predicate.selection.matchingProperties[context.property] == .text(context.selectedValue) else {
                throw AutomationContractError.invalidPlan("Additional records must use the reviewed target's existing owner or list context")
            }
            kinds.insert([.duplicateLabel], at: 0)
            if goal.saveControl == nil { kinds.append([.duplicateLabel, .unrelatedData]) }
            else { gaps.append("Combined extra-record search is unavailable with a one-save-per-step rule; duplicate names and unrelated records are checked separately.") }
        } else { gaps.append("Duplicate-name search needs approved, distinct existing owner or list values to keep the target identifiable.") }
        let mutations = try kinds.map { selectedKinds -> AutomationMutationCase in
            var changed = plan, targetCreate = create, additional = create, read = lookup
            if var targetGoal = targetCreate.uiProgram?.operations.first?.goal {
                targetGoal.maximumCalls = 6; targetGoal.maximumActions = 15
                targetCreate.uiProgram?.operations[0].goal = targetGoal
            }
            additional.id = "fixture.additional"
            additional.attemptTextBindings = [:]
            var names: [String: String] = [:], selections: [AutomationEntitySelection] = [], instructions: [String] = []
            if selectedKinds.contains(.duplicateLabel), let context {
                names["duplicateName"] = name.value
                instructions.append("Create and save exactly one record named duplicateName in existing \(context.property) \(context.protectedValue).")
                var selection = predicate.selection; selection.matchingProperties[context.property] = .text(context.protectedValue)
                selections.append(selection)
            }
            if selectedKinds.contains(.unrelatedData) {
                names["extraName"] = extraPrefix
                instructions.append("Create and save exactly one separate record named extraName" + (context.map { " in existing \($0.property) \($0.protectedValue)" } ?? "") + ".")
                var selection = predicate.selection; selection.attemptProperties = [name.key: extraPrefix]
                if let context { selection.matchingProperties[context.property] = .text(context.protectedValue) }
                selections.append(selection)
                read.hostProgram?.operations[0].attemptQueryPrefix = nil
                read.hostProgram?.operations[0].queryText = name.value
            }
            additional.attemptTextBindings = names
            var additionalGoal = AutomationNavigationGoal(id: "create", instruction: "Use the app's record creation controls. Additional records only: " + instructions.joined(separator: " ") + " Use each named input exactly as supplied. Preserve the selected record and all settings.", endpoint: goal.endpoint,
                maximumCalls: 6, maximumActions: 15, minimumBindingUses: names.mapValues { _ in 1 }, allowedFillBindings: names.keys.sorted(),
                selectionBindings: context == nil ? nil : ["additionalContext"])
            additionalGoal.saveControl = goal.saveControl
            additional.operation = "Create approved additional fixture records"
            additional.uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal, goal: additionalGoal)], bindings: context.map { ["additionalContext": $0.protectedValue] } ?? [:])
            changed.setup = [targetCreate, additional, read]
            for (index, selection) in selections.enumerated() {
                var addedCheck = check
                addedCheck.checkID = "fixture.additional.\(index)"
                addedCheck.justification = "Query verifies this additional record and its initial state before the subject runs"
                addedCheck.entityProperty?.selection = selection
                changed.setupChecks?.append(addedCheck)
            }
            changed.provenance["fixture.mutation"] = selectedKinds.map(\.rawValue).joined(separator: ",")
            changed.id = "mutation." + String(try AutomationFrozenCase.planDigest(changed).prefix(32))
            let frozen = try AutomationFrozenCase(plan: changed)
            guard frozen.oracleDigest == baseline.oracleDigest, changed.execution == plan.execution, changed.observations == plan.observations else { throw AutomationContractError.conflictingOperation }
            _ = try bindings(plan: changed)
            return .init(frozen: frozen, recipeIDs: selectedKinds.map { "fresh." + $0.rawValue }, kinds: selectedKinds,
                requiredCapabilities: ["apple.entity.query"], semanticJustification: "Additional valid records preserve the selected entity's identity, request and independently approved expected state")
        }
        var reductions = mutations.map { AutomationReductionEdge(parentDigest: $0.frozen.digest, childDigest: baseline.digest, semanticJustification: "Remove added records; retain the exact subject and business check") }
        for pair in mutations where pair.kinds.count == 2 {
            for single in mutations where single.kinds.count == 1 {
                reductions.append(.init(parentDigest: pair.frozen.digest, childDigest: single.frozen.digest, semanticJustification: "Remove one independent added-record condition"))
            }
        }
        return .init(mutations: mutations, reductions: reductions, gaps: gaps)
    }

    public static func bindings(plan: AutomationCase) throws -> [AutomationFreshFixtureBinding] {
        let creates = plan.setup.filter { $0.kind == .ui }
        guard creates.count == 2, plan.setup.count == 3, let lookup = plan.setup.last, lookup.kind == .systemQuery,
              let query = lookup.hostProgram?.operations.first, lookup.hostProgram?.operations.count == 1,
              let checks = plan.setupChecks, (2...3).contains(checks.count),
              creates.allSatisfy({ $0.attemptTextBindings?.isEmpty == false }),
              checks.allSatisfy({ $0.observationID == lookup.id && $0.entityProperty?.operationID == query.id }),
              plan.requirements.allSatisfy({ requirement in checks.contains { $0.entityProperty == requirement.entityProperty } }) else {
            throw AutomationContractError.missingEvidence("Mutation setup requires independent checks for every fresh record")
        }
        let prefixes = Set(creates.flatMap { Array(($0.attemptTextBindings ?? [:]).values) })
        let checkedPrefixes = Set(checks.flatMap { Array(($0.entityProperty?.selection.attemptProperties ?? [:]).values) })
        guard prefixes == checkedPrefixes else { throw AutomationContractError.conflictingOperation }
        return try checks.map { check in
            guard let selection = check.entityProperty?.selection else { throw AutomationContractError.invalidIdentity }
            try selection.validate(query: query)
            return .init(producerSegmentID: lookup.id, outputID: query.id, selection: selection)
        }
    }
}
