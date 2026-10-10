import Foundation

/// Data-only proposal: each exact phrase still requires campaign approval.
/// This family changes no setup, input binding, endpoint, oracle or budget.
public enum AutomationGoalPhraseVariation {
    public static func propose(baseline: AutomationFrozenCase, instruction: String,
                               semanticJustification: String) throws -> AutomationMutationCase {
        try baseline.validate()
        _ = try contractDigest(baseline.plan)
        guard !semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              semanticJustification.utf16.count <= 4096 else { throw AutomationContractError.invalidPlan("Explain the approved phrase's intended equivalence") }
        var plan = baseline.plan
        guard var program = plan.execution.uiProgram, var goal = program.operations[0].goal,
              goal.instruction != instruction else { throw AutomationContractError.invalidPlan("Phrase must differ from the baseline") }
        goal.instruction = instruction; try goal.validate()
        program.operations[0].goal = goal; plan.execution.uiProgram = program; plan.execution.operation = instruction
        plan.revision = 1
        plan.id = "phrase." + String(AutomationArtifactRegistry.digest(Data((baseline.digest + "\n" + instruction).utf8)).prefix(32))
        let mutation = AutomationMutationCase(frozen: try .init(plan: plan), recipeIDs: [], kinds: [.alternatePhrasing],
            requiredCapabilities: [], semanticJustification: semanticJustification, goalPhraseVariation: true)
        try validate(mutation, baseline: baseline)
        return mutation
    }
    static func validateBaseline(_ plan: AutomationCase) throws { _ = try contractDigest(plan) }
    static func validate(_ mutation: AutomationMutationCase, baseline: AutomationFrozenCase) throws {
        guard mutation.goalPhraseVariation == true, mutation.kinds == [.alternatePhrasing], mutation.recipeIDs.isEmpty,
              mutation.requiredCapabilities.isEmpty, !mutation.semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mutation.semanticJustification.utf16.count <= 4096,
              mutation.frozen.plan.execution.operation != baseline.plan.execution.operation,
              try contractDigest(mutation.frozen.plan) == contractDigest(baseline.plan) else {
            throw AutomationContractError.invalidPlan("Goal phrase variation changes the approved workflow contract")
        }
    }
    private static func contractDigest(_ plan: AutomationCase) throws -> String {
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard !plan.requirements.isEmpty, segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }),
              plan.execution.kind == .ui, plan.execution.hostProgram == nil,
              let program = plan.execution.uiProgram, program.operations.count == 1,
              program.operations[0].kind == .navigateGoal, let goal = program.operations[0].goal,
              plan.execution.operation == goal.instruction else {
            throw AutomationContractError.invalidPlan("Phrase trials require a read-only UI navigation goal and separate business observer")
        }
        try program.validate(phase: .subject)
        var normalized = plan
        normalized.id = "approved-phrase-contract"; normalized.revision = 1
        normalized.execution.operation = "approved-phrase"
        normalized.execution.uiProgram!.operations[0].goal!.instruction = "approved-phrase"
        return try AutomationFrozenCase.planDigest(normalized)
    }
}
