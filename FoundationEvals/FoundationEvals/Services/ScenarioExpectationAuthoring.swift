import Foundation
import CryptoKit

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

    var schemaVersion: Int
    var id: String
    var version: String
    var targetBundleIdentifier: String
    var actions: [Action]
    var resultProjections: [Projection]
    var observers: [Observer]
    var preparationOperations: [String]
    var capabilities: [String]

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
        }
    }
}

/// Works on a copy and returns a whole new definition. A failed operation
/// cannot leave an assertion without its projection/observation/claim.
enum ScenarioExpectationAuthoring {
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
        copy.assertions.append(.init(
            kind: semantic ? .semanticRubric : .returnedField,
            observationKey: "feature.response", expectedValue: expected,
            explanation: semantic ? rubric : "Check the captured App Feature response.",
            applicableLanes: [.appFeature]
        ))
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
