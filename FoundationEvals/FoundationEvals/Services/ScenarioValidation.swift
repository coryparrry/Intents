import Foundation

struct ScenarioValidationIssue: Codable, Equatable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    var id: String { "\(path):\(message)" }
    var severity: Severity
    var path: String
    var message: String
}

enum ScenarioValidationError: LocalizedError, Sendable {
    case invalid([ScenarioValidationIssue])

    var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            issues.filter { $0.severity == .error }.map(\.message).joined(separator: " ")
        }
    }
}

enum ScenarioValidator {
    static func issues(in definition: ScenarioDefinition, requireFrozenDigest: Bool = true) -> [ScenarioValidationIssue] {
        var issues: [ScenarioValidationIssue] = []

        func error(_ path: String, _ message: String) {
            issues.append(.init(severity: .error, path: path, message: message))
        }

        func warning(_ path: String, _ message: String) {
            issues.append(.init(severity: .warning, path: path, message: message))
        }

        if definition.schemaVersion != ScenarioDefinition.currentSchemaVersion {
            error("schemaVersion", "Unsupported scenario schema version \(definition.schemaVersion).")
        }
        if definition.version < 1 { error("version", "Scenario version must be at least 1.") }
        if definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("name", "Give the scenario a name.")
        }
        if requireFrozenDigest, !definition.hasValidDigest {
            error("definitionDigest", "The frozen scenario digest is missing or does not match the definition.")
        }

        let bundle = definition.target.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if bundle.isEmpty || !bundle.contains(".") {
            error("target.bundleIdentifier", "Enter the application bundle identifier used by the signed test.")
        }
        if definition.target.projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("target.projectPath", "Choose the developer-owned Xcode project or workspace.")
        }
        if definition.target.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("target.scheme", "Choose the app scheme to build.")
        }
        if definition.target.testTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("target.testTarget", "Choose the UI-test target containing testIntentLabScenario.")
        }
        if definition.target.destinationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("target.destinationIdentifier", "Choose an enrolled physical device.")
        }

        if definition.goal.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.requestText", "The approved Siri request cannot be empty.")
        }
        if definition.goal.expectedBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.expectedBehavior", "Describe the observable expected behavior.")
        }
        if definition.goal.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.languageCode", "Record the language used for the request.")
        }

        if definition.fixture.id.isEmpty || definition.fixture.version.isEmpty || definition.fixture.digest.isEmpty {
            error("fixture", "The fixture needs a stable ID, version, and digest.")
        }
        if !definition.fixture.isSynthetic, definition.safety.mutationPolicy == .syntheticMutation {
            error("safety.mutationPolicy", "Mutation scenarios must use a declared synthetic fixture.")
        }

        if definition.directControl.intentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("directControl.intentIdentifier", "Declare the App Intent definition identifier.")
        }
        if definition.coverage.appFeature == .required {
            if definition.directControl.linkedFeatureRunID == nil {
                error("directControl.linkedFeatureRunID", "Link a feature run for required App Feature coverage.")
            }
            if definition.directControl.linkedFeatureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("directControl.linkedFeatureID", "Declare the expected feature ID for the linked run.")
            }
            if definition.directControl.linkedFeatureSubjectDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("directControl.linkedFeatureSubjectDigest", "Declare the linked run's subject-evidence digest.")
            }
        }
        let parameterNames = definition.directControl.parameters.map(\.name)
        if Set(parameterNames).count != parameterNames.count {
            error("directControl.parameters", "Intent parameter names must be unique.")
        }
        for (index, parameter) in definition.directControl.parameters.enumerated() {
            let path = "directControl.parameters[\(index)]"
            if parameter.name.isEmpty { error("\(path).name", "A parameter name cannot be empty.") }
            switch parameter.presence {
            case .missing:
                break
            case .value(.null):
                if !parameter.isOptional {
                    error("\(path).presence", "Explicit null is valid only for an optional parameter; use missing to keep an intent default.")
                }
            case .value(let value):
                for message in validate(value: value, as: parameter.type) {
                    error("\(path).presence", message)
                }
            }
        }

        let outputNames = definition.directControl.outputFields.map(\.name)
        if Set(outputNames).count != outputNames.count {
            error("directControl.outputFields", "Declared output field names must be unique.")
        }
        if definition.assertions.isEmpty {
            error("assertions", "Add at least one observable outcome assertion.")
        }
        if Set(definition.assertions.map(\.id)).count != definition.assertions.count {
            error("assertions", "Assertion identifiers must be unique.")
        }
        for (index, assertion) in definition.assertions.enumerated() {
            if assertion.observationKey.isEmpty {
                error("assertions[\(index)].observationKey", "Each assertion must name its evidence observation.")
            }
            if assertion.required, assertion.kind != .semanticRubric, assertion.expectedValue == nil {
                error("assertions[\(index)].expectedValue", "A required deterministic assertion needs an expected value.")
            }
            if assertion.applicableLanes?.isEmpty == true {
                error("assertions[\(index)].applicableLanes", "Choose at least one evidence lane or leave lane scope unset.")
            }
        }
        for lane in ScenarioLane.allCases where definition.coverage[lane] == .required {
            if !definition.assertions.contains(where: { $0.required && $0.applies(to: lane) }) {
                error("coverage.\(lane.rawValue)", "The required \(lane.title) lane needs a required observable outcome assertion.")
            }
        }

        if !definition.safety.deadlineSeconds.isFinite || !(1...900).contains(definition.safety.deadlineSeconds) {
            error("safety.deadlineSeconds", "The execution deadline must be between 1 and 900 seconds.")
        }
        if definition.safety.allowedActions.isEmpty {
            error("safety.allowedActions", "Declare the application actions this scenario permits.")
        }
        if definition.safety.mutationPolicy == .syntheticMutation {
            warning("safety.mutationPolicy", "Mutation attempts run once until deterministic reset and final-state recovery are proven.")
        }
        let siriAttemptCount = definition.coverage.siriAttemptCount ?? 3
        if !(1...3).contains(siriAttemptCount) {
            error("coverage.siriAttemptCount", "Siri attempt count must be between one and three.")
        }
        if definition.safety.mutationPolicy == .syntheticMutation, siriAttemptCount != 1 {
            error("coverage.siriAttemptCount", "Mutation scenarios must run exactly one Siri attempt.")
        }
        if definition.coverage.siri == .required, definition.target.route == .appIntentDefinition {
            warning(
                "target.route",
                "A required Siri lane should identify the proven App Shortcut or schema route, not assume every custom intent is Siri-discoverable."
            )
        }

        return issues
    }

    static func validate(_ definition: ScenarioDefinition, requireFrozenDigest: Bool = true) throws {
        let errors = issues(in: definition, requireFrozenDigest: requireFrozenDigest)
            .filter { $0.severity == .error }
        if !errors.isEmpty { throw ScenarioValidationError.invalid(errors) }
    }

    static func validate(value: ScenarioValue, as type: ScenarioValueType) -> [String] {
        switch (value, type) {
        case (.string, .primitive(.string)), (.boolean, .primitive(.boolean)), (.integer, .primitive(.integer)):
            []
        case (.number(let number), .primitive(.number)):
            number.isFinite ? [] : ["Number parameters must be finite."]
        case (.date(let date), .primitive(.date)):
            TimeZone(identifier: date.timeZoneIdentifier) == nil
                ? ["The date time zone identifier is invalid."] : []
        case (.enumeration(let value), .enumeration(let typeIdentifier, let allowedCases)):
            if value.typeIdentifier != typeIdentifier {
                ["The enum value type does not match the declared type."]
            } else if !allowedCases.contains(value.caseIdentifier) {
                ["The enum case is not in the manifest allowlist."]
            } else {
                []
            }
        case (.entity(let value), .entity(let typeIdentifier)):
            value.typeIdentifier == typeIdentifier && !value.identifier.isEmpty
                ? [] : ["The entity reference must use the declared type and a stable identifier."]
        case (.array(let values), .array(let elementType)):
            values.enumerated().flatMap { index, value in
                validate(value: value, as: elementType).map { "Array item \(index): \($0)" }
            }
        case (.null, _):
            ["Null validation requires the parameter's optional declaration."]
        default:
            ["The value does not match its declared parameter type; lossy conversion is not allowed."]
        }
    }
}

enum ScenarioResultEvaluator {
    static func evaluate(
        definition: ScenarioDefinition,
        lane: ScenarioLane,
        observations: [String: ScenarioValue],
        executionStatus: ScenarioExecutionStatus
    ) -> (ScenarioOutcome, [ScenarioAssertionResult]) {
        guard executionStatus == .completed else { return (.notObserved, []) }
        let assertions = definition.assertions.filter { $0.applies(to: lane) }
        if definition.coverage[lane] == .required && !assertions.contains(where: \.required) {
            return (.needsReview, [])
        }
        let results = assertions.map { assertion -> ScenarioAssertionResult in
            guard let observed = observations[assertion.observationKey] else {
                return .init(
                    assertionID: assertion.id,
                    passed: false,
                    message: "Required observation \(assertion.observationKey) was not captured."
                )
            }
            guard assertion.kind != .semanticRubric else {
                return .init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: "Semantic evidence requires a separate recorded assessment."
                )
            }
            let passed = observed == assertion.expectedValue
            return .init(
                assertionID: assertion.id,
                passed: passed,
                observedValue: observed,
                message: passed ? assertion.explanation : "Observed value did not match the approved expectation."
            )
        }
        let requiredIDs = Set(assertions.filter(\.required).map(\.id))
        let requiredSemantic = assertions.filter { $0.required && $0.kind == .semanticRubric }
        let requiredSemanticIDs = Set(requiredSemantic.map(\.id))
        let failedRequired = results.contains {
            requiredIDs.contains($0.assertionID)
                && !requiredSemanticIDs.contains($0.assertionID)
                && !$0.passed
        }
        let missingRequiredSemantic = requiredSemantic.contains {
            observations[$0.observationKey] == nil
        }
        if failedRequired || missingRequiredSemantic { return (.failed, results) }
        if !requiredSemantic.isEmpty { return (.needsReview, results) }
        return (.passed, results)
    }

    static func overall(definition: ScenarioDefinition, laneResults: [ScenarioLaneResult]) -> ScenarioOutcome {
        let requiredLanes = ScenarioLane.allCases.filter { definition.coverage[$0] == .required }
        guard !requiredLanes.isEmpty,
              requiredLanes.allSatisfy({ lane in
                  definition.assertions.contains { $0.required && $0.applies(to: lane) }
              }) else { return .needsReview }
        let requiredResults = laneResults.filter { requiredLanes.contains($0.lane) }
        if requiredResults.contains(where: { $0.outcome == .failed }) { return .failed }
        if requiredLanes.contains(where: { lane in !requiredResults.contains(where: { $0.lane == lane }) }) {
            return .notObserved
        }
        if requiredResults.contains(where: { $0.executionStatus != .completed || $0.outcome == .notObserved }) {
            return .notObserved
        }
        if requiredResults.contains(where: { $0.outcome == .needsReview }) { return .needsReview }
        if !requiredResults.allSatisfy({ $0.outcome == .passed }) { return .notObserved }
        return .passed
    }
}

enum ScenarioDiagnosticClassifier {
    static func checkpointDiagnostic(for failure: String) -> String {
        let permissionGuidance = failure.localizedCaseInsensitiveContains("Siri to activate")
            ? " Check the iPhone for an intent or Siri access prompt, approve it, then rerun."
            : ""
        return "XCTest: \(failure). Final Siri evidence was not attached.\(permissionGuidance)"
    }

    static func message(for results: [ScenarioLaneResult]) -> String {
        let feature = results.filter { $0.lane == .appFeature }
        let intent = results.filter { $0.lane == .intentIntegration }
        let siri = results.filter { $0.lane == .siri }
        let featureFailed = feature.contains {
            $0.executionStatus == .completed && $0.outcome == .failed
        }
        let featurePassed = !feature.isEmpty && feature.allSatisfy {
            $0.executionStatus == .completed && $0.outcome == .passed
        }
        let intentFailed = intent.contains { $0.outcome == .failed }
        let intentPassed = !intent.isEmpty && intent.allSatisfy { $0.outcome == .passed }
        let siriFailed = siri.contains { $0.outcome == .failed }

        if featureFailed && intentFailed {
            return "The production feature and direct intent failed similarly. Investigate the application feature first; this evidence does not attribute the failure to Siri."
        }
        if featurePassed && intentFailed {
            return "The feature control passed, but the direct intent returned a wrong or incomplete observable result. An application integration or mapping failure is observed."
        }
        if intentFailed {
            return "The direct intent failed. No completed passing feature control is available, so the evidence does not establish where the failure arose."
        }
        if intentPassed && siriFailed {
            return "The direct intent passed, but the Siri-driven outcome failed. The evidence establishes a Siri-experience failure, not Siri's hidden reasoning or the point where the wrong value was introduced."
        }
        if siri.contains(where: { $0.outcome == .notObserved }) {
            return "The Siri outcome was not established because required invocation or final-state evidence is missing."
        }
        return "Review each evidence lane separately; the available observations do not establish a more specific boundary."
    }
}
