import Foundation
import CryptoKit

enum ScenarioDeclaredExpectedValues {
    static func initial(for type: ScenarioValueType) -> ScenarioValue? {
        switch type {
        case .primitive(.string): return .string("")
        case .primitive(.boolean): return .boolean(false)
        case .primitive(.integer): return .integer(0)
        case .primitive(.number): return .number(0)
        case .primitive(.date):
            let instant = Date()
            return .date(.init(source: ISO8601DateFormatter().string(from: instant),
                               timeZoneIdentifier: TimeZone.current.identifier,
                               resolvedInstant: instant))
        case .enumeration(let typeIdentifier, let cases):
            return cases.first.map { ScenarioValue.enumeration(.init(typeIdentifier: typeIdentifier, caseIdentifier: $0)) }
        case .entity(let typeIdentifier):
            return .entity(.init(typeIdentifier: typeIdentifier, identifier: ""))
        case .array: return .array([])
        }
    }
}

/// The app-owned, compiled declaration is the editor's catalogue. Its fields
/// mirror only the public Intent Lab wire contract needed for authoring.
struct ScenarioIntegrationCatalog: Codable, Sendable {
    struct Action: Codable, Sendable, Identifiable {
        struct Parameter: Codable, Sendable {
            var name: String
            var type: ScenarioValueType
            var required: Bool
        }
        var id: String
        var parameters: [Parameter]
    }

    struct Projection: Codable, Sendable, Identifiable {
        var id: String
        var type: ScenarioValueType
        var path: [ScenarioProjectionPathComponent]
    }

    struct Observer: Codable, Sendable, Identifiable {
        var id: String
        var source: ScenarioPlannedObservationSource
        var type: ScenarioValueType
        var operationID: String?
        var selector: String?
    }

    struct FeatureControl: Codable, Sendable {
        var featureID: String
        var interfaceDigest: String
        var operationID: String
        var testIntentIdentifier: String
        var parameters: [Action.Parameter]
        var outputProjections: [Projection]
    }

    var schemaVersion: Int
    var id: String
    var version: String
    var targetBundleIdentifier: String
    var actions: [Action]
    var resultProjections: [Projection]
    var observers: [Observer]
    var preparationOperations: [String]
    var capabilities: [String]
    var localFeatureControls: [FeatureControl]? = nil

    func localFeatureControl(for definition: ScenarioDefinition) -> FeatureControl? {
        guard let binding = definition.featureBinding,
              let operationID = definition.actionRequirements?.first(where: {
                  $0.lane == .appFeature && $0.kind == .productionService
              })?.operationID,
              capabilities.contains("local-feature-controls") else { return nil }
        let matches = (localFeatureControls ?? []).filter {
            $0.featureID == binding.featureID
                && $0.interfaceDigest == binding.interfaceDigest
                && $0.operationID == operationID
        }
        guard matches.count == 1, let control = matches.first,
              !control.testIntentIdentifier.isEmpty,
              Set(control.parameters.map(\.name)).count == control.parameters.count,
              Set(control.outputProjections.map(\.id)).count == control.outputProjections.count,
              Set(binding.inputMapping.map(\.featureInputName)).count == binding.inputMapping.count,
              control.parameters.filter(\.required).allSatisfy({ parameter in
                  binding.inputMapping.contains { $0.featureInputName == parameter.name }
              }),
              binding.inputMapping.allSatisfy({ input in
                  control.parameters.contains { parameter in
                      parameter.name == input.featureInputName
                          && ScenarioValidator.validate(value: input.value, as: parameter.type).isEmpty
                  }
              }),
              binding.outputProjections.count == control.outputProjections.count,
              binding.outputProjections.allSatisfy({ field in
                  control.outputProjections.contains {
                      $0.id == field.name && $0.type == field.type && $0.path == field.path
                  }
              }) else { return nil }
        return control
    }

    static func decodeVerified(_ data: Data, identity: ScenarioIntegrationIdentity) throws -> Self {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == identity.digest else {
            throw ScenarioAuthoringError.staleDeclaration
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.id == identity.id,
              catalog.version == identity.version,
              !catalog.actions.isEmpty,
              Set(catalog.actions.map(\.id)).count == catalog.actions.count,
              Set(catalog.resultProjections.map(\.id)).count == catalog.resultProjections.count,
              Set(catalog.observers.map(\.id)).count == catalog.observers.count,
              (catalog.localFeatureControls ?? []).isEmpty
                  || catalog.capabilities.contains("local-feature-controls"),
              Set((catalog.localFeatureControls ?? []).map {
                  "\($0.featureID):\($0.operationID)"
              }).count == (catalog.localFeatureControls ?? []).count,
              catalog.actions.allSatisfy({ !$0.id.isEmpty && Set($0.parameters.map(\.name)).count == $0.parameters.count }) else {
            throw ScenarioAuthoringError.invalidDeclaration
        }
        return catalog
    }
}

enum ScenarioAuthoringError: LocalizedError {
    case staleDeclaration
    case invalidDeclaration
    case missingAction
    case existingChecks
    case missingProjection
    case missingObserver
    case incompatibleValue
    case duplicateCheck
    case missingCheck
    case missingFeature
    case missingLocalFeatureControl

    var errorDescription: String? {
        switch self {
        case .staleDeclaration: "Rebuild and check support. The compiled declaration changed."
        case .invalidDeclaration: "The compiled integration declaration has duplicate or invalid action fields."
        case .missingAction: "Choose an action declared by the connected app."
        case .existingChecks: "Remove this action's checks before choosing a different action."
        case .missingProjection: "Add a result projection to the app's integration, then rebuild and check support."
        case .missingObserver: "Implement this observer in the app's test integration, then rebuild and check support."
        case .incompatibleValue: "The expected value does not match the declared observation type."
        case .duplicateCheck: "This observation already has a check. Edit that check instead."
        case .missingCheck: "The selected check is no longer in this scenario."
        case .missingFeature: "Choose a connected App Feature before checking its response."
        case .missingLocalFeatureControl: "The checked app has no matching local Feature control. Rebuild and check support."
        }
    }
}

/// Works on a copy and returns a whole new definition. A failed operation
/// cannot leave an assertion without its projection/observation/claim.
enum ScenarioExpectationAuthoring {
    static func withDeclaredIntentActionRequirements(
        _ definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              catalog.actions.contains(where: { $0.id == definition.directControl.intentIdentifier }) else {
            throw ScenarioAuthoringError.missingAction
        }
        let parameters = Dictionary(uniqueKeysWithValues: definition.directControl.parameters.compactMap {
            parameter -> (String, ScenarioValue)? in
            guard case .value(let value) = parameter.presence else { return nil }
            return (parameter.name, value)
        })
        var requirements = (definition.actionRequirements ?? []).filter {
            $0.lane == .appFeature && definition.coverage.appFeature != .notApplicable
        }
        for lane in [ScenarioLane.intentIntegration, .siri]
        where definition.coverage[lane] != .notApplicable {
            requirements.append(.init(
                lane: lane, kind: .productionIntent,
                operationID: definition.directControl.intentIdentifier,
                resolvedParameters: parameters
            ))
        }
        var copy = definition
        if copy.actionRequirements != requirements || copy.actionPolicyVersion != 1 {
            copy.actionRequirements = requirements
            copy.actionPolicyVersion = 1
            copy.definitionDigest = ""
            copy.testContractDigest = nil
        }
        return copy
    }

    static func selectingLocalFeatureControl(
        featureID: String,
        operationID: String,
        inputMapping: [ScenarioFeatureInputMapping],
        in definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard catalog.capabilities.contains("local-feature-controls"),
              let control = (catalog.localFeatureControls ?? []).first(where: {
                  $0.featureID == featureID && $0.operationID == operationID
              }),
              !control.testIntentIdentifier.isEmpty,
              Set(inputMapping.map(\.featureInputName)).count == inputMapping.count,
              inputMapping.allSatisfy({ input in
                  control.parameters.contains { $0.name == input.featureInputName }
              }) else { throw ScenarioAuthoringError.missingLocalFeatureControl }
        let binding = ScenarioFeatureBinding(
            featureID: control.featureID,
            interfaceDigest: control.interfaceDigest,
            inputMapping: inputMapping,
            outputProjections: control.outputProjections.map {
                .init(name: $0.id, type: $0.type, path: $0.path)
            }
        )
        var copy = definition
        copy.featureBinding = binding
        copy.coverage.appFeature = .required
        var requirements = copy.actionRequirements ?? []
        requirements.removeAll { $0.lane == .appFeature }
        requirements.append(.init(
            lane: .appFeature, kind: .productionService, operationID: operationID,
            resolvedParameters: Dictionary(uniqueKeysWithValues: inputMapping.map {
                ($0.featureInputName, $0.value)
            })
        ))
        copy.actionRequirements = requirements
        copy.actionPolicyVersion = 1
        if var observations = copy.observationPlan,
           let index = observations.firstIndex(where: { $0.id == "feature.response" }) {
            observations[index].source = .testOnlyIntent
            observations[index].operationID = operationID
            copy.observationPlan = observations
        }
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func addingFeatureResponseCheck(
        expected: ScenarioValue,
        semantic: Bool,
        rubric: String,
        to definition: ScenarioDefinition
    ) throws -> ScenarioDefinition {
        guard definition.featureBinding != nil else { throw ScenarioAuthoringError.missingFeature }
        guard case .string = expected else { throw ScenarioAuthoringError.incompatibleValue }
        guard !definition.assertions.contains(where: {
            $0.observationKey == "feature.response" && $0.applies(to: .appFeature)
        }) else { throw ScenarioAuthoringError.duplicateCheck }
        guard !semantic || !rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScenarioAuthoringError.incompatibleValue
        }
        var copy = definition
        var observations = copy.observationPlan ?? []
        guard !observations.contains(where: { $0.id == "feature.response" }) else {
            throw ScenarioAuthoringError.duplicateCheck
        }
        let operationID = copy.actionRequirements?.first(where: {
            $0.lane == .appFeature && $0.kind == .productionService
        })?.operationID
        observations.append(.init(id: "feature.response", source: .testOnlyIntent,
                                  operationID: operationID, selector: nil))
        copy.observationPlan = observations
        copy.assertions.append(.init(
            kind: semantic ? .semanticRubric : .returnedField,
            observationKey: "feature.response", expectedValue: expected,
            explanation: semantic ? rubric : "Check the captured App Feature response.",
            applicableLanes: [.appFeature]
        ))
        if !semantic {
            var claims = copy.requiredClaims ?? [.executionCompleted]
            if !claims.contains(.returnedValueChecked) { claims.append(.returnedValueChecked) }
            copy.requiredClaims = claims
        }
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func selectingAction(
        _ actionID: String,
        in definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard let action = catalog.actions.first(where: { $0.id == actionID }) else {
            throw ScenarioAuthoringError.missingAction
        }
        if definition.directControl.intentIdentifier != actionID && !definition.assertions.isEmpty {
            throw ScenarioAuthoringError.existingChecks
        }
        var copy = definition
        copy.directControl.intentIdentifier = action.id
        copy.directControl.parameters = action.parameters.map {
            .init(name: $0.name, type: $0.type, isOptional: !$0.required, presence: .missing)
        }
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func addingReturnedCheck(
        projectionID: String,
        expected: ScenarioValue,
        lanes: Set<ScenarioLane>,
        to definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard let projection = catalog.resultProjections.first(where: { $0.id == projectionID }) else {
            throw ScenarioAuthoringError.missingProjection
        }
        guard ScenarioValidator.validate(value: expected, as: projection.type).isEmpty else {
            throw ScenarioAuthoringError.incompatibleValue
        }
        guard !definition.assertions.contains(where: { $0.observationKey == projectionID }) else {
            throw ScenarioAuthoringError.duplicateCheck
        }
        var copy = definition
        copy.directControl.outputFields.append(.init(
            name: projection.id, type: projection.type, path: projection.path
        ))
        var observations = copy.observationPlan ?? []
        observations.append(.init(id: projection.id, source: .intentResult, operationID: nil, selector: nil))
        copy.observationPlan = observations
        copy.assertions.append(.init(kind: .returnedField, observationKey: projection.id,
                                     expectedValue: expected, explanation: "Check returned \(projection.id).",
                                     applicableLanes: lanes))
        var claims = copy.requiredClaims ?? [.executionCompleted]
        if !claims.contains(.returnedValueChecked) { claims.append(.returnedValueChecked) }
        copy.requiredClaims = claims
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func addingStateCheck(
        observerID: String,
        kind: ScenarioAssertionKind,
        expected: ScenarioValue,
        lanes: Set<ScenarioLane>,
        to definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard let observer = catalog.observers.first(where: { $0.id == observerID }),
              observer.source.checksApplicationState else {
            throw ScenarioAuthoringError.missingObserver
        }
        guard ScenarioValidator.validate(value: expected, as: observer.type).isEmpty else {
            throw ScenarioAuthoringError.incompatibleValue
        }
        guard !definition.assertions.contains(where: { $0.observationKey == observerID }) else {
            throw ScenarioAuthoringError.duplicateCheck
        }
        var copy = definition
        var observations = copy.observationPlan ?? []
        observations.append(.init(id: observer.id, source: observer.source,
                                  operationID: observer.operationID, selector: observer.selector))
        copy.observationPlan = observations
        copy.assertions.append(.init(kind: kind, observationKey: observer.id,
                                     expectedValue: expected, explanation: "Check app state \(observer.id).",
                                     applicableLanes: lanes))
        copy.checkMode = .behaviour
        var claims = copy.requiredClaims ?? [.executionCompleted]
        if !claims.contains(.applicationStateChecked) { claims.append(.applicationStateChecked) }
        copy.requiredClaims = claims
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func updatingCheck(
        _ assertionID: UUID,
        expected: ScenarioValue,
        in definition: ScenarioDefinition,
        catalog: ScenarioIntegrationCatalog
    ) throws -> ScenarioDefinition {
        guard let index = definition.assertions.firstIndex(where: { $0.id == assertionID }) else {
            throw ScenarioAuthoringError.missingCheck
        }
        let key = definition.assertions[index].observationKey
        let declaredType = key == "feature.response" && definition.assertions[index].applies(to: .appFeature)
            ? .primitive(.string)
            : (catalog.resultProjections.first(where: { $0.id == key })?.type
                ?? catalog.observers.first(where: { $0.id == key })?.type)
        guard let declaredType, ScenarioValidator.validate(value: expected, as: declaredType).isEmpty else {
            throw ScenarioAuthoringError.incompatibleValue
        }
        var copy = definition
        copy.assertions[index].expectedValue = expected
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }

    static func removingCheck(_ assertionID: UUID, from definition: ScenarioDefinition) throws -> ScenarioDefinition {
        guard let removed = definition.assertions.first(where: { $0.id == assertionID }) else {
            throw ScenarioAuthoringError.missingCheck
        }
        var copy = definition
        copy.assertions.removeAll { $0.id == assertionID }
        if !copy.assertions.contains(where: { $0.observationKey == removed.observationKey }) {
            copy.directControl.outputFields.removeAll { $0.name == removed.observationKey }
            copy.observationPlan?.removeAll { $0.id == removed.observationKey }
        }
        if !copy.assertions.contains(where: { $0.kind == .returnedField }) {
            copy.requiredClaims?.removeAll { $0 == .returnedValueChecked }
        }
        if !copy.assertions.contains(where: { $0.kind == .stateTransition || $0.kind == .noMutation }) {
            copy.requiredClaims?.removeAll { $0 == .applicationStateChecked }
            copy.checkMode = .basic
        }
        copy.definitionDigest = ""
        copy.testContractDigest = nil
        return copy
    }
}
