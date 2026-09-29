import Foundation

public enum IntentLabLane: String, Codable { case appFeature, intentIntegration, siri }
public enum IntentLabLaneRequirement: String, Codable { case required, optional, notApplicable }
public enum IntentLabExecutionStatus: String, Codable { case completed, blockedByEnvironment, timedOut, cancelled, crashed, failedToBuild, invalidEvidence }
public enum IntentLabOutcome: String, Codable { case passed, failed, needsReview, notObserved, notApplicable }

public indirect enum IntentLabValue: Codable, Equatable {
    case null
    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case date(IntentLabDateValue)
    case enumeration(IntentLabEnumValue)
    case entity(IntentLabEntityValue)
    case array([IntentLabValue])
}

public struct IntentLabDateValue: Codable, Equatable {
    public var source: String
    public var timeZoneIdentifier: String
    public var resolvedInstant: Date
    public init(source: String, timeZoneIdentifier: String, resolvedInstant: Date) {
        self.source = source
        self.timeZoneIdentifier = timeZoneIdentifier
        self.resolvedInstant = resolvedInstant
    }
}

public struct IntentLabEnumValue: Codable, Equatable {
    public var typeIdentifier: String
    public var caseIdentifier: String
    public init(typeIdentifier: String, caseIdentifier: String) {
        self.typeIdentifier = typeIdentifier
        self.caseIdentifier = caseIdentifier
    }
}

public struct IntentLabEntityValue: Codable, Equatable {
    public var typeIdentifier: String
    public var identifier: String
    public init(typeIdentifier: String, identifier: String) {
        self.typeIdentifier = typeIdentifier
        self.identifier = identifier
    }
}

public indirect enum IntentLabValueType: Codable, Equatable {
    case primitive(IntentLabPrimitiveType)
    case enumeration(typeIdentifier: String, allowedCases: [String])
    case entity(typeIdentifier: String)
    case array(element: IntentLabValueType)
}

public extension IntentLabValueType {
    func accepts(_ value: IntentLabValue) -> Bool {
        if case .null = value { return true }
        switch (self, value) {
        case (.primitive(.string), .string), (.primitive(.boolean), .boolean),
             (.primitive(.integer), .integer), (.primitive(.date), .date):
            return true
        case (.primitive(.number), .number(let number)):
            return number.isFinite
        case (.enumeration(let identifier, let cases), .enumeration(let value)):
            return value.typeIdentifier == identifier && cases.contains(value.caseIdentifier)
        case (.entity(let identifier), .entity(let value)):
            return value.typeIdentifier == identifier && !value.identifier.isEmpty
        case (.array(let element), .array(let values)):
            return values.allSatisfy { element.accepts($0) }
        default:
            return false
        }
    }
}

public enum IntentLabPrimitiveType: String, Codable { case string, boolean, integer, number, date }
public enum IntentLabPresence: Codable { case missing, value(IntentLabValue) }

public struct IntentLabParameter: Codable {
    public var name: String
    public var type: IntentLabValueType
    public var isOptional: Bool
    public var presence: IntentLabPresence

    public init(name: String, type: IntentLabValueType, isOptional: Bool, presence: IntentLabPresence) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
        self.presence = presence
    }
}

public struct IntentLabProjectionPathComponent: Codable, Equatable {
    public enum Kind: String, Codable { case property, index, count }
    public var kind: Kind
    public var name: String?
    public var index: Int?

    public init(kind: Kind, name: String? = nil, index: Int? = nil) {
        self.kind = kind
        self.name = name
        self.index = index
    }
}
public struct IntentLabOutputField: Codable {
    public var name: String
    public var type: IntentLabValueType
    public var displayName: String?
    public var path: [IntentLabProjectionPathComponent]?

    public init(
        name: String,
        type: IntentLabValueType,
        displayName: String? = nil,
        path: [IntentLabProjectionPathComponent]? = nil
    ) {
        self.name = name
        self.type = type
        self.displayName = displayName
        self.path = path
    }
}
public enum IntentLabPurpose: String, Codable { case exploratory, releaseRequirement }
public enum IntentLabCheckMode: String, Codable { case basic, behaviour }
public enum IntentLabProofClaim: String, Codable {
    case executionCompleted, returnedValueChecked, applicationStateChecked
}
public enum IntentLabObservationSource: String, Codable {
    case intentResult, entityQuery, valueQuery, uiElement, testOnlyIntent
}
public struct IntentLabPlannedObservation: Codable {
    public var id: String
    public var source: IntentLabObservationSource
    public var operationID: String?
    public var selector: String?
}
public struct IntentLabIntegrationIdentity: Codable, Equatable {
    public var id: String
    public var version: String
    public var digest: String
    public init(id: String, version: String, digest: String) {
        self.id = id
        self.version = version
        self.digest = digest
    }
}
public struct IntentLabDirectControl: Codable {
    public var intentIdentifier: String
    public var parameters: [IntentLabParameter]
    public var outputFields: [IntentLabOutputField]
}
public struct IntentLabTarget: Codable { public var bundleIdentifier: String }
public struct IntentLabGoal: Codable { public var requestText: String; public var languageCode: String }
public struct IntentLabFixture: Codable { public var id: String; public var version: String; public var digest: String; public var preparationOperation: String; public var cleanupOperation: String }
public enum IntentLabAssertionKind: String, Codable {
    case entityIdentifier, returnedField, visibleText, stateTransition, noMutation, semanticRubric
}
public struct IntentLabAssertion: Codable {
    public var id: UUID
    public var kind: IntentLabAssertionKind
    public var observationKey: String
    public var expectedValue: IntentLabValue?
    public var required: Bool
    public var applicableLanes: Set<IntentLabLane>?
    public init(
        id: UUID, kind: IntentLabAssertionKind, observationKey: String,
        expectedValue: IntentLabValue?, required: Bool, applicableLanes: Set<IntentLabLane>?
    ) {
        self.id = id
        self.kind = kind
        self.observationKey = observationKey
        self.expectedValue = expectedValue
        self.required = required
        self.applicableLanes = applicableLanes
    }
}
public enum IntentLabMutationPolicy: String, Codable { case readOnly, syntheticMutation }
public struct IntentLabSafety: Codable {
    public var deadlineSeconds: Double
    public var mutationPolicy: IntentLabMutationPolicy?
}
public struct IntentLabCoverage: Codable {
    public var appFeature: IntentLabLaneRequirement
    public var intentIntegration: IntentLabLaneRequirement
    public var siri: IntentLabLaneRequirement
    public var siriAttemptCount: Int?
}

/// Host-selected native coordinate. Absence retains the historical all-routes
/// invocation; a selected coordinate executes in its own XCTest invocation.
public struct IntentLabExecutionScope: Codable {
    public var lane: IntentLabLane
    public var attempt: Int

    public init(lane: IntentLabLane, attempt: Int) {
        self.lane = lane
        self.attempt = attempt
    }
}

/// The frozen logical feature contract for a project-local native feature run.
/// The consumer's compiled integration declaration resolves this identity to a
/// test-only App Intent; scenario values never name executable code directly.
public struct IntentLabFeatureBinding: Codable {
    public var featureID: String
    public var interfaceDigest: String
    public var inputMapping: [InputMapping]
    public var outputProjections: [IntentLabOutputField]

    public struct InputMapping: Codable {
        public var featureInputName: String
        public var value: IntentLabValue

        public init(featureInputName: String, value: IntentLabValue) {
            self.featureInputName = featureInputName
            self.value = value
        }
    }

    public init(
        featureID: String,
        interfaceDigest: String,
        inputMapping: [InputMapping],
        outputProjections: [IntentLabOutputField]
    ) {
        self.featureID = featureID
        self.interfaceDigest = interfaceDigest
        self.inputMapping = inputMapping
        self.outputProjections = outputProjections
    }
}

public enum IntentLabActionKind: String, Codable { case productionIntent, productionService, testSupport }
public enum IntentLabActionTerminalStatus: String, Codable { case succeeded, failed }
public enum IntentLabActionFailureReason: String, Codable {
    case missingActionEvidence, staleActionEvidence, wrongAction, wrongParameter, wrongOutcome,
         unexpectedExecution, operationError, invalidActionEvidence
}

public struct IntentLabActionRequirement: Codable {
    public var lane: IntentLabLane
    public var kind: IntentLabActionKind
    public var operationID: String
    public var resolvedParameters: [String: IntentLabValue]
    public var allowedExecutionCount: Int
    public init(lane: IntentLabLane, kind: IntentLabActionKind, operationID: String,
                resolvedParameters: [String: IntentLabValue], allowedExecutionCount: Int = 1) {
        self.lane = lane
        self.kind = kind
        self.operationID = operationID
        self.resolvedParameters = resolvedParameters
        self.allowedExecutionCount = allowedExecutionCount
    }
}

public struct IntentLabActionReceipt: Codable {
    public var executionID: UUID
    public var appSessionID: UUID
    public var attemptContext: String
    public var lane: IntentLabLane
    public var attempt: Int
    public var kind: IntentLabActionKind
    public var operationID: String
    public var resolvedParameters: [String: IntentLabValue]
    public var terminalStatus: IntentLabActionTerminalStatus
    public var operationError: String?
    public var sequence: Int
    public var startedAt: Date
    public var completedAt: Date
    public var observationTransport: String
    public var isTopLevel: Bool
    public init(executionID: UUID, appSessionID: UUID, attemptContext: String,
                lane: IntentLabLane, attempt: Int, kind: IntentLabActionKind,
                operationID: String, resolvedParameters: [String: IntentLabValue],
                terminalStatus: IntentLabActionTerminalStatus, operationError: String?,
                sequence: Int, startedAt: Date, completedAt: Date,
                observationTransport: String, isTopLevel: Bool = true) {
        self.executionID = executionID
        self.appSessionID = appSessionID
        self.attemptContext = attemptContext
        self.lane = lane
        self.attempt = attempt
        self.kind = kind
        self.operationID = operationID
        self.resolvedParameters = resolvedParameters
        self.terminalStatus = terminalStatus
        self.operationError = operationError
        self.sequence = sequence
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observationTransport = observationTransport
        self.isTopLevel = isTopLevel
    }
}

public struct IntentLabScenario: Codable {
    public var schemaVersion: Int? = 1
    public var id: UUID
    public var version: Int
    public var definitionDigest: String
    public var target: IntentLabTarget
    public var goal: IntentLabGoal
    public var fixture: IntentLabFixture
    public var directControl: IntentLabDirectControl
    public var assertions: [IntentLabAssertion]
    public var coverage: IntentLabCoverage
    public var safety: IntentLabSafety
    public var purpose: IntentLabPurpose?
    public var checkMode: IntentLabCheckMode?
    public var requiredClaims: [IntentLabProofClaim]?
    public var observationPlan: [IntentLabPlannedObservation]?
    public var integration: IntentLabIntegrationIdentity?
    public var executionScope: IntentLabExecutionScope?
    public var featureBinding: IntentLabFeatureBinding?
    public var actionRequirements: [IntentLabActionRequirement]?
    public var actionPolicyVersion: Int?

    public func validateContract(harnessVersion: String) throws {
        switch schemaVersion ?? 1 {
        case 1:
            guard harnessVersion == "intent-lab-v1" else { throw IntentLabPayloadError.unsupportedSchema }
        case 2:
            guard harnessVersion == "intent-lab-v2", purpose != nil, checkMode != nil,
                  let requiredClaims, let observationPlan, let integration,
                  requiredClaims.contains(.executionCompleted),
                  Set(requiredClaims.map(\.rawValue)).count == requiredClaims.count,
                  Set(observationPlan.map(\.id)).count == observationPlan.count,
                  observationPlan.allSatisfy({ !$0.id.isEmpty }),
                  Set(directControl.outputFields.map(\.name)).isDisjoint(
                    with: observationPlan.filter({ $0.source != .intentResult }).map(\.id)
                  ),
                  !integration.id.isEmpty, !integration.version.isEmpty,
                  integration.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  (coverage.siri == .notApplicable || !goal.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                throw IntentLabPayloadError.unsupportedSchema
            }
            if checkMode == .behaviour && (!requiredClaims.contains(.applicationStateChecked)
                || !observationPlan.contains(where: { $0.source != .intentResult })) {
                throw IntentLabPayloadError.unsupportedSchema
            }
            if safety.mutationPolicy == .syntheticMutation,
               ["", "none", "noop", "readOnly"].contains(fixture.cleanupOperation) {
                throw IntentLabPayloadError.unsupportedSchema
            }
            if let executionScope {
                switch executionScope.lane {
                case .appFeature:
                    guard executionScope.attempt == 1,
                          coverage.appFeature != .notApplicable,
                          featureBinding != nil,
                          let actionRequirements,
                          actionRequirements.filter({ $0.lane == .appFeature }).count == 1,
                          actionRequirements.first(where: { $0.lane == .appFeature })?.kind
                            == .productionService else {
                        throw IntentLabPayloadError.unsupportedSchema
                    }
                case .intentIntegration:
                    guard executionScope.attempt == 1,
                          coverage.intentIntegration != .notApplicable else {
                        throw IntentLabPayloadError.unsupportedSchema
                    }
                case .siri:
                    let attemptCount = coverage.siriAttemptCount ?? 3
                    guard coverage.siri != .notApplicable,
                          (1...3).contains(attemptCount),
                          (1...attemptCount).contains(executionScope.attempt) else {
                        throw IntentLabPayloadError.unsupportedSchema
                    }
                }
            }
            if let featureBinding {
                guard !featureBinding.featureID.isEmpty,
                      featureBinding.interfaceDigest.range(
                        of: "^[0-9a-f]{64}$", options: .regularExpression
                      ) != nil,
                      Set(featureBinding.inputMapping.map(\.featureInputName)).count
                        == featureBinding.inputMapping.count,
                      featureBinding.inputMapping.allSatisfy({ !$0.featureInputName.isEmpty }),
                      Set(featureBinding.outputProjections.map(\.name)).count
                        == featureBinding.outputProjections.count,
                      featureBinding.outputProjections.allSatisfy({
                          !$0.name.isEmpty && $0.name != "feature.response"
                              && $0.name != "intentlab.actionReceipts"
                      }) else {
                    throw IntentLabPayloadError.unsupportedSchema
                }
            } else if executionScope?.lane == .appFeature {
                throw IntentLabPayloadError.unsupportedSchema
            }
            if let actionRequirements {
                guard actionPolicyVersion == 1, !actionRequirements.isEmpty,
                      Set(actionRequirements.map(\.lane.rawValue)).count == actionRequirements.count,
                      actionRequirements.allSatisfy({ requirement in
                          requirement.allowedExecutionCount == 1 && !requirement.operationID.isEmpty
                              && requirement.operationID.count <= 128
                              && (requirement.lane == .appFeature
                                  ? requirement.kind == .productionService
                                  : requirement.kind == .productionIntent)
                      }) else { throw IntentLabPayloadError.unsupportedSchema }
            } else if actionPolicyVersion != nil {
                throw IntentLabPayloadError.unsupportedSchema
            }
        default:
            throw IntentLabPayloadError.unsupportedSchema
        }
    }
}

public enum IntentLabPayloadError: LocalizedError {
    case partialEnvironment
    case malformedBase64(String)
    case oversized(Int)
    case unsupportedSchema

    public var errorDescription: String? {
        switch self {
        case .partialEnvironment:
            "Intent Lab received only part of its invocation environment."
        case .malformedBase64(let name):
            "Intent Lab could not decode the \(name) environment payload."
        case .oversized(let bytes):
            "Intent Lab rejected an oversized \(bytes)-byte invocation payload."
        case .unsupportedSchema:
            "Intent Lab rejected an unsupported scenario schema."
        }
    }
}

public enum IntentLabPayloadLoader {
    public static let scenarioKey = "FOUNDATION_EVALS_INTENT_LAB_SCENARIO_B64"
    public static let invocationKey = "FOUNDATION_EVALS_INTENT_LAB_INVOCATION_B64"
    public static let maximumPayloadBytes = 256 * 1_024

    public static func environmentData(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Data? {
        let scenario = environment[scenarioKey]
        let invocation = environment[invocationKey]
        guard (scenario == nil) == (invocation == nil) else {
            throw IntentLabPayloadError.partialEnvironment
        }
        guard let scenario, let invocation else { return nil }
        guard let scenarioData = Data(base64Encoded: scenario) else {
            throw IntentLabPayloadError.malformedBase64("scenario")
        }
        guard let invocationData = Data(base64Encoded: invocation) else {
            throw IntentLabPayloadError.malformedBase64("invocation")
        }
        let byteCount = scenarioData.count + invocationData.count
        guard byteCount <= maximumPayloadBytes else {
            throw IntentLabPayloadError.oversized(byteCount)
        }
        switch name {
        case "IntentLabScenario": return scenarioData
        case "IntentLabInvocation": return invocationData
        default: return nil
        }
    }
}

public struct IntentLabProductIdentity: Codable, Equatable {
    public var bundleIdentifier: String
    public var executableName: String
    public var sha256: String
}
public struct IntentLabTestIdentity: Codable, Equatable { public var bundleIdentifier: String; public var className: String; public var methodName: String }
public struct IntentLabInvocation: Codable {
    public var id: UUID
    public var nonce: String
    public var issuedAt: Date
    public var testIdentity: IntentLabTestIdentity
    public var harnessVersion: String
    public var destinationIdentifier: String
    public var scenarioDigest: String
    public var resultBundleIdentity: String
    public var appProduct: IntentLabProductIdentity?
    public var testProduct: IntentLabProductIdentity?
    public var integration: IntentLabIntegrationIdentity?
    public var requiredCapabilities: [String]?
    public var featureBackend: String?
}

public struct IntentLabAssertionResult: Codable {
    public var id = UUID()
    public var assertionID: UUID
    public var passed: Bool
    public var observedValue: IntentLabValue?
    public var message: String
    public init(assertionID: UUID, passed: Bool, observedValue: IntentLabValue?, message: String) {
        self.assertionID = assertionID
        self.passed = passed
        self.observedValue = observedValue
        self.message = message
    }
}

public struct IntentLabArtifactReference: Codable {
    public var id: UUID
    public var kind: String
    public var filename: String
    public var relativePath: String
    public var contentType: String
    public var byteCount: Int
    public var sha256: String
    public var manuallySupplied: Bool
    public init(id: UUID, kind: String, filename: String, relativePath: String, contentType: String, byteCount: Int, sha256: String, manuallySupplied: Bool) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.relativePath = relativePath
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.manuallySupplied = manuallySupplied
    }
}

public struct IntentLabLaneResult: Codable {
    public var id = UUID()
    public var caseID: UUID
    public var attempt: Int
    public var lane: IntentLabLane
    public var executionStatus: IntentLabExecutionStatus
    public var outcome: IntentLabOutcome
    public var startedAt: Date
    public var completedAt: Date
    public var observations: [String: IntentLabValue]
    /// Scoped executions retain the typed state observed before the action.
    public var beforeObservations: [String: IntentLabValue]? = nil
    public var assertionResults: [IntentLabAssertionResult]
    public var diagnostic: String?
    public var proposedCause: String?
    public var artifacts: [IntentLabArtifactReference]
    public var observationSources: [String: String]? = nil
    public var claims: [IntentLabProofClaim]? = nil
    public var actionReceipts: [IntentLabActionReceipt]? = nil
    public var actionFailureReason: IntentLabActionFailureReason? = nil
    public var cleanupVerified: Bool? = nil
    public init(caseID: UUID, attempt: Int, lane: IntentLabLane, executionStatus: IntentLabExecutionStatus, outcome: IntentLabOutcome, startedAt: Date, completedAt: Date, observations: [String: IntentLabValue], assertionResults: [IntentLabAssertionResult], diagnostic: String?, proposedCause: String?, artifacts: [IntentLabArtifactReference], observationSources: [String: String]? = nil, claims: [IntentLabProofClaim]? = nil, beforeObservations: [String: IntentLabValue]? = nil, actionReceipts: [IntentLabActionReceipt]? = nil, actionFailureReason: IntentLabActionFailureReason? = nil, cleanupVerified: Bool? = nil) {
        self.caseID = caseID
        self.attempt = attempt
        self.lane = lane
        self.executionStatus = executionStatus
        self.outcome = outcome
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observations = observations
        self.beforeObservations = beforeObservations
        self.assertionResults = assertionResults
        self.diagnostic = diagnostic
        self.proposedCause = proposedCause
        self.artifacts = artifacts
        self.observationSources = observationSources
        self.claims = claims
        self.actionReceipts = actionReceipts
        self.actionFailureReason = actionFailureReason
        self.cleanupVerified = cleanupVerified
    }
}

public struct IntentLabEnvironment: Codable {
    public var xcodeVersion: String
    public var sdkVersion: String
    public var deviceModel: String
    public var operatingSystem: String
    public var operatingSystemBuild: String?
    public var languageCode: String
    public var regionCode: String
    public var timeZoneIdentifier: String
    public var siriConfiguration: String?
    public var siriConfigurationSource: String?
    public var executedAt: Date
    public init(xcodeVersion: String, sdkVersion: String, deviceModel: String, operatingSystem: String, operatingSystemBuild: String?, languageCode: String, regionCode: String, timeZoneIdentifier: String, siriConfiguration: String?, siriConfigurationSource: String?, executedAt: Date) {
        self.xcodeVersion = xcodeVersion
        self.sdkVersion = sdkVersion
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.operatingSystemBuild = operatingSystemBuild
        self.languageCode = languageCode
        self.regionCode = regionCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.siriConfiguration = siriConfiguration
        self.siriConfigurationSource = siriConfigurationSource
        self.executedAt = executedAt
    }
}

public struct IntentLabEvidenceEnvelope: Codable {
    public var schemaVersion = 1
    public var invocation: IntentLabInvocation
    public var sourceBundleIdentifier: String
    public var observedAppProduct: IntentLabProductIdentity
    public var observedTestProduct: IntentLabProductIdentity
    public var environment: IntentLabEnvironment
    public var testCount: Int
    public var results: [IntentLabLaneResult]
    public var integration: IntentLabIntegrationIdentity?
    public var runnerPackageVersion: String?
    public var negotiatedCapabilities: [String]?
    public init(schemaVersion: Int, invocation: IntentLabInvocation, sourceBundleIdentifier: String, observedAppProduct: IntentLabProductIdentity, observedTestProduct: IntentLabProductIdentity, environment: IntentLabEnvironment, testCount: Int, results: [IntentLabLaneResult], integration: IntentLabIntegrationIdentity? = nil, runnerPackageVersion: String? = nil, negotiatedCapabilities: [String]? = nil) {
        self.schemaVersion = schemaVersion
        self.invocation = invocation
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.observedAppProduct = observedAppProduct
        self.observedTestProduct = observedTestProduct
        self.environment = environment
        self.testCount = testCount
        self.results = results
        self.integration = integration
        self.runnerPackageVersion = runnerPackageVersion
        self.negotiatedCapabilities = negotiatedCapabilities
    }
}

public extension JSONDecoder {
    static var intentLab: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

public extension JSONEncoder {
    static var intentLab: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
}
