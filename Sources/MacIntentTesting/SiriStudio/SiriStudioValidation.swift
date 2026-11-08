import Foundation

/// Validates the same authored document for the editor, CLI, and generator.
public enum SiriStudioValidation {
    /// Checks every document identity and shared setting, then validates content only for the requested scenarios.
    /// A nil selection validates all conversations; an explicit selection may leave other drafts unfinished.
    public static func validate(_ document: SiriStudioDocument, catalog: MacIntentCatalog,
                                scenarioIDs: Set<UUID>? = nil) throws {
        guard document.version == SiriStudioDocument.currentVersion else {
            throw MacIntentTestingError("Unsupported Siri Studio document version \(document.version).")
        }
        _ = try MacIntentRunConfiguration.validatedAppLaunchArguments(document.appLaunchArguments ?? [])
        guard document.bundleIdentifier == catalog.bundleIdentifier else {
            throw MacIntentTestingError("This document belongs to \(document.bundleIdentifier), not \(catalog.bundleIdentifier).")
        }
        guard (1...200).contains(document.scenarios.count) else {
            throw MacIntentTestingError("Supply 1–200 scenarios.")
        }
        let actions = Dictionary(grouping: catalog.actions, by: \.id)
        guard actions.values.allSatisfy({ $0.count == 1 }) else {
            throw MacIntentTestingError("Duplicate action identifiers in catalog.")
        }
        try validateIdentities(document)
        for scenario in try selectedScenarios(in: document, scenarioIDs) {
            do {
                guard (1..<Int.max).contains(scenario.revision), (1...10).contains(scenario.repeatCount),
                      (1...12).contains(scenario.turns.count),
                      !scenario.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MacIntentTestingError("Provide a name, a positive revision, 1–10 repeats, and 1–12 turns.")
                }
                guard scenario.scenarioExpectations.replyContains.isEmpty else {
                    throw MacIntentTestingError("Reply checks belong on a turn, not on the whole scenario.")
                }
                guard !scenario.metrics.isEmpty else {
                    throw MacIntentTestingError("Add at least one expectation.")
                }
                try validateGroup(scenario.scenarioExpectations, actions: actions)
                if let setup = scenario.setup {
                    guard setup.expectedValueJSON == nil else {
                        throw MacIntentTestingError("Setup checks only that the action succeeds. Remove its expected result.")
                    }
                    do { _ = try MacIntentSource.intentInputs(setup, catalog: catalog) }
                    catch { throw MacIntentTestingError("Setup: \(error.localizedDescription)") }
                }
                for (index, turn) in scenario.turns.enumerated() {
                    do {
                        guard turn.utterance.utf8.count <= 1000,
                              !turn.utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw MacIntentTestingError("Enter an utterance from 1 to 1,000 UTF-8 bytes.")
                        }
                        try validateGroup(turn.expectations, actions: actions)
                        try requireNoContradiction(turn.expectations.calls, scenario.scenarioExpectations.forbidden)
                    } catch { throw MacIntentTestingError("Turn \(index + 1): \(error.localizedDescription)") }
                }
            } catch { throw MacIntentTestingError("\(scenario.name): \(error.localizedDescription)") }
        }
    }

    /// Keeps document-wide identity checks even when unfinished, unselected content is not executed.
    private static func validateIdentities(_ document: SiriStudioDocument) throws {
        var ids = Set<UUID>()
        for scenario in document.scenarios {
            try unique(scenario.id, in: &ids)
            if let setup = scenario.setup { try unique(setup.id, in: &ids) }
            for turn in scenario.turns { try unique(turn.id, in: &ids) }
            for group in [scenario.scenarioExpectations] + scenario.turns.map(\.expectations) {
                for call in group.calls + group.forbidden { try unique(call.id, in: &ids) }
            }
        }
    }

    /// Selects in authored order and rejects unknown or explicitly empty selections.
    static func selectedScenarios(in document: SiriStudioDocument, _ ids: Set<UUID>?) throws -> [SiriStudioScenario] {
        let selected = document.scenarios.filter { ids?.contains($0.id) ?? true }
        guard !selected.isEmpty, ids == nil || ids?.count == selected.count else {
            throw MacIntentTestingError("Select at least one scenario and use only IDs in this document.")
        }
        return selected
    }

    /// Verifies UUID uniqueness across all authored items.
    private static func unique(_ id: UUID, in ids: inout Set<UUID>) throws {
        guard ids.insert(id).inserted else { throw MacIntentTestingError("Duplicate authored ID \(id).") }
    }

    /// Resolves calls against compiled metadata and checks expectation consistency.
    private static func validateGroup(_ group: SiriStudioExpectations, actions: [String: [MacIntentAction]]) throws {
        for call in group.calls + group.forbidden {
            guard let action = actions[call.actionIdentifier]?.first else {
                throw MacIntentTestingError("Unknown action \(call.actionIdentifier).")
            }
            var parameters = Set<String>()
            for argument in call.arguments {
                let id = argument.parameterIdentifier
                guard let parameter = action.parameters.first(where: { $0.id == id }) else {
                    throw MacIntentTestingError("Unknown parameter \(id) on \(action.id).")
                }
                guard parameters.insert(id).inserted else { throw MacIntentTestingError("Duplicate parameter \(id).") }
                try validateMatcher(argument.matcher, type: parameter.type, enumCases: parameter.enumCases,
                                    entity: parameter.entityIdentifier, label: "\(action.id).\(id)")
            }
            if let result = call.result {
                guard ["String", "Int", "Double", "Bool"].contains(action.outputType),
                      !group.forbidden.contains(where: { $0.id == call.id }) else {
                    throw MacIntentTestingError("Result matching is available only for required calls with scalar results.")
                }
                try validateMatcher(result, type: action.outputType, label: "\(action.id) result")
            }
        }
        guard group.replyContains.allSatisfy({ !$0.text.isEmpty }) else {
            throw MacIntentTestingError("Enter text for each reply check.")
        }
        try requireNoContradiction(group.calls, group.forbidden)
    }

    /// Rejects a required action whenever the same scope unconditionally forbids it.
    private static func requireNoContradiction(_ calls: [SiriStudioCall], _ forbidden: [SiriStudioCall]) throws {
        let excluded = Set(forbidden.filter { $0.arguments.isEmpty }.map(\.actionIdentifier))
        if let conflict = calls.first(where: { excluded.contains($0.actionIdentifier) }) {
            throw MacIntentTestingError("\(conflict.actionIdentifier) is both required and forbidden.")
        }
    }

    /// Checks matcher compatibility and validates values before any Swift is emitted.
    private static func validateMatcher(_ matcher: SiriStudioMatcher, type: String, enumCases: [String] = [],
                                        entity: String? = nil, label: String) throws {
        let allowed: Bool
        switch matcher {
        case .isNil, .notNil: allowed = true
        case .equals, .contains: allowed = type == "String"
        case .containsRegex(let pattern):
            allowed = type == "String"
            if allowed, (try? Regex(pattern)) == nil { throw MacIntentTestingError("Invalid regular expression for \(label).") }
        case .intEquals: allowed = type == "Int"
        case .doubleEquals(let value): allowed = type == "Double" && value.isFinite
        case .boolEquals: allowed = type == "Bool"
        case .enumCase(let value): allowed = type == "Enum" && enumCases.contains(value)
        case .entityIdentifier(let entityType, let identifier): allowed = entity == entityType && !identifier.isEmpty
        }
        guard allowed else { throw MacIntentTestingError("Matcher or value is not allowed for \(label) (\(entity ?? type)).") }
    }
}
