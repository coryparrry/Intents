import Foundation

/// A developer declares which frozen input is the actual AI request. This declaration
/// does not establish semantic equivalence: the exact resulting case still needs approval.
public enum AutomationSubjectPhraseSlot: Codable, Equatable, Sendable {
    case uiRequestBinding(String)
    case siriRecognizedText
}

public enum AutomationSubjectPhraseVariation {
    public static func propose(baseline: AutomationFrozenCase, slot: AutomationSubjectPhraseSlot,
                               request: String, semanticJustification: String) throws -> AutomationMutationCase {
        try baseline.validate()
        let original = try text(in: baseline.plan, slot: slot)
        guard request != original, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.contains("\0"), request.utf16.count <= 2048 else {
            throw AutomationContractError.invalidPlan("Enter a distinct approved subject request of at most 2,048 characters")
        }
        var plan = baseline.plan
        setText(request, in: &plan, slot: slot)
        plan.revision = 1
        plan.id = "subject-phrase." + String(try AutomationFrozenCase.canonicalDigest([baseline.digest, request]).prefix(32))
        let proposal = AutomationMutationCase(frozen: try .init(plan: plan), recipeIDs: [], kinds: [.alternatePhrasing],
            requiredCapabilities: [], semanticJustification: semanticJustification, subjectPhraseSlot: slot)
        try validate(proposal, baseline: baseline)
        return proposal
    }

    static func validate(_ mutation: AutomationMutationCase, baseline: AutomationFrozenCase) throws {
        guard let slot = mutation.subjectPhraseSlot, mutation.goalPhraseVariation != true,
              mutation.recipeIDs.isEmpty, mutation.kinds == [.alternatePhrasing], mutation.requiredCapabilities.isEmpty,
              !mutation.semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mutation.semanticJustification.utf16.count <= 4096 else {
            throw AutomationContractError.invalidPlan("Subject phrase requires an explicit request slot and semantic justification")
        }
        try baseline.validate(); try mutation.frozen.validate()
        try baseline.plan.uiRequestFixture?.validate(plan: baseline.plan)
        try mutation.frozen.plan.uiRequestFixture?.validate(plan: mutation.frozen.plan)
        let original = try text(in: baseline.plan, slot: slot), candidate = try text(in: mutation.frozen.plan, slot: slot)
        guard candidate != original, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.utf16.count <= 2048, !candidate.contains("\0") else { throw AutomationContractError.invalidPlan("Invalid subject phrase") }
        var normalized = mutation.frozen.plan
        normalized.id = baseline.plan.id; normalized.revision = baseline.plan.revision
        setText(original, in: &normalized, slot: slot)
        guard normalized == baseline.plan else {
            throw AutomationContractError.invalidPlan("Subject wording changes the approved route, bindings, observer or workflow contract")
        }
    }

    private static func text(in plan: AutomationCase, slot: AutomationSubjectPhraseSlot) throws -> String {
        guard !plan.requirements.isEmpty else { throw AutomationContractError.invalidPlan("Subject phrasing requires an independent business check") }
        switch slot {
        case .uiRequestBinding(let name):
            guard plan.execution.kind == .ui, plan.execution.hostProgram == nil, plan.execution.siriProgram == nil,
                  let program = plan.execution.uiProgram, program.operations.count == 1,
                  program.operations[0].kind == .navigateGoal, let goal = program.operations[0].goal,
                  goal.instruction == plan.execution.operation, (goal.allowedFillBindings ?? []).contains(name),
                  !(plan.execution.inputBindings ?? []).contains(where: { $0.destination == .uiBinding && $0.name == name }),
                  plan.execution.attemptTextBindings?[name] == nil,
                  let value = program.bindings[name], !value.isEmpty else {
                throw AutomationContractError.invalidPlan("Subject phrasing requires an existing frozen AI request binding, never a fresh entity binding")
            }
            try program.validate(phase: .subject)
            return value
        case .siriRecognizedText:
            guard let program = plan.execution.siriProgram else { throw AutomationContractError.invalidPlan("Siri request is unavailable") }
            try program.validate(segment: plan.execution, target: plan.target)
            return program.request
        }
    }

    private static func setText(_ text: String, in plan: inout AutomationCase, slot: AutomationSubjectPhraseSlot) {
        switch slot {
        case .uiRequestBinding(let name): plan.execution.uiProgram!.bindings[name] = text
        case .siriRecognizedText: plan.execution.siriProgram = .init(request: text)
        }
    }
}
