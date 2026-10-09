import Foundation

/// A frozen, developer-approved name prefix, expanded locally for each attempt.
/// It identifies a fixture through a subsequent real query; it is never an entity ID.
public enum AutomationAttemptText {
    public static func value(prefix: String, attemptID: String) throws -> String {
        try validatePrefix(prefix)
        guard !attemptID.isEmpty, attemptID.utf16.count <= 256 else { throw AutomationInputBindingError.inputUnavailable }
        return prefix + "-Intents-" + AutomationArtifactRegistry.digest(Data(attemptID.utf8))
    }
    static func validatePrefix(_ prefix: String) throws {
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prefix.utf16.count <= 128,
              !prefix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AutomationContractError.invalidPlan("Test name needs a short visible prefix")
        }
    }
    static func validate(plan: AutomationCase, approval: RunApproval) throws {
        var available = Set<String>()
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            let declared = segment.attemptTextBindings ?? [:]
            guard declared.count <= 1, declared.isEmpty || (segment.kind == .ui && segment.phase == .setup &&
                segment.effects.contains(.fixtureWrite) && segment.effects.isSubset(of: [.observe, .navigate, .fixtureWrite]) &&
                approval.disposable && segment.uiProgram != nil) else {
                throw AutomationContractError.invalidPlan("Fresh names require disposable UI fixture setup")
            }
            for (name, prefix) in declared {
                try validatePrefix(prefix)
                guard AutomationHostProgram.identifier(name), segment.uiProgram?.bindings[name] == nil,
                      !(segment.inputBindings ?? []).contains(where: { $0.destination == .uiBinding && $0.name == name }) else {
                    throw AutomationContractError.invalidPlan("Fresh name cannot replace another input")
                }
            }
            let selections = (segment.inputBindings ?? []).compactMap(\.uniqueEntity) +
                ((plan.setupChecks ?? []) + plan.requirements).filter { $0.observationID == segment.id }.compactMap { $0.entityProperty?.selection }
            for selection in selections {
                guard (selection.attemptProperties ?? [:]).values.allSatisfy(available.contains) else {
                    throw AutomationContractError.invalidPlan("Fresh selection needs a preceding approved UI name")
                }
            }
            for operation in segment.hostProgram?.operations ?? [] {
                if let prefix = operation.attemptQueryPrefix {
                    guard available.contains(prefix), segment.kind == .systemQuery,
                          segment.effects.isSubset(of: [.observe]) else { throw AutomationContractError.invalidPlan("Fresh lookup requires preceding UI fixture setup") }
                }
            }
            available.formUnion(declared.values)
        }
    }
}
