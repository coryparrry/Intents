#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Runtime grammar restricts each action to its current eligible aliases. This
/// narrows model output; the native action grant remains the authority.
struct AutomationGuidedNavigationDecision {
    let projection: AutomationControllerContextSelection.Projection
    let bindingNames: [String]
    let tapAliases: [String]
    let fillBindingOptions: [String: [String]]
    let kinds: Set<String>
    let schema: GenerationSchema

    init(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) throws {
        try goal.validate(); try request.validate()
        guard request.goalId == goal.id, bindings.count <= 30,
              bindings.keys.allSatisfy(AutomationHostProgram.identifier) else { throw AutomationContractError.invalidIdentity }
        projection = try AutomationControllerContextSelection.project(request)
        guard Set(goal.allowedFillBindings ?? []).isSubset(of: Set(bindings.keys)) else { throw AutomationContractError.invalidIdentity }
        guard Set(goal.selectionBindings ?? []).isSubset(of: Set(bindings.keys)) else { throw AutomationContractError.invalidIdentity }
        bindingNames = bindings.keys.sorted().filter { goal.allowedFillBindings == nil || goal.allowedFillBindings!.contains($0) }
        var fillOptions: [String: [String]] = [:]
        for (index, node) in projection.nodes.enumerated() {
            let alias = "n" + String(index)
            guard projection.fillAliases.contains(alias) else { continue }
            let permitted = bindingNames.filter { binding in
                // Previously approved input plus an exact current value match
                // gives the planner no useful reason to repeat the same fill.
                // This is proposal shaping, never setup/record completion proof.
                !(goal.minimumBindingUses?[binding] != nil && (request.approvedBindingUses?[binding] ?? 0) > 0 && node.value == bindings[binding])
            }
            if !permitted.isEmpty { fillOptions[alias] = permitted }
        }
        fillBindingOptions = fillOptions
        let tapProjection = projection, tapBindingNames = bindingNames
        let selectedOptions = (goal.selectionBindings ?? []).compactMap { bindings[$0] }.filter { !$0.isEmpty }
        tapAliases = tapProjection.tapAliases.filter { alias in
            guard let index = Int(alias.dropFirst()) else { return true }
            let node = tapProjection.nodes[index]
            if request.approvedSaveTap == true, goal.matchesSaveControl(node) { return false }
            // Exact, explicitly declared selection semantics only. Unknown
            // selection and ordinary selected controls retain their actions.
            // Fields at the wire clipping limit may be prefixes of longer
            // labels. They cannot establish an exact option-value match.
            let exactFields = [(node.name, 512), (node.text, 512), (node.value, 1024)].compactMap { field, limit in
                field.flatMap { $0.utf16.count < limit ? $0 : nil }
            }
            if node.selected == true, selectedOptions.contains(where: exactFields.contains) { return false }
            guard node.editable == true || (node.editable == nil && node.fillSupported == true) else { return true }
            return !tapBindingNames.contains { goal.minimumBindingUses?[$0] != nil && (request.approvedBindingUses?[$0] ?? 0) > 0 && node.value == bindings[$0] }
        }
        func strings(_ choices: [String]) -> DynamicGenerationSchema {
            .init(type: String.self, guides: [.anyOf(choices)])
        }
        func branch(_ name: String, _ kind: String, _ fields: [DynamicGenerationSchema.Property] = []) -> DynamicGenerationSchema {
            .init(name: name, description: kind == "finish" ? "The entire requested UI workflow is complete. Approved input activity alone does not mean records were saved. Do not choose this while a requested save or next step remains." : nil, properties: [.init(name: "kind", schema: strings([kind]))] + fields)
        }
        var choices: [DynamicGenerationSchema] = [branch("ControllerCannotProceed", "cannotProceed", [
            .init(name: "reason", schema: strings(["unsupportedObservation", "navigationStalled", "budgetExhausted", "noSafeAction"]))])]
        var available: Set<String> = ["cannotProceed"]
        if request.remainingActions > 0 {
            if !tapAliases.isEmpty {
                choices.append(branch("ControllerTap", "tap", [.init(name: "node", schema: strings(tapAliases))])); available.insert("tap")
            }
            for alias in projection.fillAliases {
                guard let names = fillBindingOptions[alias] else { continue }
                choices.append(branch("ControllerFill_" + alias, "fill", [.init(name: "node", schema: strings([alias])),
                    .init(name: "textBinding", schema: strings(names))])); available.insert("fill")
            }
            if request.verbs.contains("scroll") {
                choices.append(branch("ControllerScroll", "scroll", [.init(name: "direction", schema: strings(["up", "down", "left", "right"]))])); available.insert("scroll")
            }
        }
        if (goal.minimumBindingUses ?? [:]).allSatisfy({ (request.approvedBindingUses?[$0.key] ?? 0) >= $0.value }),
           goal.saveControl == nil || request.approvedSaveTap == true {
            choices.append(branch("ControllerFinishRequestedWorkflow", "finish")); available.insert("finish")
        }
        kinds = available
        schema = try .init(root: .init(name: "ControllerDecision", anyOf: choices), dependencies: [])
    }

    func decision(_ content: GeneratedContent) throws -> AutomationControllerDecision {
        guard content.isComplete, case .structure(let fields, _) = content.kind,
              let rawKind = fields["kind"], case .string(let kind) = rawKind.kind, kinds.contains(kind) else {
            throw AutomationContractError.invalidIdentity
        }
        func exact(_ keys: Set<String>) throws {
            guard Set(fields.keys) == keys else { throw AutomationContractError.invalidIdentity }
        }
        func string(_ key: String) throws -> String {
            guard let field = fields[key], case .string(let value) = field.kind else { throw AutomationContractError.invalidIdentity }
            return value
        }
        func node(_ eligible: [String]) throws -> String {
            let alias = try string("node")
            guard eligible.contains(alias), let id = projection.nodeIDs[alias] else { throw AutomationContractError.invalidIdentity }
            return id
        }
        switch kind {
        case "tap": try exact(["kind", "node"]); return try .init(kind: kind, node: node(tapAliases))
        case "fill":
            try exact(["kind", "node", "textBinding"])
            let binding = try string("textBinding")
            let alias = try string("node")
            guard fillBindingOptions[alias]?.contains(binding) == true else { throw AutomationContractError.invalidIdentity }
            return try .init(kind: kind, node: node(projection.fillAliases), textBinding: binding)
        case "scroll":
            try exact(["kind", "direction"]); let direction = try string("direction")
            guard ["up", "down", "left", "right"].contains(direction) else { throw AutomationContractError.invalidIdentity }
            return .init(kind: kind, direction: direction)
        case "finish": try exact(["kind"]); return .init(kind: kind)
        case "cannotProceed":
            try exact(["kind", "reason"]); let reason = try string("reason")
            guard ["unsupportedObservation", "navigationStalled", "budgetExhausted", "noSafeAction"].contains(reason) else { throw AutomationContractError.invalidIdentity }
            return .init(kind: kind, reason: reason)
        default: throw AutomationContractError.invalidIdentity
        }
    }
}
#endif
