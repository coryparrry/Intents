import Foundation
import CryptoKit

public struct DeveloperProtocolVersion: Codable, Hashable, Sendable, Comparable {
    public static let current = Self(major: 1, minor: 0)

    public var major: Int
    public var minor: Int

    /// Creates a protocol version used for ordering and read-compatibility checks.
    /// - Parameters:
    ///   - major: Protocol family; readers require an exact match.
    ///   - minor: Revision within the family; readers accept revisions up to their own.
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Orders versions lexicographically by major version, then minor version.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// Returns whether this version can read the supplied version: the major must match
    /// and the incoming minor version must be no newer than this reader's minor version.
    public func canRead(_ other: Self) -> Bool {
        major == other.major && other.minor <= minor
    }
}

public enum DeveloperRunnerPlatform: String, Codable, CaseIterable, Sendable {
    case iPhone
    case iPad
    case mac
    case vision
    case unknown
}

public struct DeveloperRunnerIdentity: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var platform: DeveloperRunnerPlatform
    public var operatingSystem: String
    public var hardwareModel: String
    public var appBundleIdentifier: String
    public var appVersion: String
    public var localeIdentifier: String?
    public var protocolVersion: DeveloperProtocolVersion
    /// Metadata supplied by the application build. It is not device attestation.
    public var buildProvenance: DeveloperRunnerBuildProvenance?

    /// Creates the app-reported identity exchanged during pairing and authentication.
    /// Values are stored as supplied; optional build provenance is a report from the app,
    /// which the host must compare with its checked product before claiming a build match.
    /// - Parameters:
    ///   - id: Runner identity used to correlate discovery and saved trust.
    ///   - displayName: Human-readable app or device label.
    ///   - platform: Platform category reported by the runner.
    ///   - operatingSystem: Reported operating system version.
    ///   - hardwareModel: Reported hardware description.
    ///   - appBundleIdentifier: Bundle identifier of the app exposing features.
    ///   - appVersion: App version reported to the host.
    ///   - localeIdentifier: Optional locale used by the runner.
    ///   - protocolVersion: Protocol revision the runner reports.
    ///   - buildProvenance: Optional app-supplied build identifiers; not device attestation.
    public init(
        id: UUID,
        displayName: String,
        platform: DeveloperRunnerPlatform,
        operatingSystem: String,
        hardwareModel: String,
        appBundleIdentifier: String,
        appVersion: String,
        localeIdentifier: String? = nil,
        protocolVersion: DeveloperProtocolVersion = .current,
        buildProvenance: DeveloperRunnerBuildProvenance? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.operatingSystem = operatingSystem
        self.hardwareModel = hardwareModel
        self.appBundleIdentifier = appBundleIdentifier
        self.appVersion = appVersion
        self.localeIdentifier = localeIdentifier
        self.protocolVersion = protocolVersion
        self.buildProvenance = buildProvenance
    }
}

/// Values embedded by the developer's build process and reported during the authenticated handshake.
/// A host must compare these with its checked product before claiming an exact build match.
public struct DeveloperRunnerBuildProvenance: Codable, Hashable, Sendable {
    public var logicalAppID: String
    public var buildID: String
    public var sourceManifestDigest: String?
    public var packageRevision: String?
    public var compiledProductNonce: String?

    /// Creates build metadata for comparison with a host's checked app product.
    /// - Parameters:
    ///   - logicalAppID: Logical app identifier shared with the host's build record.
    ///   - buildID: Identifier for the compiled executable, such as its SHA-256 digest.
    ///   - sourceManifestDigest: Optional digest supplied by the build process.
    ///   - packageRevision: Optional revision of the embedded developer package.
    ///   - compiledProductNonce: Optional nonce embedded into this compiled product.
    public init(
        logicalAppID: String,
        buildID: String,
        sourceManifestDigest: String? = nil,
        packageRevision: String? = nil,
        compiledProductNonce: String? = nil
    ) {
        self.logicalAppID = logicalAppID
        self.buildID = buildID
        self.sourceManifestDigest = sourceManifestDigest
        self.packageRevision = packageRevision
        self.compiledProductNonce = compiledProductNonce
    }
}

public struct DeveloperFeatureDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var version: String
    public var inputTypeName: String
    public var outputTypeName: String
    public var capabilityNames: [String]
    /// Present only when the app explicitly supports the expectation-free input contract.
    public var subjectInputSchema: DeveloperSubjectInputSchema?

    /// Creates the feature contract advertised to a host; values are stored without validation.
    /// - Parameters:
    ///   - id: Registry key used to select the feature for execution.
    ///   - displayName: Human-readable feature label.
    ///   - version: Version that an execution request must match exactly.
    ///   - inputTypeName: Name describing the request's encoded input type.
    ///   - outputTypeName: Name describing the feature's output type.
    ///   - capabilityNames: Capabilities declared by the app.
    ///   - subjectInputSchema: Optional schema for the expectation-free input contract.
    public init(
        id: String,
        displayName: String,
        version: String,
        inputTypeName: String,
        outputTypeName: String,
        capabilityNames: [String] = [],
        subjectInputSchema: DeveloperSubjectInputSchema? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.inputTypeName = inputTypeName
        self.outputTypeName = outputTypeName
        self.capabilityNames = capabilityNames
        self.subjectInputSchema = subjectInputSchema
    }
}

public enum DeveloperFeatureInputContract: String, Codable, Hashable, Sendable {
    case legacyTypedV1
    case subjectV1
}

public indirect enum DeveloperSubjectValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case array([DeveloperSubjectValue])
    case object([String: DeveloperSubjectValue])
    case null
}

public indirect enum DeveloperSubjectValueType: Codable, Hashable, Sendable {
    case string
    case integer
    case number
    case boolean
    case array(DeveloperSubjectValueType)
    case object([DeveloperSubjectInputField])
}

public struct DeveloperSubjectInputField: Codable, Hashable, Sendable {
    public var name: String
    public var valueType: DeveloperSubjectValueType
    public var required: Bool
    public var nullable: Bool

    /// Declares an allowed business-input field and its presence/nullability rules.
    /// Required controls whether the key must exist; nullable separately controls whether
    /// an explicit `null` value is accepted.
    public init(name: String, valueType: DeveloperSubjectValueType, required: Bool = true, nullable: Bool = false) {
        self.name = name
        self.valueType = valueType
        self.required = required
        self.nullable = nullable
    }
}

public struct DeveloperSubjectInputSchema: Codable, Hashable, Sendable {
    public static let capabilityName = "expectation-free-subject-input-v1"
    public var version: String
    public var fields: [DeveloperSubjectInputField]

    /// Creates an expectation-free input schema; ``validate(_:)`` performs its checks.
    /// - Parameters:
    ///   - version: Nonempty schema version required during validation.
    ///   - fields: Allowed business-input keys, their types and presence rules.
    public init(version: String, fields: [DeveloperSubjectInputField]) {
        self.version = version
        self.fields = fields
    }

    /// Validates business inputs and fixture references against the app-declared contract.
    /// Rejects unknown fields, missing required values, type/nullability mismatches, duplicate
    /// schema fields, assessment-field names and duplicate or incomplete fixture references.
    /// - Parameter input: Subject input received from the host.
    /// - Throws: An `invalidInput` ``DeveloperExecutionFailure`` describing the violated rule.
    public func validate(_ input: DeveloperSubjectInput) throws {
        guard !version.isEmpty else { throw invalid("The subject input schema has no version.") }
        try validate(input.businessInputs, against: fields, path: "businessInputs")
        let fixtureIDs = input.fixtureReferences.map(\.identifier)
        guard Set(fixtureIDs).count == fixtureIDs.count else {
            throw invalid("Fixture references must have unique identifiers.")
        }
        guard input.fixtureReferences.allSatisfy({ !$0.identifier.isEmpty && !$0.contractDigest.isEmpty }) else {
            throw invalid("Fixture references require an identifier and contract digest.")
        }
    }

    /// Checks object keys against their declarations, rejecting assessment names, duplicate
    /// schema fields, missing required keys and input keys absent from the schema.
    private func validate(
        _ values: [String: DeveloperSubjectValue],
        against fields: [DeveloperSubjectInputField],
        path: String
    ) throws {
        let names = fields.map(\.name)
        guard Set(names).count == names.count else { throw invalid("The \(path) schema has duplicate fields.") }
        for field in fields {
            guard !field.name.isEmpty, !Self.isOracleName(field.name) else {
                throw invalid("The \(path) schema declares an unsupported assessment field: \(field.name).")
            }
            guard let value = values[field.name] else {
                if field.required { throw invalid("Missing required subject input \(path).\(field.name).") }
                continue
            }
            try validate(value, as: field.valueType, nullable: field.nullable, path: "\(path).\(field.name)")
        }
        for name in values.keys where !names.contains(name) {
            throw invalid("Unsupported subject input \(path).\(name).")
        }
    }

    /// Checks a subject value recursively against its declared type and nullability.
    /// Array elements cannot be null, and integer and number values require their exact type.
    private func validate(
        _ value: DeveloperSubjectValue,
        as type: DeveloperSubjectValueType,
        nullable: Bool,
        path: String
    ) throws {
        if case .null = value {
            if nullable { return }
            throw invalid("Subject input \(path) cannot be null.")
        }
        switch (value, type) {
        case (.string, .string), (.integer, .integer), (.number, .number), (.boolean, .boolean):
            return
        case (.array(let values), .array(let elementType)):
            for (index, element) in values.enumerated() {
                try validate(element, as: elementType, nullable: false, path: "\(path)[\(index)]")
            }
        case (.object(let values), .object(let fields)):
            try validate(values, against: fields, path: path)
        default:
            throw invalid("Subject input \(path) has the wrong declared type.")
        }
    }

    /// Recognizes disallowed assessment-field names after removing nonletters and folding case.
    private static func isOracleName(_ name: String) -> Bool {
        let compact = name.lowercased().filter(\.isLetter)
        return ["expected", "expectedanswer", "expectedfacts", "referenceanswer", "goldenanswer",
                "answerkey", "rubric", "threshold", "passthreshold", "scoringinstructions"].contains(compact)
    }

    /// Wraps a schema-validation message in an `invalidInput` execution failure.
    private func invalid(_ message: String) -> DeveloperExecutionFailure {
        .init(code: .invalidInput, message: message)
    }
}

public struct DeveloperSubjectFixtureReference: Codable, Hashable, Sendable {
    public var identifier: String
    public var contractDigest: String

    /// Identifies an intended fixture by its app-defined identifier and contract digest.
    /// The initializer stores values unchanged; schema validation rejects empty values.
    public init(identifier: String, contractDigest: String) {
        self.identifier = identifier
        self.contractDigest = contractDigest
    }
}

/// The app receives only the user-facing business input, intended fixture and execution correlation.
/// Assessment references, expected answers, rubrics and thresholds stay on the host.
public struct DeveloperSubjectInput: Codable, Hashable, Sendable {
    public var caseID: UUID
    public var attemptID: UUID
    public var businessInputs: [String: DeveloperSubjectValue]
    public var fixtureReferences: [DeveloperSubjectFixtureReference]

    /// Creates only the business input, fixture references and execution correlation sent to the app.
    /// - Parameters:
    ///   - caseID: Host case that supplied the business input.
    ///   - attemptID: Individual attempt within that case.
    ///   - businessInputs: User-facing values checked against the app's declared schema.
    ///   - fixtureReferences: Intended fixtures identified by contract, without assessment data.
    public init(
        caseID: UUID,
        attemptID: UUID,
        businessInputs: [String: DeveloperSubjectValue],
        fixtureReferences: [DeveloperSubjectFixtureReference] = []
    ) {
        self.caseID = caseID
        self.attemptID = attemptID
        self.businessInputs = businessInputs
        self.fixtureReferences = fixtureReferences
    }

    private enum CodingKeys: String, CodingKey { case caseID, attemptID, businessInputs, fixtureReferences }

    /// Decodes the four subject-input fields and rejects unknown top-level keys.
    /// - Parameter decoder: Decoder containing case, attempt, business inputs and fixture references.
    /// - Throws: A decoding error for unknown, missing or malformed fields.
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["caseID", "attemptID", "businessInputs", "fixtureReferences"])
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown subject input field."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        caseID = try values.decode(UUID.self, forKey: .caseID)
        attemptID = try values.decode(UUID.self, forKey: .attemptID)
        businessInputs = try values.decode([String: DeveloperSubjectValue].self, forKey: .businessInputs)
        fixtureReferences = try values.decode([DeveloperSubjectFixtureReference].self, forKey: .fixtureReferences)
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        /// Represents an arbitrary string key so decoding can detect unsupported top-level fields.
        init?(stringValue: String) { self.stringValue = stringValue }
        /// Rejects integer coding keys because the subject-input envelope uses named fields.
        init?(intValue: Int) { return nil }
    }
}

public struct DeveloperTextFeatureInput: Codable, Hashable, Sendable {
    public var caseID: UUID
    public var instructions: String
    public var prompt: String
    public var expected: String
    public var repetition: Int

    /// Creates input for the historical text workflow, including its expected answer.
    /// Use the subject-input contract when assessment references must remain on the host.
    /// - Parameters:
    ///   - caseID: Case associated with the text invocation.
    ///   - instructions: Instructions passed to the app's text feature.
    ///   - prompt: User-facing prompt to execute.
    ///   - expected: Expected answer included by the legacy contract.
    ///   - repetition: Host-provided repetition index.
    public init(caseID: UUID, instructions: String, prompt: String, expected: String, repetition: Int) {
        self.caseID = caseID
        self.instructions = instructions
        self.prompt = prompt
        self.expected = expected
        self.repetition = repetition
    }
}

public struct DeveloperFeatureUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    /// Records app-reported token counts; omitted counts default to zero.
    /// The initializer stores counts unchanged and does not measure usage.
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct DeveloperFeatureOutput: Codable, Hashable, Sendable {
    public var response: String
    public var encodedValue: Data?
    public var encodedValueTypeName: String?
    public var usage: DeveloperFeatureUsage
    public var metadata: [String: String]

    /// Creates the output returned by an app-owned feature.
    /// - Parameters:
    ///   - response: Human-readable response used by the host.
    ///   - encodedValue: Optional encoded structured result.
    ///   - encodedValueTypeName: Optional type name describing the encoded value.
    ///   - usage: App-reported input/output token counts.
    ///   - metadata: App-defined string metadata accompanying the result.
    public init(
        response: String,
        encodedValue: Data? = nil,
        encodedValueTypeName: String? = nil,
        usage: DeveloperFeatureUsage = .init(),
        metadata: [String: String] = [:]
    ) {
        self.response = response
        self.encodedValue = encodedValue
        self.encodedValueTypeName = encodedValueTypeName
        self.usage = usage
        self.metadata = metadata
    }
}

public struct DeveloperFeatureExecutionRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var featureID: String
    public var featureVersion: String
    public var encodedInput: Data
    public var inputTypeName: String
    /// Nil decodes as the historical typed input contract.
    public var inputContract: DeveloperFeatureInputContract?
    public var deadline: Date

    /// Creates a feature invocation without dispatching it or validating its payload.
    /// - Parameters:
    ///   - id: Request identity used for cancellation and result correlation; keep active IDs unique.
    ///   - runID: Host run grouping this invocation.
    ///   - featureID: Registry key of the app-owned feature.
    ///   - featureVersion: Exact registered feature version required for admission.
    ///   - encodedInput: JSON input decoded by the registered feature.
    ///   - inputTypeName: Declared input type; subject-input admission checks it against the descriptor.
    ///   - inputContract: Requested contract; `nil` selects the historical typed contract.
    ///   - deadline: Wall-clock deadline checked before dispatch and around operation execution.
    public init(
        id: UUID = UUID(),
        runID: UUID,
        featureID: String,
        featureVersion: String,
        encodedInput: Data,
        inputTypeName: String,
        inputContract: DeveloperFeatureInputContract? = nil,
        deadline: Date
    ) {
        self.id = id
        self.runID = runID
        self.featureID = featureID
        self.featureVersion = featureVersion
        self.encodedInput = encodedInput
        self.inputTypeName = inputTypeName
        self.inputContract = inputContract
        self.deadline = deadline
    }
}

public enum DeveloperExecutionErrorCode: String, Codable, Sendable {
    case cancelled
    case deadlineExceeded
    case featureNotFound
    case incompatibleFeatureVersion
    case invalidInput
    case unsupportedInputContract
    case executionFailed
    case disconnected
    case protocolMismatch
    case untrustedPeer
}

public struct DeveloperExecutionFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    public var code: DeveloperExecutionErrorCode
    public var message: String

    /// Creates a structured execution error with its wire code and user-facing message.
    /// The message also supplies the localized error description.
    public init(code: DeveloperExecutionErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct DeveloperFeatureExecutionResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { requestID }
    public var requestID: UUID
    public var runID: UUID
    public var featureID: String
    public var startedAt: Date
    public var completedAt: Date
    public var output: DeveloperFeatureOutput?
    public var failure: DeveloperExecutionFailure?

    /// Creates a terminal result correlated to the originating request and run.
    /// The initializer stores output and failure as supplied; it does not enforce exclusivity.
    /// - Parameters:
    ///   - requestID: Execution request identity and this result's `id`.
    ///   - runID: Host run that owns the execution.
    ///   - featureID: Registered feature selected by the request.
    ///   - startedAt: Time recorded when admission began.
    ///   - completedAt: Time recorded when the terminal result was produced.
    ///   - output: Successful feature output, when available.
    ///   - failure: Structured failure, when execution did not succeed.
    public init(
        requestID: UUID,
        runID: UUID,
        featureID: String,
        startedAt: Date,
        completedAt: Date,
        output: DeveloperFeatureOutput? = nil,
        failure: DeveloperExecutionFailure? = nil
    ) {
        self.requestID = requestID
        self.runID = runID
        self.featureID = featureID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.output = output
        self.failure = failure
    }
}

public struct DeveloperPairingChallenge: Codable, Hashable, Sendable {
    public var runner: DeveloperRunnerIdentity
    public var pairingSessionID: UUID
    public var nonce: Data
    public var expiresAt: Date

    /// Creates a pairing challenge bound to a runner, pairing session, random nonce and expiry.
    /// The human-readable pairing code is conveyed separately and is not stored here.
    public init(runner: DeveloperRunnerIdentity, pairingSessionID: UUID, nonce: Data, expiresAt: Date) {
        self.runner = runner
        self.pairingSessionID = pairingSessionID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

public struct DeveloperPairingRequest: Codable, Hashable, Sendable {
    public var pairingSessionID: UUID
    public var proof: Data
    public var desktopID: UUID

    /// Creates a desktop's pairing response using a code-derived proof for this session.
    /// The request carries the desktop identity and proof, rather than the pairing code itself.
    public init(pairingSessionID: UUID, proof: Data, desktopID: UUID) {
        self.pairingSessionID = pairingSessionID
        self.proof = proof
        self.desktopID = desktopID
    }
}

public struct DeveloperPairingReceipt: Codable, Hashable, Sendable {
    public var runner: DeveloperRunnerIdentity
    public var desktopID: UUID
    public var pairingSessionID: UUID
    public var sealedTrustToken: Data
    public var issuedAt: Date

    /// Creates a pairing receipt containing a sealed trust token for the requesting desktop.
    /// - Parameters:
    ///   - runner: App-reported runner identity associated with the new trust.
    ///   - desktopID: Desktop whose code proof was accepted.
    ///   - pairingSessionID: Pairing session that authorized the receipt.
    ///   - sealedTrustToken: Token sealed with the pairing-code-derived key and transcript.
    ///   - issuedAt: Timestamp reported for issuance of the receipt.
    public init(
        runner: DeveloperRunnerIdentity,
        desktopID: UUID,
        pairingSessionID: UUID,
        sealedTrustToken: Data,
        issuedAt: Date = Date()
    ) {
        self.runner = runner
        self.desktopID = desktopID
        self.pairingSessionID = pairingSessionID
        self.sealedTrustToken = sealedTrustToken
        self.issuedAt = issuedAt
    }
}

public struct DeveloperRunnerHello: Codable, Hashable, Sendable {
    public var runner: DeveloperRunnerIdentity
    public var features: [DeveloperFeatureDescriptor]
    public var desktopID: UUID
    public var reconnectChallengeID: UUID
    public var runnerProof: Data

    /// Creates the runner's authenticated greeting for a reconnect challenge.
    /// The greeting advertises registered features and proves the runner's saved trust token.
    /// - Parameters:
    ///   - runner: Runner identity for this secure session.
    ///   - features: Feature descriptors exposed by the app.
    ///   - desktopID: Desktop authenticated on the connection.
    ///   - reconnectChallengeID: Challenge that established this session.
    ///   - runnerProof: Role-specific trust-token proof for that challenge.
    public init(
        runner: DeveloperRunnerIdentity,
        features: [DeveloperFeatureDescriptor],
        desktopID: UUID,
        reconnectChallengeID: UUID,
        runnerProof: Data
    ) {
        self.runner = runner
        self.features = features
        self.desktopID = desktopID
        self.reconnectChallengeID = reconnectChallengeID
        self.runnerProof = runnerProof
    }
}

public struct DeveloperReconnectChallenge: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runner: DeveloperRunnerIdentity
    public var nonce: Data
    public var expiresAt: Date

    /// Creates a reconnect challenge used to derive proofs and the secure session key.
    /// - Parameters:
    ///   - id: Challenge identity, also used as the secure session ID.
    ///   - runner: Runner that issued the challenge.
    ///   - nonce: Random challenge bytes.
    ///   - expiresAt: Time after which the host rejects authentication with this challenge.
    public init(
        id: UUID = UUID(),
        runner: DeveloperRunnerIdentity,
        nonce: Data,
        expiresAt: Date
    ) {
        self.id = id
        self.runner = runner
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

public struct DeveloperDesktopHello: Codable, Hashable, Sendable {
    public var desktopID: UUID
    public var challengeID: UUID
    public var proof: Data

    /// Creates a desktop greeting with a trust-token proof bound to the reconnect challenge.
    public init(desktopID: UUID, challengeID: UUID, proof: Data) {
        self.desktopID = desktopID
        self.challengeID = challengeID
        self.proof = proof
    }
}

public struct DeveloperAuthenticationFailure: Codable, Hashable, Sendable {
    public var runnerID: UUID
    public var desktopID: UUID
    public var reconnectChallengeID: UUID
    public var message: String

    /// Creates a saved-trust rejection tied to the runner, desktop and reconnect challenge.
    /// The client uses these identities to ignore failures unrelated to its pending handshake.
    public init(runnerID: UUID, desktopID: UUID, reconnectChallengeID: UUID, message: String) {
        self.runnerID = runnerID
        self.desktopID = desktopID
        self.reconnectChallengeID = reconnectChallengeID
        self.message = message
    }
}

public enum DeveloperRunnerMessage: Codable, Hashable, Sendable {
    case pairingChallenge(DeveloperPairingChallenge)
    case pairingRequest(DeveloperPairingRequest)
    case pairingReceipt(DeveloperPairingReceipt)
    case reconnectChallenge(DeveloperReconnectChallenge)
    case desktopHello(DeveloperDesktopHello)
    case authenticationFailure(DeveloperAuthenticationFailure)
    case hello(DeveloperRunnerHello)
    case execute(DeveloperFeatureExecutionRequest)
    case result(DeveloperFeatureExecutionResult)
    case cancel(requestID: UUID)
    case disconnect(reason: String)
    case secure(DeveloperSecureEnvelope)
}

public enum DeveloperAuthenticatedMessage: Codable, Hashable, Sendable {
    case hello(DeveloperRunnerHello)
    case execute(DeveloperFeatureExecutionRequest)
    case result(DeveloperFeatureExecutionResult)
    case cancel(requestID: UUID)
    case disconnect(reason: String)
}

public struct DeveloperSecureEnvelope: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sequence: UInt64
    public var sealedMessage: Data

    /// Creates an encrypted wire envelope with session identity and ordered sequence number.
    /// Construction does not authenticate the ciphertext; the session cipher checks it on receipt.
    public init(sessionID: UUID, sequence: UInt64, sealedMessage: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.sealedMessage = sealedMessage
    }
}

enum DeveloperAuthentication {
    /// Generates a random 256-bit trust token encoded as a Base64 string.
    static func makeToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// Generates 32 random bytes for pairing or reconnect challenge material.
    static func makeNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Formats 16 random bytes as uppercase hexadecimal groups for an out-of-band pairing code.
    static func makePairingCode() -> String {
        let compact = makeNonce().prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")
    }

    /// Authenticates the desktop's pairing transcript with a key derived from the code,
    /// challenge nonce, pairing session and desktop identity.
    static func pairingProof(
        code: String,
        challenge: DeveloperPairingChallenge,
        desktopID: UUID
    ) -> Data {
        let key = pairingKey(code: code, challenge: challenge, desktopID: desktopID)
        return Data(HMAC<SHA256>.authenticationCode(
            for: pairingPayload(challenge: challenge, desktopID: desktopID, role: "desktop"),
            using: key
        ))
    }

    /// Checks a pairing proof against the desktop-role transcript and code-derived key.
    static func validatesPairingProof(
        _ proof: Data,
        code: String,
        challenge: DeveloperPairingChallenge,
        desktopID: UUID
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: pairingPayload(challenge: challenge, desktopID: desktopID, role: "desktop"),
            using: pairingKey(code: code, challenge: challenge, desktopID: desktopID)
        )
    }

    /// Seals a UTF-8 trust token with AES-GCM and the runner-role pairing transcript.
    /// Throws encryption errors or an execution failure if combined ciphertext is unavailable.
    static func sealTrustToken(
        _ token: String,
        code: String,
        challenge: DeveloperPairingChallenge,
        desktopID: UUID
    ) throws -> Data {
        let sealed = try AES.GCM.seal(
            Data(token.utf8),
            using: pairingKey(code: code, challenge: challenge, desktopID: desktopID),
            authenticating: pairingPayload(challenge: challenge, desktopID: desktopID, role: "runner")
        )
        guard let combined = sealed.combined else {
            throw DeveloperExecutionFailure(code: .executionFailed, message: "The trust receipt could not be sealed.")
        }
        return combined
    }

    /// Authenticates and opens a sealed trust receipt using the supplied pairing code.
    /// Throws for malformed ciphertext, authentication failure or a token that is not UTF-8.
    static func openTrustToken(
        _ sealedToken: Data,
        code: String,
        challenge: DeveloperPairingChallenge,
        desktopID: UUID
    ) throws -> String {
        let box = try AES.GCM.SealedBox(combined: sealedToken)
        let data = try AES.GCM.open(
            box,
            using: pairingKey(code: code, challenge: challenge, desktopID: desktopID),
            authenticating: pairingPayload(challenge: challenge, desktopID: desktopID, role: "runner")
        )
        guard let token = String(data: data, encoding: .utf8) else {
            throw DeveloperExecutionFailure(code: .untrustedPeer, message: "The trust receipt was invalid.")
        }
        return token
    }

    /// Computes the desktop-role HMAC for a reconnect challenge using the saved token.
    static func desktopProof(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Data {
        proof(token: token, challenge: challenge, desktopID: desktopID, role: "desktop")
    }

    /// Computes the runner-role HMAC for a reconnect challenge using the saved token.
    static func runnerProof(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Data {
        proof(token: token, challenge: challenge, desktopID: desktopID, role: "runner")
    }

    /// Derives 32 session-key bytes from the trust token, challenge nonce and challenge,
    /// runner and desktop identities with the session-key domain prefix.
    static func sessionKey(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Data {
        var material = Data("FoundationEvalsDeveloper.session-key.v1".utf8)
        material.append(contentsOf: token.utf8)
        material.append(challenge.nonce)
        material.append(contentsOf: challenge.id.uuidString.utf8)
        material.append(contentsOf: challenge.runner.id.uuidString.utf8)
        material.append(contentsOf: desktopID.uuidString.utf8)
        return Data(SHA256.hash(data: material))
    }

    /// Validates the desktop-role reconnect proof using the saved token.
    static func validatesDesktopProof(
        _ proof: Data,
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Bool {
        validates(proof, token: token, challenge: challenge, desktopID: desktopID, role: "desktop")
    }

    /// Validates the runner-role reconnect proof using the saved token.
    static func validatesRunnerProof(
        _ proof: Data,
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Bool {
        validates(proof, token: token, challenge: challenge, desktopID: desktopID, role: "runner")
    }

    /// Computes a role-bound reconnect HMAC over the challenge transcript.
    private static func proof(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID,
        role: String
    ) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: payload(challenge: challenge, desktopID: desktopID, role: role),
            using: SymmetricKey(data: Data(token.utf8))
        )
        return Data(code)
    }

    /// Checks a role-bound reconnect HMAC without exposing the expected proof bytes.
    private static func validates(
        _ proof: Data,
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID,
        role: String
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: payload(challenge: challenge, desktopID: desktopID, role: role),
            using: SymmetricKey(data: Data(token.utf8))
        )
    }

    /// Encodes the reconnect domain, nonce, challenge ID, desktop ID and role into its transcript.
    private static func payload(
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID,
        role: String
    ) -> Data {
        var value = Data("FoundationEvalsDeveloper.reconnect.v1".utf8)
        value.append(challenge.nonce)
        value.append(contentsOf: challenge.id.uuidString.utf8)
        value.append(contentsOf: desktopID.uuidString.utf8)
        value.append(contentsOf: role.utf8)
        return value
    }

    /// Derives the pairing key from normalized code, nonce, pairing-session ID and desktop ID.
    private static func pairingKey(
        code: String,
        challenge: DeveloperPairingChallenge,
        desktopID: UUID
    ) -> SymmetricKey {
        var material = Data("FoundationEvalsDeveloper.pairing-key.v1".utf8)
        material.append(contentsOf: normalizedPairingCode(code).utf8)
        material.append(challenge.nonce)
        material.append(contentsOf: challenge.pairingSessionID.uuidString.utf8)
        material.append(contentsOf: desktopID.uuidString.utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    /// Encodes the pairing transcript with nonce, session, runner, desktop and role bindings.
    private static func pairingPayload(
        challenge: DeveloperPairingChallenge,
        desktopID: UUID,
        role: String
    ) -> Data {
        var value = Data("FoundationEvalsDeveloper.pairing-transcript.v1".utf8)
        value.append(challenge.nonce)
        value.append(contentsOf: challenge.pairingSessionID.uuidString.utf8)
        value.append(contentsOf: challenge.runner.id.uuidString.utf8)
        value.append(contentsOf: desktopID.uuidString.utf8)
        value.append(contentsOf: role.utf8)
        return value
    }

    /// Uppercases a pairing code and removes separators and all other nonhexadecimal characters.
    private static func normalizedPairingCode(_ code: String) -> String {
        code.uppercased().filter { $0.isHexDigit }
    }
}

enum DeveloperSecureDirection: String, Sendable {
    case desktopToRunner
    case runnerToDesktop
}

struct DeveloperSessionCipher: Sendable {
    let sessionID: UUID
    private let key: SymmetricKey
    private var nextOutboundSequence: UInt64 = 0
    private var nextInboundSequence: UInt64 = 0

    /// Derives a cipher for this reconnect challenge with independent inbound and outbound
    /// sequence counters starting at zero.
    init(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) {
        sessionID = challenge.id
        key = SymmetricKey(data: DeveloperAuthentication.sessionKey(
            token: token,
            challenge: challenge,
            desktopID: desktopID
        ))
    }

    /// JSON-encodes and seals an authenticated message, binding its session, sequence and direction.
    /// Advances the outbound counter only after sealing succeeds; encoding/encryption errors propagate.
    mutating func seal(
        _ message: DeveloperAuthenticatedMessage,
        direction: DeveloperSecureDirection
    ) throws -> DeveloperSecureEnvelope {
        let sequence = nextOutboundSequence
        let sealed = try AES.GCM.seal(
            JSONEncoder().encode(message),
            using: key,
            authenticating: additionalData(sequence: sequence, direction: direction)
        )
        guard let combined = sealed.combined else {
            throw DeveloperExecutionFailure(code: .executionFailed, message: "The secure message could not be sealed.")
        }
        nextOutboundSequence += 1
        return .init(sessionID: sessionID, sequence: sequence, sealedMessage: combined)
    }

    /// Requires this session's next inbound sequence, then authenticates and decodes the message.
    /// Rejects replayed or out-of-order envelopes with `untrustedPeer`; advances the counter only
    /// after decryption and decoding succeed. Authentication and decoding errors propagate.
    mutating func open(
        _ envelope: DeveloperSecureEnvelope,
        direction: DeveloperSecureDirection
    ) throws -> DeveloperAuthenticatedMessage {
        guard envelope.sessionID == sessionID,
              envelope.sequence == nextInboundSequence else {
            throw DeveloperExecutionFailure(code: .untrustedPeer, message: "The secure message was replayed or out of order.")
        }
        let box = try AES.GCM.SealedBox(combined: envelope.sealedMessage)
        let data = try AES.GCM.open(
            box,
            using: key,
            authenticating: additionalData(sequence: envelope.sequence, direction: direction)
        )
        let message = try JSONDecoder().decode(DeveloperAuthenticatedMessage.self, from: data)
        nextInboundSequence += 1
        return message
    }

    /// Builds AES-GCM additional authenticated data binding session, sequence and traffic direction.
    private func additionalData(sequence: UInt64, direction: DeveloperSecureDirection) -> Data {
        var value = Data("FoundationEvalsDeveloper.secure-envelope.v1".utf8)
        value.append(contentsOf: sessionID.uuidString.utf8)
        value.append(contentsOf: String(sequence).utf8)
        value.append(contentsOf: direction.rawValue.utf8)
        return value
    }
}

struct DeveloperSecureEnvelopeBuffer: Sendable {
    private(set) var nextSequence: UInt64 = 0
    private var pending: [UInt64: DeveloperRunnerEnvelope] = [:]

    /// Buffers secure envelopes until every sequence from the next expected value is available.
    /// Returns that contiguous prefix in order; nonsecure envelopes and old sequences are ignored.
    /// An insertion at a pending sequence replaces the envelope stored for that sequence.
    mutating func insert(_ envelope: DeveloperRunnerEnvelope) -> [DeveloperRunnerEnvelope] {
        guard case .secure(let secure) = envelope.message,
              secure.sequence >= nextSequence else { return [] }
        pending[secure.sequence] = envelope

        var ready: [DeveloperRunnerEnvelope] = []
        while let envelope = pending.removeValue(forKey: nextSequence) {
            ready.append(envelope)
            nextSequence += 1
        }
        return ready
    }
}

/// Builds a MultipeerConnectivity display name within 63 UTF-8 bytes, reserving an
/// eight-character UUID suffix and truncating only at character boundaries.
func developerPeerDisplayName(_ displayName: String, id: UUID) -> String {
    let suffix = "-\(id.uuidString.prefix(8))"
    let byteLimit = 63 - suffix.utf8.count
    var prefix = ""
    for character in displayName {
        let candidate = prefix + String(character)
        guard candidate.utf8.count <= byteLimit else { break }
        prefix = candidate
    }
    if prefix.isEmpty { prefix = "Runner" }
    return prefix + suffix
}


public enum DeveloperRunnerConnectionState: String, Codable, Sendable {
    case discovered
    case connecting
    case pairingRequired
    case connected
    case disconnected
    case incompatible
}

public struct DeveloperRunnerSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var identity: DeveloperRunnerIdentity
    public var features: [DeveloperFeatureDescriptor]
    public var state: DeveloperRunnerConnectionState
    public var lastSeen: Date
    public var availabilityDetail: String?

    /// Creates a runner snapshot whose identity also supplies the snapshot ID.
    /// - Parameters:
    ///   - identity: Last reported or placeholder runner identity.
    ///   - features: Last advertised feature descriptors.
    ///   - state: Current discovery/authentication/connection state.
    ///   - lastSeen: Timestamp associated with this snapshot.
    ///   - availabilityDetail: Optional explanation of availability or connection failure.
    public init(
        identity: DeveloperRunnerIdentity,
        features: [DeveloperFeatureDescriptor],
        state: DeveloperRunnerConnectionState,
        lastSeen: Date = Date(),
        availabilityDetail: String? = nil
    ) {
        id = identity.id
        self.identity = identity
        self.features = features
        self.state = state
        self.lastSeen = lastSeen
        self.availabilityDetail = availabilityDetail
    }
}

public enum DeveloperRunPhase: String, Codable, Sendable {
    case preparing
    case dispatching
    case running
    case completed
    case cancelled
    case failed
    case timedOut
    case disconnected
}

public struct DeveloperRunStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runnerID: UUID
    public var featureID: String
    public var phase: DeveloperRunPhase
    public var completedSamples: Int
    public var totalSamples: Int
    public var detail: String?

    /// Creates host-side progress for a run without dispatching any work.
    /// - Parameters:
    ///   - id: Run identity shared by execution requests.
    ///   - runnerID: Runner selected for the run.
    ///   - featureID: Feature selected for execution.
    ///   - phase: Current lifecycle phase.
    ///   - completedSamples: Number of successful samples recorded so far.
    ///   - totalSamples: Number of samples expected for the run.
    ///   - detail: Optional progress or failure explanation.
    public init(
        id: UUID,
        runnerID: UUID,
        featureID: String,
        phase: DeveloperRunPhase,
        completedSamples: Int = 0,
        totalSamples: Int = 0,
        detail: String? = nil
    ) {
        self.id = id
        self.runnerID = runnerID
        self.featureID = featureID
        self.phase = phase
        self.completedSamples = completedSamples
        self.totalSamples = totalSamples
        self.detail = detail
    }
}

public enum DeveloperPairingPresentationState: Codable, Hashable, Sendable {
    case idle
    case advertising(code: String, endpoint: String, expiresAt: Date)
    case paired(desktopID: UUID)
    case expired
}

public struct DeveloperRunnerEnvelope: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var protocolVersion: DeveloperProtocolVersion
    public var sentAt: Date
    public var message: DeveloperRunnerMessage

    /// Wraps a wire message with envelope identity, protocol revision and send timestamp.
    /// The envelope ID is separate from request identities carried inside execution messages.
    /// - Parameters:
    ///   - id: Identity of this wire envelope.
    ///   - protocolVersion: Revision used to check read compatibility.
    ///   - sentAt: Sender's timestamp for this message.
    ///   - message: Handshake or encrypted-session message to transport.
    public init(
        id: UUID = UUID(),
        protocolVersion: DeveloperProtocolVersion = .current,
        sentAt: Date = Date(),
        message: DeveloperRunnerMessage
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.message = message
    }
}
