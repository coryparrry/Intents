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

        let isReusable = definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
        if definition.schemaVersion != ScenarioDefinition.currentSchemaVersion && !isReusable {
            error("schemaVersion", "Unsupported scenario schema version \(definition.schemaVersion).")
        }
        if isReusable {
            if let integration = definition.integration {
                if !validIdentifier(integration.id) || integration.version.isEmpty || integration.version.count > 64
                    || integration.digest.count != 64
                    || integration.digest.unicodeScalars.contains(where: {
                        !CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                    }) {
                    error("integration", "Bind a stable integration ID, version, and lowercase SHA-256 declaration digest.")
                }
            } else {
                error("integration", "Bind the selected integration declaration before freezing this check.")
            }
            if definition.purpose == nil { error("purpose", "Choose exploratory check or release requirement.") }
            if definition.checkMode == nil { error("checkMode", "Choose Basic or Behaviour checks.") }
            if definition.requiredClaims == nil {
                error("requiredClaims", "Declare the proof claims this check requires.")
            }
            let claims = definition.requiredClaims ?? []
            if claims.isEmpty || !claims.contains(.executionCompleted) || Set(claims).count != claims.count {
                error("requiredClaims", "Include executionCompleted once and do not duplicate proof claims.")
            }
            if definition.observationPlan == nil {
                error("observationPlan", "Declare an observation plan, including an empty plan for execution-only checks.")
            }
            if definition.checkMode == .basic, claims.contains(.applicationStateChecked) {
                error("requiredClaims", "Basic checks cannot claim application state coverage.")
            }
            if definition.checkMode == .behaviour, !claims.contains(.applicationStateChecked) {
                error("requiredClaims", "Behaviour checks must require application state evidence.")
            }
            if definition.purpose == .releaseRequirement, definition.assertions.isEmpty {
                error("assertions", "A release requirement needs an observable assertion.")
            }
            if definition.coverage.intentIntegration != .required {
                error("coverage.intentIntegration", "Version 2 checks require the direct intent lane.")
            }
        } else if definition.schemaVersion == ScenarioDefinition.currentSchemaVersion,
                  definition.purpose != nil || definition.checkMode != nil
                    || definition.requiredClaims != nil || definition.observationPlan != nil
                    || definition.integration != nil {
            error("schemaVersion", "Version 1 scenarios cannot declare version 2 coverage fields.")
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

        if (!isReusable || definition.coverage.siri != .notApplicable),
           definition.goal.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.requestText", "The approved Siri request cannot be empty.")
        }
        if (!isReusable || definition.checkMode == .behaviour || definition.purpose == .releaseRequirement),
           definition.goal.expectedBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.expectedBehavior", "Describe the observable expected behavior.")
        }
        if (!isReusable || definition.coverage.siri != .notApplicable),
           definition.goal.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("goal.languageCode", "Record the language used for the request.")
        }

        if (!isReusable || definition.safety.mutationPolicy != .readOnly),
           (definition.fixture.id.isEmpty || definition.fixture.version.isEmpty || definition.fixture.digest.isEmpty) {
            error("fixture", "The fixture needs a stable ID, version, and digest.")
        }
        if !definition.fixture.isSynthetic, definition.safety.mutationPolicy == .syntheticMutation {
            error("safety.mutationPolicy", "Mutation scenarios must use a declared synthetic fixture.")
        }
        if isReusable, definition.safety.mutationPolicy == .syntheticMutation,
           ["", "none", "noop", "readOnly"].contains(
               definition.fixture.cleanupOperation.trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            error("fixture.cleanupOperation", "Mutation scenarios need a compiled cleanup operation that restores and verifies the synthetic fixture.")
        }

        if definition.directControl.intentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("directControl.intentIdentifier", "Declare the App Intent definition identifier.")
        } else if isReusable, !validIdentifier(definition.directControl.intentIdentifier) {
            error("directControl.intentIdentifier", "Use a bounded App Intent identifier without path syntax.")
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
            if isReusable, !validIdentifier(parameter.name) {
                error("\(path).name", "Use a bounded parameter name without path syntax.")
            }
            if isReusable {
                for message in validateDeclaration(parameter.type) { error("\(path).type", message) }
            }
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
        if isReusable {
            for (index, field) in definition.directControl.outputFields.enumerated() {
                let fieldPath = "directControl.outputFields[\(index)]"
                if !validIdentifier(field.name) {
                    error("\(fieldPath).name", "An output needs a bounded stable observation key.")
                }
                for message in validateDeclaration(field.type) { error("\(fieldPath).type", message) }
                guard let path = field.path, !path.isEmpty, path.count <= 8 else {
                    error("\(fieldPath).path", "Choose one to eight typed projection path components.")
                    continue
                }
                if path.last?.kind == .count, field.type != .primitive(.integer) {
                    error("\(fieldPath).type", "A count projection must declare an integer result.")
                }
                for (componentIndex, component) in path.enumerated() {
                    let componentPath = "\(fieldPath).path[\(componentIndex)]"
                    switch component.kind {
                    case .property:
                        if component.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                            || component.index != nil
                            || component.name.map({ !validPropertyName($0) }) != false {
                            error(componentPath, "A property component needs one bounded property name, without path syntax.")
                        }
                    case .index:
                        if component.name != nil || component.index.map({ !(0..<100).contains($0) }) != false {
                            error(componentPath, "An index component needs only an index from 0 to 99.")
                        }
                    case .count:
                        if component.name != nil || component.index != nil || componentIndex != path.count - 1 {
                            error(componentPath, "A count component must be the final path component.")
                        }
                    }
                }
            }
        }
        if definition.assertions.isEmpty && !isReusable {
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
        if isReusable {
            let plan = definition.observationPlan ?? []
            if Set(plan.map(\.id)).count != plan.count {
                error("observationPlan", "Observation identifiers must be unique.")
            }
            for (index, observation) in plan.enumerated() {
                if !validIdentifier(observation.id) {
                    error("observationPlan[\(index)].id", "An observation needs a bounded stable ID.")
                }
                if observation.source != .intentResult && observation.source != .uiElement,
                   observation.operationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    error("observationPlan[\(index)].operationID", "State observers need a compiled operation ID.")
                }
                if let operationID = observation.operationID, !validIdentifier(operationID) {
                    error("observationPlan[\(index)].operationID", "Use a bounded compiled operation identifier.")
                }
                if let selector = observation.selector, selector.count > 256 || selector.isEmpty {
                    error("observationPlan[\(index)].selector", "Use a non-empty selector of at most 256 characters.")
                }
                if observation.source == .uiElement, observation.selector == nil {
                    error("observationPlan[\(index)].selector", "UI observations need a stable accessibility identifier.")
                }
                if observation.source == .intentResult,
                   !definition.directControl.outputFields.contains(where: { $0.name == observation.id }) {
                    error("observationPlan[\(index)].id", "An intent result observation needs a matching output projection.")
                }
            }
            for (index, assertion) in definition.assertions.enumerated() {
                guard let observation = plan.first(where: { $0.id == assertion.observationKey }) else {
                    error("assertions[\(index)].observationKey", "The assertion needs a declared observation.")
                    continue
                }
                if assertion.kind == .returnedField && observation.source != .intentResult {
                    error("assertions[\(index)].kind", "Returned-value assertions must use an intent result observation.")
                }
                if assertion.kind != .returnedField && !observation.source.checksApplicationState {
                    error("assertions[\(index)].kind", "Application-state assertions need an independent state observer.")
                }
                if definition.checkMode == .basic && assertion.kind != .returnedField {
                    error("assertions[\(index)].kind", "Basic checks can assert returned values only.")
                }
            }
            let claims = definition.requiredClaims ?? []
            func hasRequiredStateProof(for lane: ScenarioLane) -> Bool {
                definition.assertions.contains { assertion in
                    assertion.required && assertion.applies(to: lane)
                        && assertion.kind != .semanticRubric
                        && assertion.kind != .returnedField
                        && assertion.expectedValue != nil
                        && plan.contains {
                            $0.id == assertion.observationKey && $0.source.checksApplicationState
                        }
                }
            }
            if claims.contains(.returnedValueChecked),
               !definition.assertions.contains(where: { $0.required && $0.kind == .returnedField }) {
                error("requiredClaims", "A returned-value claim needs a required returned-value assertion.")
            }
            if claims.contains(.applicationStateChecked), !hasRequiredStateProof(for: .intentIntegration) {
                error("requiredClaims", "An application-state claim needs a required deterministic state assertion in the direct intent lane.")
            }
            if definition.coverage.siri != .notApplicable, !hasRequiredStateProof(for: .siri) {
                error("coverage.siri", "Siri checks need a required deterministic final-state assertion; a submitted request cannot pass alone.")
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

    private static func validIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
            && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    private static func validPropertyName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func validateDeclaration(_ type: ScenarioValueType) -> [String] {
        switch type {
        case .primitive: return []
        case .enumeration(let typeIdentifier, let allowedCases):
            if !validIdentifier(typeIdentifier) || allowedCases.isEmpty || allowedCases.count > 100
                || Set(allowedCases).count != allowedCases.count || !allowedCases.allSatisfy(validIdentifier) {
                return ["Enum declarations need a stable type and a bounded, unique case allowlist."]
            }
            return []
        case .entity(let typeIdentifier):
            return validIdentifier(typeIdentifier) ? [] : ["Entity declarations need a stable type identifier."]
        case .array(let element):
            if case .array = element { return ["Nested arrays are not supported."] }
            return validateDeclaration(element)
        }
    }

    static func validate(value: ScenarioValue, as type: ScenarioValueType) -> [String] {
        switch (value, type) {
        case (.string, .primitive(.string)), (.boolean, .primitive(.boolean)), (.integer, .primitive(.integer)):
            []
        case (.number(let number), .primitive(.number)):
            number.isFinite ? [] : ["Number parameters must be finite."]
        case (.date(let date), .primitive(.date)):
            if TimeZone(identifier: date.timeZoneIdentifier) == nil {
                ["The date time zone identifier is invalid."]
            } else if date.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !date.resolvedInstant.timeIntervalSince1970.isFinite {
                ["Date parameters need source text and a finite resolved instant."]
            } else {
                []
            }
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
        guard !requiredLanes.isEmpty else { return .needsReview }
        if definition.schemaVersion == ScenarioDefinition.currentSchemaVersion,
           !definition.assertions.contains(where: { assertion in
               assertion.required && requiredLanes.contains(where: assertion.applies(to:))
           }) { return .needsReview }
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
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            let direct = requiredResults.filter { $0.lane == .intentIntegration }
            let claims = definition.requiredClaims ?? []
            if claims.contains(.executionCompleted),
               (direct.isEmpty || !direct.allSatisfy({ verifiedClaim(.executionCompleted, definition: definition, result: $0) })) {
                return .notObserved
            }
            if claims.contains(.returnedValueChecked),
               !direct.allSatisfy({ verifiedClaim(.returnedValueChecked, definition: definition, result: $0) }) {
                return .notObserved
            }
            if claims.contains(.applicationStateChecked),
               !direct.allSatisfy({ verifiedClaim(.applicationStateChecked, definition: definition, result: $0) }) {
                return .notObserved
            }
            if definition.coverage.siri != .notApplicable,
               requiredResults.filter({ $0.lane == .siri }).contains(where: {
                   !verifiedClaim(.applicationStateChecked, definition: definition, result: $0)
               }) { return .notObserved }
        }
        return .passed
    }

    static func verifiedClaim(
        _ claim: ScenarioProofClaim,
        definition: ScenarioDefinition,
        result: ScenarioLaneResult
    ) -> Bool {
        guard result.executionStatus == .completed, result.outcome == .passed,
              result.claims?.contains(claim) == true else { return false }
        if claim == .executionCompleted { return result.lane == .intentIntegration }
        let plan = definition.observationPlan ?? []
        return definition.assertions.contains { assertion in
            guard assertion.required, assertion.applies(to: result.lane),
                  let observation = plan.first(where: { $0.id == assertion.observationKey }),
                  let observed = result.observations[assertion.observationKey],
                  let source = result.observationSources?[assertion.observationKey],
                  result.assertionResults.contains(where: { $0.assertionID == assertion.id && $0.passed })
            else { return false }
            let sourceMatches: Bool
            switch observation.source {
            case .intentResult: sourceMatches = source == .appIntentsTesting
            case .entityQuery: sourceMatches = source == .entityQuery
            case .valueQuery: sourceMatches = source == .valueQuery
            case .uiElement: sourceMatches = source == .accessibleUI
            case .testOnlyIntent: sourceMatches = source == .testOnlyIntent || source == .applicationInstrumentation
            }
            guard sourceMatches, observed == assertion.expectedValue else { return false }
            switch claim {
            case .executionCompleted: return false
            case .returnedValueChecked: return assertion.kind == .returnedField
                && observation.source == .intentResult
            case .applicationStateChecked: return assertion.kind != .returnedField
                && observation.source.checksApplicationState
            }
        }
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
        let featureFailed = feature.contains { $0.outcome == .failed }
        let featurePassed = !feature.isEmpty && feature.allSatisfy { $0.outcome == .passed }
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
            return "The direct intent failed an observable check. No passing app-feature control was recorded, so this run cannot show whether the underlying feature or the intent integration caused it."
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
