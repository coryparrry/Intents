import Foundation
import CryptoKit

/// Typed business inputs carried through the single string parameter of the
/// app-owned test intent wrapper. The production service still receives only
/// app-declared operations and interprets this payload against its typed contract.
public struct IntentLabLocalFeatureInput: Codable {
    public var featureID: String
    public var interfaceDigest: String
    public var parameters: [IntentLabParameter]

    public init(featureID: String, interfaceDigest: String, parameters: [IntentLabParameter]) {
        self.featureID = featureID
        self.interfaceDigest = interfaceDigest
        self.parameters = parameters
    }
}

private struct CanonicalLocalFeatureInterface: Encodable {
    let featureID: String
    let operationID: String
    let testIntentIdentifier: String
    let parameters: [IntentLabIntegrationDeclaration.Parameter]
    let outputProjections: [IntentLabIntegrationDeclaration.Projection]
}

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
    /// Consumer-compiled cleanup operations. Omission is accepted for older declarations,
    /// but a v2 scenario can only request a listed operation.
    public var cleanupOperations: [String]?
    public var observers: [Observer]
    public var queryOperations: [QueryOperation]?
    /// Project-local feature operations exposed through a test-only intent. Older
    /// schema-1 declarations may omit this registry.
    public var localFeatureControls: [FeatureControl]?
    /// Harmless, zero-business-input app-target support check. Older declarations
    /// may omit it; readiness then requires setup before the check can run.
    public var readinessControl: ReadinessControl?
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

        public init(name: String, type: IntentLabValueType, required: Bool) {
            self.name = name
            self.type = type
            self.required = required
        }
    }
    public struct Projection: Codable {
        public var id: String
        public var type: IntentLabValueType
        public var path: [IntentLabProjectionPathComponent]

        public init(id: String, type: IntentLabValueType, path: [IntentLabProjectionPathComponent]) {
            self.id = id
            self.type = type
            self.path = path
        }
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

    /// A compiled, typed bridge from a project-local production operation to its
    /// test-only App Intent wrapper. The host can negotiate only exact identities.
    public struct FeatureControl: Codable {
        public var featureID: String
        public var interfaceDigest: String
        /// Production service operation handled by the app-owned test support.
        public var operationID: String
        /// App Intent identifier for the test-only transport wrapper.
        public var testIntentIdentifier: String
        public var parameters: [Parameter]
        public var outputProjections: [Projection]

        public init(
            featureID: String,
            interfaceDigest: String,
            operationID: String,
            testIntentIdentifier: String,
            parameters: [Parameter],
            outputProjections: [Projection]
        ) {
            self.featureID = featureID
            self.interfaceDigest = interfaceDigest
            self.operationID = operationID
            self.testIntentIdentifier = testIntentIdentifier
            self.parameters = parameters
            self.outputProjections = outputProjections
        }

        /// SHA-256 of the canonical typed feature interface. JSON object keys are
        /// sorted and slash escaping is disabled; declared array order is retained.
        public static func calculateInterfaceDigest(
            featureID: String,
            operationID: String,
            testIntentIdentifier: String,
            parameters: [Parameter],
            outputProjections: [Projection]
        ) throws -> String {
            let interface = CanonicalLocalFeatureInterface(
                featureID: featureID,
                operationID: operationID,
                testIntentIdentifier: testIntentIdentifier,
                parameters: parameters,
                outputProjections: outputProjections
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(interface)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        public func validate() throws {
            guard IntentLabIntegrationDeclaration.validFeatureControl(self) else {
                throw IntentLabDeclarationError.invalid
            }
        }
    }

    /// An allowlisted, payload-free test intent used only to check app-target
    /// readiness. The fixed operation and intent identifiers prevent this route
    /// from being redirected to a business Feature wrapper.
    public struct ReadinessControl: Codable {
        public static let expectedOperationID = "intentLabReadiness"
        public static let expectedTestIntentIdentifier = "IntentLabReadinessIntent"
        public static let expectedResponseID = "readiness.ready"

        public var operationID: String
        public var testIntentIdentifier: String
        public var response: Projection

        public init(operationID: String, testIntentIdentifier: String, response: Projection) {
            self.operationID = operationID
            self.testIntentIdentifier = testIntentIdentifier
            self.response = response
        }

        public func validate() throws {
            let expectedPath = [
                IntentLabProjectionPathComponent(kind: .property, name: "value"),
                IntentLabProjectionPathComponent(kind: .property, name: "ready"),
            ]
            guard operationID == Self.expectedOperationID,
                  testIntentIdentifier == Self.expectedTestIntentIdentifier,
                  response.id == Self.expectedResponseID,
                  response.type == .primitive(.boolean), response.path.count == expectedPath.count,
                  zip(response.path, expectedPath).allSatisfy({ actual, expected in
                      actual.kind == expected.kind && actual.name == expected.name
                          && actual.index == expected.index
                  }) else {
                throw IntentLabDeclarationError.invalid
            }
        }
    }

    /// Old read-only declarations did not include cleanupOperations. They may
    /// continue to request a no-op, but never an undeclared mutating operation.
    public func allowsCleanupOperation(
        _ operationID: String,
        requiresMutationCleanup: Bool = false
    ) -> Bool {
        let noOps = ["", "none", "noop", "readOnly"]
        if requiresMutationCleanup {
            guard !noOps.contains(operationID), let cleanupOperations else { return false }
            return cleanupOperations.contains(operationID)
        }
        return (cleanupOperations ?? noOps).contains(operationID)
    }

    /// Returns the one app-declared control that exactly matches the frozen local
    /// feature contract. A changed interface digest requires renewed negotiation.
    public func localFeatureControl(
        featureID: String,
        interfaceDigest: String,
        operationID: String
    ) throws -> FeatureControl {
        guard let control = (localFeatureControls ?? []).first(where: {
            $0.featureID == featureID && $0.operationID == operationID
        }) else {
            throw IntentLabDeclarationError.localFeatureControlNotDeclared
        }
        guard control.interfaceDigest == interfaceDigest else {
            throw IntentLabDeclarationError.mismatchedIdentity
        }
        return control
    }

    /// Returns the one declared readiness control. Absence means the app requires
    /// setup before readiness can be checked.
    public func declaredReadinessControl() throws -> ReadinessControl {
        guard let readinessControl else {
            throw IntentLabDeclarationError.readinessControlNotDeclared
        }
        try readinessControl.validate()
        return readinessControl
    }

    public func validate() throws {
        let operations = queryOperations ?? []
        let featureControls = localFeatureControls ?? []
        try readinessControl?.validate()
        let requiresTestOnlyIntent = !featureControls.isEmpty || readinessControl != nil
        guard schemaVersion == 1, !id.isEmpty, !version.isEmpty,
              !targetBundleIdentifier.isEmpty, !projectIdentity.isEmpty, !targetIdentity.isEmpty,
              supportedHarnessProtocols.contains("intent-lab-v2"),
              Set(actions.map(\.id)).count == actions.count,
              Set(observers.map(\.id)).count == observers.count,
              observers.allSatisfy({ !$0.id.isEmpty }),
              Set(operations.map(\.id)).count == operations.count,
              Set(featureControls.map { "\($0.featureID)\u{1f}\($0.operationID)" }).count == featureControls.count,
              featureControls.allSatisfy(Self.validFeatureControl),
              capabilities.contains("local-feature-controls") == !featureControls.isEmpty,
              capabilities.contains("test-only-intent") == requiresTestOnlyIntent,
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
              Set(preparationOperations).count == preparationOperations.count,
              Set(cleanupOperations ?? []).count == (cleanupOperations ?? []).count,
              Set(capabilities).count == capabilities.count else {
            throw IntentLabDeclarationError.invalid
        }
    }

    fileprivate static func validFeatureControl(_ control: FeatureControl) -> Bool {
        let digestIsValid = control.interfaceDigest.range(
            of: "^[0-9a-f]{64}$", options: .regularExpression
        ) != nil
        guard !control.featureID.isEmpty, digestIsValid,
              !control.operationID.isEmpty, !control.testIntentIdentifier.isEmpty,
              Set(control.parameters.map(\.name)).count == control.parameters.count,
              control.parameters.allSatisfy({ !$0.name.isEmpty && supportedProbeType($0.type) }),
              Set(control.outputProjections.map(\.id)).count == control.outputProjections.count,
              !control.outputProjections.contains(where: {
                  $0.id == "feature.response" || $0.id == "intentlab.actionReceipts"
              }),
              control.outputProjections.allSatisfy({ projection in
                  !projection.id.isEmpty && supportedProbeType(projection.type)
                      && projection.path.first?.kind == .property
                      && projection.path.first?.name == "value"
                      && projection.path.enumerated().allSatisfy { position, component in
                          switch component.kind {
                          case .property: return component.name?.isEmpty == false && component.index == nil
                          case .index: return (component.index ?? -1) >= 0 && component.name == nil
                          case .count:
                              return component.index == nil && component.name == nil
                                  && position == projection.path.count - 1
                                  && projection.type == .primitive(.integer)
                          }
                      }
              }),
              let expectedDigest = try? FeatureControl.calculateInterfaceDigest(
                  featureID: control.featureID,
                  operationID: control.operationID,
                  testIntentIdentifier: control.testIntentIdentifier,
                  parameters: control.parameters,
                  outputProjections: control.outputProjections
              ), expectedDigest == control.interfaceDigest else { return false }
        return true
    }

    private static func supportedProbeType(_ type: IntentLabValueType) -> Bool {
        switch type {
        case .primitive:
            return true
        case .enumeration(let identifier, let cases):
            return !identifier.isEmpty && !cases.isEmpty && cases.allSatisfy { !$0.isEmpty }
                && Set(cases).count == cases.count
        case .entity(let identifier):
            return !identifier.isEmpty
        case .array(let element):
            if case .array = element { return false }
            return supportedProbeType(element)
        }
    }
}

public enum IntentLabDeclarationError: LocalizedError {
    case invalid
    case missing
    case mismatchedIdentity
    case localFeatureControlNotDeclared
    case readinessControlNotDeclared
    case missingCapability(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: "The bundled Intent Lab integration declaration is invalid."
        case .missing: "The UI-test bundle is missing IntentLabIntegration.json."
        case .mismatchedIdentity: "The bundled integration does not match the frozen scenario and invocation."
        case .localFeatureControlNotDeclared: "The integration does not declare this local feature operation."
        case .readinessControlNotDeclared: "The integration does not declare a readiness support operation."
        case .missingCapability(let name): "The integration does not provide required capability \(name)."
        }
    }
}
