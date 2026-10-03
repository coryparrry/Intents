import Foundation

enum IntentLabLane: String, Codable { case appFeature, intentIntegration, siri }
enum IntentLabLaneRequirement: String, Codable { case required, optional, notApplicable }
enum IntentLabExecutionStatus: String, Codable { case completed, blockedByEnvironment, timedOut, cancelled, crashed, failedToBuild, invalidEvidence }
enum IntentLabOutcome: String, Codable { case passed, failed, needsReview, notObserved, notApplicable }

indirect enum IntentLabValue: Codable, Equatable {
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

struct IntentLabDateValue: Codable, Equatable {
    var source: String
    var timeZoneIdentifier: String
    var resolvedInstant: Date
}

struct IntentLabEnumValue: Codable, Equatable {
    var typeIdentifier: String
    var caseIdentifier: String
}

struct IntentLabEntityValue: Codable, Equatable {
    var typeIdentifier: String
    var identifier: String
}

indirect enum IntentLabValueType: Codable {
    case primitive(IntentLabPrimitiveType)
    case enumeration(typeIdentifier: String, allowedCases: [String])
    case entity(typeIdentifier: String)
    case array(element: IntentLabValueType)
}

enum IntentLabPrimitiveType: String, Codable { case string, boolean, integer, number, date }
enum IntentLabPresence: Codable { case missing, value(IntentLabValue) }

struct IntentLabParameter: Codable {
    var name: String
    var type: IntentLabValueType
    var isOptional: Bool
    var presence: IntentLabPresence
}

struct IntentLabOutputField: Codable { var name: String; var type: IntentLabValueType }
struct IntentLabDirectControl: Codable {
    var intentIdentifier: String
    var parameters: [IntentLabParameter]
    var outputFields: [IntentLabOutputField]
}
struct IntentLabTarget: Codable { var bundleIdentifier: String }
struct IntentLabGoal: Codable { var requestText: String; var languageCode: String }
struct IntentLabFixture: Codable { var id: String; var version: String; var digest: String; var preparationOperation: String; var cleanupOperation: String }
enum IntentLabAssertionKind: String, Codable {
    case entityIdentifier, returnedField, visibleText, stateTransition, noMutation, semanticRubric
}
struct IntentLabAssertion: Codable {
    var id: UUID
    var kind: IntentLabAssertionKind
    var observationKey: String
    var expectedValue: IntentLabValue?
    var required: Bool
    var applicableLanes: Set<IntentLabLane>?
}
struct IntentLabSafety: Codable { var deadlineSeconds: Double }
struct IntentLabCoverage: Codable {
    var appFeature: IntentLabLaneRequirement
    var intentIntegration: IntentLabLaneRequirement
    var siri: IntentLabLaneRequirement
    var siriAttemptCount: Int?
}

struct IntentLabScenario: Codable {
    var schemaVersion: Int? = 1
    var id: UUID
    var version: Int
    var definitionDigest: String
    var target: IntentLabTarget
    var goal: IntentLabGoal
    var fixture: IntentLabFixture
    var directControl: IntentLabDirectControl
    var assertions: [IntentLabAssertion]
    var coverage: IntentLabCoverage
    var safety: IntentLabSafety
}

enum IntentLabPayloadError: LocalizedError {
    case partialEnvironment
    case malformedBase64(String)
    case oversized(Int)
    case unsupportedSchema

    var errorDescription: String? {
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

enum IntentLabPayloadLoader {
    static let scenarioKey = "FOUNDATION_EVALS_INTENT_LAB_SCENARIO_B64"
    static let invocationKey = "FOUNDATION_EVALS_INTENT_LAB_INVOCATION_B64"
    static let maximumPayloadBytes = 256 * 1_024

    static func environmentData(
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

struct IntentLabProductIdentity: Codable, Equatable {
    var bundleIdentifier: String
    var executableName: String
    var sha256: String
}
struct IntentLabTestIdentity: Codable, Equatable { var bundleIdentifier: String; var className: String; var methodName: String }
struct IntentLabInvocation: Codable {
    var id: UUID
    var nonce: String
    var issuedAt: Date
    var testIdentity: IntentLabTestIdentity
    var harnessVersion: String
    var destinationIdentifier: String
    var scenarioDigest: String
    var resultBundleIdentity: String
    var appProduct: IntentLabProductIdentity?
    var testProduct: IntentLabProductIdentity?
}

struct IntentLabAssertionResult: Codable {
    var id = UUID()
    var assertionID: UUID
    var passed: Bool
    var observedValue: IntentLabValue?
    var message: String
}

struct IntentLabArtifactReference: Codable {
    var id: UUID
    var kind: String
    var filename: String
    var relativePath: String
    var contentType: String
    var byteCount: Int
    var sha256: String
    var manuallySupplied: Bool
}

struct IntentLabLaneResult: Codable {
    var id = UUID()
    var caseID: UUID
    var attempt: Int
    var lane: IntentLabLane
    var executionStatus: IntentLabExecutionStatus
    var outcome: IntentLabOutcome
    var startedAt: Date
    var completedAt: Date
    var observations: [String: IntentLabValue]
    var assertionResults: [IntentLabAssertionResult]
    var diagnostic: String?
    var proposedCause: String?
    var artifacts: [IntentLabArtifactReference]
    var observationSources: [String: String]? = nil
}

struct IntentLabEnvironment: Codable {
    var xcodeVersion: String
    var sdkVersion: String
    var deviceModel: String
    var operatingSystem: String
    var operatingSystemBuild: String?
    var languageCode: String
    var regionCode: String
    var timeZoneIdentifier: String
    var siriConfiguration: String?
    var siriConfigurationSource: String?
    var executedAt: Date
}

struct IntentLabEvidenceEnvelope: Codable {
    var schemaVersion = 1
    var invocation: IntentLabInvocation
    var sourceBundleIdentifier: String
    var observedAppProduct: IntentLabProductIdentity
    var observedTestProduct: IntentLabProductIdentity
    var environment: IntentLabEnvironment
    var testCount: Int
    var results: [IntentLabLaneResult]
}

extension JSONDecoder {
    static var intentLab: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

extension JSONEncoder {
    static var intentLab: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
}
