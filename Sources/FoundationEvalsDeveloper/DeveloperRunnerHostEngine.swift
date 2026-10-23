import Foundation

public actor DeveloperTrustStore {
    private struct State: Codable {
        var tokensByDesktopID: [UUID: String]
    }

    private let fileURL: URL?
    private var tokensByDesktopID: [UUID: String]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            tokensByDesktopID = state.tokensByDesktopID
        } else {
            tokensByDesktopID = [:]
        }
    }

    public func token(for desktopID: UUID) -> String? {
        tokensByDesktopID[desktopID]
    }

    public func trust(desktopID: UUID, token: String) throws {
        tokensByDesktopID[desktopID] = token
        try persist()
    }

    public func revoke(desktopID: UUID) throws {
        tokensByDesktopID[desktopID] = nil
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(State(tokensByDesktopID: tokensByDesktopID))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

enum DeveloperHostTransportAction: Sendable {
    case respond([DeveloperRunnerEnvelope])
    case execute(
        request: DeveloperFeatureExecutionRequest,
        task: Task<DeveloperFeatureExecutionResult, Never>
    )
}

public actor DeveloperRunnerHostEngine {
    private struct PairingSession: Sendable {
        var id: UUID
        var code: String
        var nonce: Data
        var endpoint: String
        var expiresAt: Date
        var failedAttempts: Int
        var nextAttemptAt: Date?
    }

    public let identity: DeveloperRunnerIdentity
    public let registry: DeveloperFeatureRegistry
    public let trustStore: DeveloperTrustStore

    private var pairingSession: PairingSession?
    private var pairedDesktopID: UUID?
    private var authenticatedConnections: [String: UUID] = [:]
    private var reconnectChallenges: [String: DeveloperReconnectChallenge] = [:]
    private var requestIDsByConnection: [String: Set<UUID>] = [:]
    private var secureSessions: [String: DeveloperSessionCipher] = [:]

    public init(
        identity: DeveloperRunnerIdentity,
        registry: DeveloperFeatureRegistry,
        trustStore: DeveloperTrustStore = .init()
    ) {
        self.identity = identity
        self.registry = registry
        self.trustStore = trustStore
    }

    public func beginPairing(
        endpoint: String,
        duration: Duration = .seconds(300),
        now: Date = Date()
    ) -> DeveloperPairingPresentationState {
        beginPairingForTesting(
            endpoint: endpoint,
            duration: duration,
            now: now,
            code: DeveloperAuthentication.makePairingCode()
        )
    }

    func beginPairingForTesting(
        endpoint: String,
        duration: Duration = .seconds(300),
        now: Date = Date(),
        code: String
    ) -> DeveloperPairingPresentationState {
        let seconds = Double(duration.components.seconds)
        let session = PairingSession(
            id: UUID(),
            code: code,
            nonce: DeveloperAuthentication.makeNonce(),
            endpoint: endpoint,
            expiresAt: now.addingTimeInterval(seconds),
            failedAttempts: 0,
            nextAttemptAt: nil
        )
        pairingSession = session
        pairedDesktopID = nil
        return .advertising(code: session.code, endpoint: endpoint, expiresAt: session.expiresAt)
    }

    public func stopPairing() {
        pairingSession = nil
        pairedDesktopID = nil
    }

    public func pairingState(now: Date = Date()) -> DeveloperPairingPresentationState {
        guard let session = pairingSession else {
            if let pairedDesktopID { return .paired(desktopID: pairedDesktopID) }
            return .idle
        }
        guard session.expiresAt > now else {
            pairingSession = nil
            return .expired
        }
        return .advertising(code: session.code, endpoint: session.endpoint, expiresAt: session.expiresAt)
    }

    public func connectionOpened(id connectionID: String, now: Date = Date()) -> [DeveloperRunnerEnvelope] {
        let reconnect = DeveloperReconnectChallenge(
            runner: identity,
            nonce: DeveloperAuthentication.makeNonce(),
            expiresAt: now.addingTimeInterval(300)
        )
        reconnectChallenges[connectionID] = reconnect
        var messages = [DeveloperRunnerEnvelope(message: .reconnectChallenge(reconnect))]
        if let session = pairingSession, session.expiresAt > now {
            messages.append(DeveloperRunnerEnvelope(message: .pairingChallenge(.init(
                runner: identity,
                pairingSessionID: session.id,
                nonce: session.nonce,
                expiresAt: session.expiresAt
            ))))
        }
        return messages
    }

    /// Refresh both challenges when pairing starts on a connection that is
    /// already open. Its original reconnect challenge may have expired while
    /// the developer was finding the pairing controls.
    func pairingChallenges(for connectionID: String, now: Date = Date()) -> [DeveloperRunnerEnvelope] {
        guard authenticatedConnections[connectionID] == nil,
              reconnectChallenges[connectionID] != nil,
              let session = pairingSession,
              session.expiresAt > now else { return [] }
        return connectionOpened(id: connectionID, now: now)
    }

    public func connectionClosed(id connectionID: String) async {
        authenticatedConnections[connectionID] = nil
        reconnectChallenges[connectionID] = nil
        secureSessions[connectionID] = nil
        await cancelRequests(for: connectionID)
    }

    public func authenticatedDesktopID(for connectionID: String) -> UUID? {
        authenticatedConnections[connectionID]
    }

    public func handle(
        _ envelope: DeveloperRunnerEnvelope,
        connectionID: String,
        now: Date = Date()
    ) async -> [DeveloperRunnerEnvelope] {
        let action = await accept(envelope, connectionID: connectionID, now: now)
        return await resolve(action, connectionID: connectionID)
    }

    func accept(
        _ envelope: DeveloperRunnerEnvelope,
        connectionID: String,
        now: Date = Date()
    ) async -> DeveloperHostTransportAction {
        guard DeveloperProtocolVersion.current.canRead(envelope.protocolVersion) else {
            return .respond([failureEnvelope(
                requestID: envelope.id,
                code: .protocolMismatch,
                message: "Runner protocol \(envelope.protocolVersion.major).\(envelope.protocolVersion.minor) is incompatible."
            )])
        }

        switch envelope.message {
        case .pairingRequest(let request):
            return .respond(await pair(request, connectionID: connectionID, now: now))
        case .desktopHello(let hello):
            return .respond(await authenticate(hello, connectionID: connectionID))
        case .secure(let secure):
            return await handleSecure(secure, connectionID: connectionID)
        case .execute(let request):
            return .respond([
                resultFailure(request, code: .untrustedPeer, message: "Authenticated messages must use the secure session.")
            ])
        case .pairingChallenge, .pairingReceipt, .reconnectChallenge, .authenticationFailure, .hello, .result,
             .cancel, .disconnect:
            return .respond([])
        }
    }

    func resolve(
        _ action: DeveloperHostTransportAction,
        connectionID: String
    ) async -> [DeveloperRunnerEnvelope] {
        switch action {
        case .respond(let envelopes):
            return envelopes
        case .execute(let request, let task):
            let result = await task.value
            guard requestIDsByConnection[connectionID]?.remove(request.id) != nil else { return [] }
            return secureEnvelope(.result(result), connectionID: connectionID).map { [$0] } ?? []
        }
    }

    private func pair(
        _ request: DeveloperPairingRequest,
        connectionID: String,
        now: Date
    ) async -> [DeveloperRunnerEnvelope] {
        guard var session = pairingSession,
              session.id == request.pairingSessionID,
              session.expiresAt > now else {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .untrustedPeer,
                message: "The pairing code is invalid or expired."
            )]
        }
        if let nextAttemptAt = session.nextAttemptAt, nextAttemptAt > now {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .untrustedPeer,
                message: "Wait before trying the pairing code again."
            )]
        }
        let pairingChallenge = DeveloperPairingChallenge(
            runner: identity,
            pairingSessionID: session.id,
            nonce: session.nonce,
            expiresAt: session.expiresAt
        )
        guard DeveloperAuthentication.validatesPairingProof(
            request.proof,
            code: session.code,
            challenge: pairingChallenge,
            desktopID: request.desktopID
        ) else {
            session.failedAttempts += 1
            session.nextAttemptAt = now.addingTimeInterval(2)
            pairingSession = session.failedAttempts >= 5 ? nil : session
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .untrustedPeer,
                message: session.failedAttempts >= 5
                    ? "Pairing was cancelled after too many invalid attempts."
                    : "The pairing code is invalid or expired."
            )]
        }
        guard let challenge = reconnectChallenges.removeValue(forKey: connectionID),
              challenge.expiresAt > now else {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .untrustedPeer,
                message: "The connection challenge expired. Reconnect and try again."
            )]
        }

        let token = DeveloperAuthentication.makeToken()
        let sealedToken: Data
        do {
            sealedToken = try DeveloperAuthentication.sealTrustToken(
                token,
                code: session.code,
                challenge: pairingChallenge,
                desktopID: request.desktopID
            )
        } catch {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .executionFailed,
                message: "The trust receipt could not be protected."
            )]
        }
        do {
            try await trustStore.trust(desktopID: request.desktopID, token: token)
        } catch {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .executionFailed,
                message: "The trust receipt could not be saved."
            )]
        }
        pairingSession = nil
        pairedDesktopID = request.desktopID
        authenticatedConnections[connectionID] = request.desktopID
        secureSessions[connectionID] = DeveloperSessionCipher(
            token: token,
            challenge: challenge,
            desktopID: request.desktopID
        )
        let features = await registry.descriptors
        guard let secureHello = secureEnvelope(
            .hello(.init(
                runner: identity,
                features: features,
                desktopID: request.desktopID,
                reconnectChallengeID: challenge.id,
                runnerProof: DeveloperAuthentication.runnerProof(
                    token: token,
                    challenge: challenge,
                    desktopID: request.desktopID
                )
            )),
            connectionID: connectionID
        ) else {
            return [failureEnvelope(
                requestID: request.pairingSessionID,
                code: .executionFailed,
                message: "The secure runner session could not start."
            )]
        }
        return [
            DeveloperRunnerEnvelope(message: .pairingReceipt(.init(
                runner: identity,
                desktopID: request.desktopID,
                pairingSessionID: request.pairingSessionID,
                sealedTrustToken: sealedToken,
                issuedAt: now
            ))),
            secureHello,
        ]
    }

    private func authenticate(
        _ hello: DeveloperDesktopHello,
        connectionID: String,
        now: Date = Date()
    ) async -> [DeveloperRunnerEnvelope] {
        guard let challenge = reconnectChallenges[connectionID],
              challenge.id == hello.challengeID,
              challenge.expiresAt > now,
              let token = await trustStore.token(for: hello.desktopID),
              DeveloperAuthentication.validatesDesktopProof(
                hello.proof,
                token: token,
                  challenge: challenge,
                  desktopID: hello.desktopID
              ) else {
            return [DeveloperRunnerEnvelope(message: .authenticationFailure(.init(
                runnerID: identity.id,
                desktopID: hello.desktopID,
                reconnectChallengeID: hello.challengeID,
                message: "The saved trust receipt is no longer valid. Pair this runner again."
            )))]
        }
        reconnectChallenges[connectionID] = nil
        authenticatedConnections[connectionID] = hello.desktopID
        secureSessions[connectionID] = DeveloperSessionCipher(
            token: token,
            challenge: challenge,
            desktopID: hello.desktopID
        )
        guard let helloEnvelope = secureEnvelope(
            .hello(.init(
                runner: identity,
                features: await registry.descriptors,
                desktopID: hello.desktopID,
                reconnectChallengeID: challenge.id,
                runnerProof: DeveloperAuthentication.runnerProof(
                    token: token,
                    challenge: challenge,
                    desktopID: hello.desktopID
                )
            )),
            connectionID: connectionID
        ) else { return [] }
        return [helloEnvelope]
    }

    private func handleSecure(
        _ envelope: DeveloperSecureEnvelope,
        connectionID: String
    ) async -> DeveloperHostTransportAction {
        guard authenticatedConnections[connectionID] != nil,
              var cipher = secureSessions[connectionID] else { return .respond([]) }
        let message: DeveloperAuthenticatedMessage
        do {
            message = try cipher.open(envelope, direction: .desktopToRunner)
            secureSessions[connectionID] = cipher
        } catch {
            return .respond([])
        }

        switch message {
        case .execute(let request):
            // The client correlates terminal results by request ID. A second
            // result here would consume the original request's continuation.
            guard requestIDsByConnection[connectionID]?.contains(request.id) != true else { return .respond([]) }
            guard !requestIDsByConnection.values.contains(where: { $0.contains(request.id) }) else {
                let result = DeveloperFeatureExecutionResult(
                    requestID: request.id, runID: request.runID, featureID: request.featureID,
                    startedAt: Date(), completedAt: Date(),
                    failure: .init(code: .invalidInput, message: "An execution with this request ID is already active.")
                )
                return .respond(secureEnvelope(.result(result), connectionID: connectionID).map { [$0] } ?? [])
            }
            requestIDsByConnection[connectionID, default: []].insert(request.id)
            let task = await registry.start(request)
            return .execute(request: request, task: task)
        case .cancel(let requestID):
            guard requestIDsByConnection[connectionID]?.contains(requestID) == true else { return .respond([]) }
            await registry.cancel(requestID: requestID)
            return .respond([])
        case .disconnect:
            authenticatedConnections[connectionID] = nil
            secureSessions[connectionID] = nil
            await cancelRequests(for: connectionID)
            return .respond([])
        case .hello, .result:
            return .respond([])
        }
    }

    private func secureEnvelope(
        _ message: DeveloperAuthenticatedMessage,
        connectionID: String
    ) -> DeveloperRunnerEnvelope? {
        guard var cipher = secureSessions[connectionID],
              let secure = try? cipher.seal(message, direction: .runnerToDesktop) else { return nil }
        secureSessions[connectionID] = cipher
        return DeveloperRunnerEnvelope(message: .secure(secure))
    }

    private func cancelRequests(for connectionID: String) async {
        let requestIDs = requestIDsByConnection.removeValue(forKey: connectionID) ?? []
        for requestID in requestIDs {
            await registry.cancel(requestID: requestID)
        }
    }

    private func failureEnvelope(
        requestID: UUID,
        code: DeveloperExecutionErrorCode,
        message: String
    ) -> DeveloperRunnerEnvelope {
        DeveloperRunnerEnvelope(message: .result(.init(
            requestID: requestID,
            runID: requestID,
            featureID: "",
            startedAt: Date(),
            completedAt: Date(),
            failure: .init(code: code, message: message)
        )))
    }

    private func resultFailure(
        _ request: DeveloperFeatureExecutionRequest,
        code: DeveloperExecutionErrorCode,
        message: String
    ) -> DeveloperRunnerEnvelope {
        DeveloperRunnerEnvelope(message: .result(.init(
            requestID: request.id,
            runID: request.runID,
            featureID: request.featureID,
            startedAt: Date(),
            completedAt: Date(),
            failure: .init(code: code, message: message)
        )))
    }

}
