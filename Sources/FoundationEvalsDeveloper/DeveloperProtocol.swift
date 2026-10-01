import Foundation
import CryptoKit

public struct DeveloperProtocolVersion: Codable, Hashable, Sendable, Comparable {
    public static let current = Self(major: 1, minor: 0)

    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

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

    public init(
        id: UUID,
        displayName: String,
        platform: DeveloperRunnerPlatform,
        operatingSystem: String,
        hardwareModel: String,
        appBundleIdentifier: String,
        appVersion: String,
        localeIdentifier: String? = nil,
        protocolVersion: DeveloperProtocolVersion = .current
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
    }
}

public struct DeveloperFeatureDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var version: String
    public var inputTypeName: String
    public var outputTypeName: String
    public var capabilityNames: [String]

    public init(
        id: String,
        displayName: String,
        version: String,
        inputTypeName: String,
        outputTypeName: String,
        capabilityNames: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.inputTypeName = inputTypeName
        self.outputTypeName = outputTypeName
        self.capabilityNames = capabilityNames
    }
}

public struct DeveloperTextFeatureInput: Codable, Hashable, Sendable {
    public var caseID: UUID
    public var instructions: String
    public var prompt: String
    public var expected: String
    public var repetition: Int

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
    public var deadline: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        featureID: String,
        featureVersion: String,
        encodedInput: Data,
        inputTypeName: String,
        deadline: Date
    ) {
        self.id = id
        self.runID = runID
        self.featureID = featureID
        self.featureVersion = featureVersion
        self.encodedInput = encodedInput
        self.inputTypeName = inputTypeName
        self.deadline = deadline
    }
}

public enum DeveloperExecutionErrorCode: String, Codable, Sendable {
    case cancelled
    case deadlineExceeded
    case featureNotFound
    case incompatibleFeatureVersion
    case invalidInput
    case executionFailed
    case disconnected
    case protocolMismatch
    case untrustedPeer
}

public struct DeveloperExecutionFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    public var code: DeveloperExecutionErrorCode
    public var message: String

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

    public init(sessionID: UUID, sequence: UInt64, sealedMessage: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.sealedMessage = sealedMessage
    }
}

enum DeveloperAuthentication {
    static func makeToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    static func makeNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func makePairingCode() -> String {
        let compact = makeNonce().prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")
    }

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

    static func desktopProof(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Data {
        proof(token: token, challenge: challenge, desktopID: desktopID, role: "desktop")
    }

    static func runnerProof(
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Data {
        proof(token: token, challenge: challenge, desktopID: desktopID, role: "runner")
    }

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

    static func validatesDesktopProof(
        _ proof: Data,
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Bool {
        validates(proof, token: token, challenge: challenge, desktopID: desktopID, role: "desktop")
    }

    static func validatesRunnerProof(
        _ proof: Data,
        token: String,
        challenge: DeveloperReconnectChallenge,
        desktopID: UUID
    ) -> Bool {
        validates(proof, token: token, challenge: challenge, desktopID: desktopID, role: "runner")
    }

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
