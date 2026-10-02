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
    enum CodingKeys: String, CodingKey { case source, timeZoneIdentifier, resolvedInstant, resolvedInstantBits }
    public init(source: String, timeZoneIdentifier: String, resolvedInstant: Date) {
        self.source = source; self.timeZoneIdentifier = timeZoneIdentifier; self.resolvedInstant = resolvedInstant
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        resolvedInstant = try values.decode(Date.self, forKey: .resolvedInstant)
        if let text = try values.decodeIfPresent(String.self, forKey: .resolvedInstantBits) {
            guard let bits = UInt64(text, radix: 16), Double(bitPattern: bits).isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .resolvedInstantBits, in: values, debugDescription: "Invalid exact date instant.")
            }
            resolvedInstant = Date(timeIntervalSince1970: Double(bitPattern: bits))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try values.encode(resolvedInstant, forKey: .resolvedInstant)
        try values.encode(String(resolvedInstant.timeIntervalSince1970.bitPattern, radix: 16), forKey: .resolvedInstantBits)
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
}

public struct IntentLabProjectionPathComponent: Codable, Equatable {
    public enum Kind: String, Codable { case property, index, count }
    public var kind: Kind
    public var name: String?
    public var index: Int?
}
public struct IntentLabOutputField: Codable {
    public var name: String
    public var type: IntentLabValueType
    public var displayName: String?
    public var path: [IntentLabProjectionPathComponent]?
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
            if let executionScope {
                switch executionScope.lane {
                case .appFeature:
                    throw IntentLabPayloadError.unsupportedSchema
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
    public init(caseID: UUID, attempt: Int, lane: IntentLabLane, executionStatus: IntentLabExecutionStatus, outcome: IntentLabOutcome, startedAt: Date, completedAt: Date, observations: [String: IntentLabValue], assertionResults: [IntentLabAssertionResult], diagnostic: String?, proposedCause: String?, artifacts: [IntentLabArtifactReference], observationSources: [String: String]? = nil, claims: [IntentLabProofClaim]? = nil, beforeObservations: [String: IntentLabValue]? = nil) {
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

/// Advertise only proof established by a required, matching returned-value check.
public enum IntentLabReturnedValueProof {
    public static func isVerified(
        assertions: [IntentLabAssertion], observations: [String: IntentLabValue],
        resultKeys: Set<String>, checks: [IntentLabAssertionResult]
    ) -> Bool {
        assertions.contains { assertion in
            assertion.required && assertion.kind == .returnedField
                && resultKeys.contains(assertion.observationKey)
                && observations[assertion.observationKey] != nil
                && observations[assertion.observationKey] == assertion.expectedValue
                && checks.contains { $0.assertionID == assertion.id && $0.passed }
        }
    }
}
