import Foundation

/// Portable, reviewable configuration. Operation IDs resolve only to compiled consumer code.
public struct IntentLabIntegrationDeclaration: Codable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var targetBundleIdentifier: String
    public var projectIdentity: String
    public var targetIdentity: String
    public var supportedHarnessProtocols: [String]
    public var actions: [Action]
    public var resultProjections: [Projection]
    public var preparationOperations: [String]
    public var observers: [Observer]
    public var queryOperations: [QueryOperation]?
    public var isolation: Isolation
    public var capabilities: [String]

    public struct Action: Codable {
        public var id: String
        public var parameters: [Parameter]
    }
    public struct Parameter: Codable {
        public var name: String
        public var type: IntentLabValueType
        public var required: Bool
    }
    public struct Projection: Codable {
        public var id: String
        public var type: IntentLabValueType
        public var path: [IntentLabProjectionPathComponent]
    }
    public struct Observer: Codable {
        public var id: String
        public var source: IntentLabObservationSource
        public var type: IntentLabValueType
        public var operationID: String?
        public var selector: String?
    }
    public struct Isolation: Codable {
        public var kind: String
        public var readinessOperationID: String?
    }
    public struct QueryOperation: Codable {
        public var id: String
        public var source: IntentLabObservationSource
        /// Entity type identifier or value-query identifier from IntentDefinitions.
        public var typeIdentifier: String
        public var identifiers: [String]?
        public var input: IntentLabValue?
    }

    public func validate() throws {
        let operations = queryOperations ?? []
        guard schemaVersion == 1, !id.isEmpty, !version.isEmpty,
              !targetBundleIdentifier.isEmpty, !projectIdentity.isEmpty, !targetIdentity.isEmpty,
              supportedHarnessProtocols.contains("intent-lab-v2"),
              Set(actions.map(\.id)).count == actions.count,
              Set(observers.map(\.id)).count == observers.count,
              observers.allSatisfy({ !$0.id.isEmpty }),
              Set(operations.map(\.id)).count == operations.count,
              operations.allSatisfy({ operation in
                  !operation.id.isEmpty && !operation.typeIdentifier.isEmpty
                    && (operation.source == .entityQuery || operation.source == .valueQuery)
                    && (operation.source == .entityQuery
                        ? !(operation.identifiers ?? []).isEmpty && operation.input == nil
                        : operation.input != nil)
              }),
              observers.filter({ $0.source == .entityQuery || $0.source == .valueQuery }).allSatisfy({ observer in
                  operations.contains(where: { $0.id == observer.operationID && $0.source == observer.source })
              }),
              Set(resultProjections.map(\.id)).count == resultProjections.count,
              Set(capabilities).count == capabilities.count else {
            throw IntentLabDeclarationError.invalid
        }
    }
}

public enum IntentLabDeclarationError: LocalizedError {
    case invalid
    case missing
    case mismatchedIdentity
    case missingCapability(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: "The bundled Intent Lab integration declaration is invalid."
        case .missing: "The UI-test bundle is missing IntentLabIntegration.json."
        case .mismatchedIdentity: "The bundled integration does not match the frozen scenario and invocation."
        case .missingCapability(let name): "The integration does not provide required capability \(name)."
        }
    }
}
