import Foundation

/// Generates the same stand-alone Swift file for export and execution.
public enum SiriStudioSource {
    /// Validates the document and emits one Swift Testing test per selected scenario.
    public static func tests(document: SiriStudioDocument, catalog: MacIntentCatalog,
                             scenarioIDs: Set<UUID>? = nil) throws -> String {
        try SiriStudioValidation.validate(document, catalog: catalog, scenarioIDs: scenarioIDs)
        let scenarios = try selection(in: document, scenarioIDs)
        let revisions = scenarios.map { "\($0.id.uuidString)=\($0.revision)" }.joined(separator: ", ")
        let sources = try scenarios.map { try test($0, catalog: catalog) }
        return """
        // Intents Siri Studio generator 1. Document v\(document.version), revisions: \(revisions)
        // Add this file to a Swift Testing UI test target deploying to macOS 27.3 or later.
        // Use Xcode 27.3 or later, Siri AI, and the same development team as the app under test.
        // Exported tests record local attachments containing utterances, arguments, and replies.
        import Foundation
        import Testing
        import SiriEvaluations
        import TabularData

        private let definitions = IntentDefinitions(bundleIdentifier: \(literal(catalog.bundleIdentifier)))

        \(SiriStudioGeneratedSupport.source)

        @Suite(.serialized)
        struct SiriStudioScenarios {
        \(indent(sources.joined(separator: "\n\n"), by: 4))
        }

        """
    }

    /// Keeps authored order and rejects unknown or empty selections.
    static func selection(in document: SiriStudioDocument, _ ids: Set<UUID>?) throws -> [SiriStudioScenario] {
        try SiriStudioValidation.selectedScenarios(in: document, ids)
    }

    /// Builds the sample factory, evaluation trait, and metric assertions for one scenario.
    private static func test(_ scenario: SiriStudioScenario, catalog: MacIntentCatalog) throws -> String {
        let id = scenario.id.uuidString
        let token = id.replacingOccurrences(of: "-", with: "_")
        let turns = scenario.turns.map { turn in
            let expectations = group(turn.expectations)
            let start = "        UserTurn(\(literal(turn.utterance)))"
            return expectations.isEmpty ? start : start + " {\n" + indent(expectations, by: 12) + "\n        }"
        }.joined(separator: "\n")
        let whole = group(scenario.scenarioExpectations)
        let scenarioSource = whole.isEmpty ? "    }" : "    } expectation: {\n" + indent(whole, by: 8) + "\n    }"
        let setup = try scenario.setup.map { try setupBody($0, catalog: catalog) } ?? "nil"
        let metricDefinitions = scenario.metrics.map { "(\(literal($0)), Metric.\($0))" }.joined(separator: ", ")
        return """
        private static let evaluation_\(token) = StudioEvaluation(
            name: \(literal(scenario.name)), scenarioID: \(literal(id)), revision: \(scenario.revision),
            contentDigest: \(literal(try scenario.contentDigest(bundleIdentifier: catalog.bundleIdentifier))),
            turnIDs: [\(scenario.turns.map { literal($0.id.uuidString) }.joined(separator: ", "))],
            samples: (0..<\(scenario.repeatCount)).map { _ in
                SiriScenario {
        \(indent(turns, by: 8))
        \(indent(scenarioSource, by: 8))
            },
            setup: \(setup)
        )

        @Test(.evaluates(evaluation_\(token),
                         info: ["intents.scenario": \(literal(id)), "intents.revision": "\(scenario.revision)"],
                         recordTranscripts: true))
        static func scenario_\(token)() async {
            let result = EvaluationContext.current.result
            let metrics = [\(metricDefinitions)]
            await evaluation_\(token).record(result, metrics: metrics)
            for (_, metric) in metrics {
                #expect(result.aggregateValue(.mean(of: metric)) == 1)
            }
        }
        """
    }

    /// Emits a setup closure with exactly the Direct Action input semantics.
    private static func setupBody(_ setup: MacIntentTestCase, catalog: MacIntentCatalog) throws -> String {
        let (action, inputs) = try MacIntentSource.intentInputs(setup, catalog: catalog)
        let binding = inputs.isEmpty ? "let" : "var"
        let lines = ["        \(binding) intent = definitions.intents[\(literal(action.id))].makeIntent()"]
            + inputs + ["        _ = try await intent.run()"]
        return "{\n" + lines.joined(separator: "\n") + "\n    }"
    }

    /// Emits one group for each ordering rule and combines all reply checks in one expression.
    private static func group(_ group: SiriStudioExpectations) -> String {
        var parts: [String] = []
        for (ordering, calls) in [(group.ordering.rawValue, group.calls), ("disallowed", group.forbidden)] where !calls.isEmpty {
            parts.append("Calls(.\(ordering)) {\n" + indent(calls.map(call).joined(separator: "\n"), by: 4) + "\n}")
        }
        if !group.replyContains.isEmpty {
            let checks = group.replyContains.map { ".contains(\(literal($0.text)), caseSensitive: \($0.caseSensitive))" }
            parts.append("SiriResponse(\(checks.joined(separator: ", ")))")
        }
        return parts.joined(separator: "\n")
    }

    /// Emits typed constraints with parameter identifiers represented as quoted data.
    private static func call(_ call: SiriStudioCall) -> String {
        var source = "definitions.intents[\(literal(call.actionIdentifier))]"
        if !call.arguments.isEmpty {
            source += ".expect.dynamicallyCall(withKeywordArguments: .init(dictionaryLiteral: " + call.arguments.map {
                "(\(literal($0.parameterIdentifier)), \(matcher($0.matcher)))"
            }.joined(separator: ", ") + "))"
        }
        if let result = call.result { source += ".result(\(matcher(result)))" }
        return source
    }

    /// Translates typed values into the public Apple matcher APIs.
    private static func matcher(_ matcher: SiriStudioMatcher) -> String {
        switch matcher {
        case .equals(let value), .enumCase(let value): ".equals(\(literal(value)))"
        case .contains(let value): ".contains(\(literal(value)))"
        case .containsRegex(let value): ".contains(regex: \(literal(value)))"
        case .isNil: ".isNil"
        case .notNil: ".notNil"
        case .intEquals(let value): ".matches(#Predicate<Int> { $0 == \(value) })"
        case .doubleEquals(let value): ".matches(#Predicate<Double> { $0 == \(value) })"
        case .boolEquals(let value): ".matches(#Predicate<Bool> { $0 == \(value) })"
        case .entityIdentifier(let type, let value): "definitions.entities[\(literal(type))].expectIdentifier(\(literal(value)))"
        }
    }

    /// Quotes authored text as a Swift literal, including interpolation markers.
    private static func literal(_ value: String) -> String { MacIntentSource.literal(value) }

    /// Indents a generated Swift fragment without changing its content.
    private static func indent(_ code: String, by spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        return code.components(separatedBy: "\n").map { $0.isEmpty ? "" : padding + $0 }.joined(separator: "\n")
    }
}
