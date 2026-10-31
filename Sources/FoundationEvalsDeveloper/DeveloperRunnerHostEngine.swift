import Foundation

public actor DeveloperTrustStore {
    private struct State: Codable {
        var tokensByDesktopID: [UUID: String]
        var pendingTokensByDesktopID: [UUID: String]?
    }
    private let fileURL: URL?
    private var tokensByDesktopID: [UUID: String]
    private var pendingTokensByDesktopID: [UUID: String]

    /// Loads confirmed and pending receipts; older files contain only confirmed tokens.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        let state = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        tokensByDesktopID = state?.tokensByDesktopID ?? [:]
        pendingTokensByDesktopID = state?.pendingTokensByDesktopID ?? [:]
    }

    /// Returns the newest saved receipt, including an unconfirmed replacement when present.
    public func token(for desktopID: UUID) -> String? {
        pendingTokensByDesktopID[desktopID] ?? tokensByDesktopID[desktopID]
    }

    /// Allows a delivered pending receipt or the last confirmed receipt to authenticate reconnects.
    func tokens(for desktopID: UUID) -> [String] {
        [pendingTokensByDesktopID[desktopID], tokensByDesktopID[desktopID]].compactMap { $0 }
    }

    /// Builds separate TLS identities for the confirmed and pending receipt of each desktop.
    func transportCredentials(runnerID: UUID) -> [DeveloperTransportCredential] {
        Set(tokensByDesktopID.keys).union(pendingTokensByDesktopID.keys).flatMap { desktop in
            tokens(for: desktop).map { .trusted(token: $0, desktopID: desktop, runnerID: runnerID) }
        }
    }

    /// Explicitly replaces confirmed trust and removes any pending replacement, then persists it.
    /// A persistence error propagates after the in-memory state changes.
    public func trust(desktopID: UUID, token: String) throws {
        tokensByDesktopID[desktopID] = token
        pendingTokensByDesktopID[desktopID] = nil
        try persist()
    }

    /// Persists one pending receipt while retaining confirmed trust until possession is proved.
    /// Repeated attempts reissue the same pending secret, preventing lost receipts from invalidating each other.
    func stagePairing(desktopID: UUID) throws -> String {
        if let pending = pendingTokensByDesktopID[desktopID] { return pending }
        let token = DeveloperAuthentication.makeToken()
        pendingTokensByDesktopID[desktopID] = token
        do { try persist() }
        catch { pendingTokensByDesktopID[desktopID] = nil; throw error }
        return token
    }

    /// Atomically authorizes this receipt and promotes it only when it is the exact pending token.
    /// Returns false for revoked/superseded tokens; failed persistence preserves both saved states.
    func confirmPairing(desktopID: UUID, token: String) throws -> Bool {
        guard tokens(for: desktopID).contains(token) else { return false }
        guard pendingTokensByDesktopID[desktopID] == token else { return true }
        let previous = tokensByDesktopID[desktopID]
        tokensByDesktopID[desktopID] = token
        pendingTokensByDesktopID[desktopID] = nil
        do { try persist() }
        catch {
            tokensByDesktopID[desktopID] = previous
            pendingTokensByDesktopID[desktopID] = token
            throw error
        }
        return true
    }

    /// Revokes both confirmed and pending receipts without closing existing engine sessions.
    /// A persistence error propagates after the in-memory state changes.
    public func revoke(desktopID: UUID) throws {
        tokensByDesktopID[desktopID] = nil
        pendingTokensByDesktopID[desktopID] = nil
        try persist()
    }

    /// Atomically persists private trust with owner-only file permissions when storage is configured.
    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(State(tokensByDesktopID: tokensByDesktopID,
            pendingTokensByDesktopID: pendingTokensByDesktopID))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum DeveloperHostTransportAction: Sendable {
    case respond([DeveloperRunnerEnvelope])
    case execute(request: DeveloperFeatureExecutionRequest, task: Task<DeveloperFeatureExecutionResult, Never>)
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
    private var pairingTransaction: UUID?
    private var pairedDesktopID: UUID?
    private var connectionGenerations: [String: UUID] = [:]
    private var authenticatedConnections: [String: UUID] = [:]
    private var reconnectChallenges: [String: DeveloperReconnectChallenge] = [:]
    private var requestIDsByConnection: [String: Set<UUID>] = [:]
    private var secureSessions: [String: DeveloperSessionCipher] = [:]
    private var confirmationTokensByConnection: [String: String] = [:]

    /// Creates a transport-independent runner host with app identity, feature dispatch and trust.
    /// - Parameters:
    ///   - identity: App-reported runner identity sent in handshake messages.
    ///   - registry: Registry that admits, executes and cancels app-owned features.
    ///   - trustStore: Tokens used to authenticate reconnecting desktops.
    public init(
        identity: DeveloperRunnerIdentity,
        registry: DeveloperFeatureRegistry,
        trustStore: DeveloperTrustStore = .init()
    ) {
        self.identity = identity
        self.registry = registry
        self.trustStore = trustStore
    }

    /// Replaces any pairing session with a newly generated out-of-band code and nonce.
    /// This creates presentation state; the transport must deliver challenges to connected peers.
    /// - Parameters:
    ///   - endpoint: Display label presented alongside the pairing code.
    ///   - duration: Pairing lifetime; expiration uses its whole-second component.
    ///   - now: Clock value used to calculate expiry.
    /// - Returns: Advertising state containing the code, endpoint and expiry.
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

    /// Creates a fresh pairing session with a caller-supplied code for deterministic tests.
    /// Resets invalid-attempt throttling and the last paired-desktop presentation state.
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

    /// Discards the pairing session and paired-desktop presentation without revoking saved trust.
    public func stopPairing() {
        pairingSession = nil
        pairedDesktopID = nil
    }

    /// Returns current pairing presentation, expiring and removing a session when needed.
    /// - Parameter now: Clock value used to test expiry.
    /// - Returns: Advertising, paired or idle state; an observed expiry returns `expired`.
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

    /// Issues and records a five-minute reconnect challenge for a transport connection.
    /// - Parameters:
    ///   - connectionID: Transport-owned identity used to scope authentication and execution ownership.
    ///   - now: Clock value used to date the challenge and check pairing availability.
    /// - Returns: A reconnect challenge, plus a pairing challenge when pairing is active.
    public func connectionOpened(id connectionID: String, now: Date = Date()) -> [DeveloperRunnerEnvelope] {
        connectionGenerations[connectionID] = UUID()
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

    /// Clears a connection's authentication, challenge and cipher and cancels its owned requests.
    /// - Parameter connectionID: Transport identity previously passed to ``connectionOpened(id:now:)``.
    public func connectionClosed(id connectionID: String) async {
        connectionGenerations[connectionID] = nil
        confirmationTokensByConnection[connectionID] = nil
        authenticatedConnections[connectionID] = nil
        reconnectChallenges[connectionID] = nil
        secureSessions[connectionID] = nil
        await cancelRequests(for: connectionID)
    }

    /// Returns the desktop authenticated on a connection, or `nil` before authentication or after closure.
    public func authenticatedDesktopID(for connectionID: String) -> UUID? {
        authenticatedConnections[connectionID]
    }

    /// Admits a wire envelope and waits for any accepted execution before returning responses.
    /// Handshake messages are handled directly; execution and cancellation require a secure session.
    /// - Parameters:
    ///   - envelope: Decoded protocol envelope received from the connection.
    ///   - connectionID: Transport identity that owns authentication and request cancellation.
    ///   - now: Clock used for pairing admission; reconnect authentication uses its own current-time default.
    /// - Returns: Responses to send on this connection, possibly empty when input is ignored.
    public func handle(
        _ envelope: DeveloperRunnerEnvelope,
        connectionID: String,
        now: Date = Date()
    ) async -> [DeveloperRunnerEnvelope] {
        let action = await accept(envelope, connectionID: connectionID, now: now)
        return await resolve(action, connectionID: connectionID)
    }

    /// Checks protocol compatibility and admits a handshake or encrypted message.
    /// Returns an execution task separately so transports can keep accepting cancellation
    /// while the app operation is still running; plaintext execution is rejected.
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

    /// Returns immediate responses or awaits an admitted feature and seals its result.
    /// Suppresses a completed result if connection teardown already removed request ownership.
    func resolve(
        _ action: DeveloperHostTransportAction,
        connectionID: String
    ) async -> [DeveloperRunnerEnvelope] {
        switch action {
        case .respond(let envelopes):
            return envelopes
        case .execute(let request, let task):
            let result = boundedResult(await task.value)
            guard requestIDsByConnection[connectionID]?.remove(request.id) != nil else { return [] }
            return secureEnvelope(.result(result), connectionID: connectionID).map { [$0] } ?? []
        }
    }

    /// Replaces oversized output with a correlated failure before sealing advances the session sequence.
    /// The budget reserves Base64 expansion, AES-GCM overhead and the outer wire envelope.
    private func boundedResult(_ result: DeveloperFeatureExecutionResult) -> DeveloperFeatureExecutionResult {
        let maximumPlaintextBytes = DeveloperNetworkSession.maximumMessageBytes / 4 * 3 - 4_096
        if let bytes = try? JSONEncoder().encode(DeveloperAuthenticatedMessage.result(result)),
           bytes.count <= maximumPlaintextBytes { return result }
        var failure = result
        failure.output = nil
        failure.failure = .init(code: .executionFailed, message: "The feature result exceeds the runner transport message limit.")
        return failure
    }

    /// Checks the code proof, session expiry and retry throttle before establishing trust.
    /// Invalid proofs wait two seconds between attempts and cancel pairing after five failures.
    /// Success stages or reissues a pending token and returns a sealed receipt and hello; possession proof confirms replacement.
    private func pair(
        _ request: DeveloperPairingRequest,
        connectionID: String,
        now: Date
    ) async -> [DeveloperRunnerEnvelope] {
        guard pairingTransaction == nil,
              let generation = connectionGenerations[connectionID],
              var session = pairingSession,
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

        pairingTransaction = UUID()
        defer { pairingTransaction = nil }
        let features = await registry.descriptors
        guard connectionGenerations[connectionID] == generation, pairingSession?.id == session.id else { return [] }
        let token: String
        do { token = try await trustStore.stagePairing(desktopID: request.desktopID) }
        catch {
            return [failureEnvelope(requestID: request.pairingSessionID, code: .executionFailed,
                message: "The pending trust receipt could not be saved.")]
        }
        guard connectionGenerations[connectionID] == generation, pairingSession?.id == session.id else { return [] }
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
        pairingSession = nil
        pairedDesktopID = request.desktopID
        confirmationTokensByConnection[connectionID] = token
        authenticatedConnections[connectionID] = request.desktopID
        secureSessions[connectionID] = DeveloperSessionCipher(
            token: token,
            challenge: challenge,
            desktopID: request.desktopID
        )
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

    /// Validates a fresh reconnect challenge and desktop token proof, then establishes the cipher
    /// and returns a secure runner hello. Invalid trust produces a challenge-correlated rejection.
    private func authenticate(
        _ hello: DeveloperDesktopHello,
        connectionID: String,
        now: Date = Date()
    ) async -> [DeveloperRunnerEnvelope] {
        guard let generation = connectionGenerations[connectionID],
              let challenge = reconnectChallenges[connectionID],
              challenge.id == hello.challengeID,
              challenge.expiresAt > now,
              let token = await trustStore.tokens(for: hello.desktopID).first(where: {
                  DeveloperAuthentication.validatesDesktopProof(hello.proof, token: $0,
                      challenge: challenge, desktopID: hello.desktopID)
              }) else {
            return authenticationFailure(hello)
        }
        let features = await registry.descriptors
        guard connectionGenerations[connectionID] == generation else { return [] }
        do {
            guard try await trustStore.confirmPairing(desktopID: hello.desktopID, token: token) else { return authenticationFailure(hello) }
        }
        catch {
            return [failureEnvelope(requestID: hello.challengeID, code: .executionFailed,
                message: "The pairing receipt could not be confirmed.")]
        }
        guard connectionGenerations[connectionID] == generation else { return [] }
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
                features: features,
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

    /// Rejects saved trust with the runner, desktop and challenge identities the client requires.
    private func authenticationFailure(_ hello: DeveloperDesktopHello) -> [DeveloperRunnerEnvelope] {
        return [DeveloperRunnerEnvelope(message: .authenticationFailure(.init(
                runnerID: identity.id,
                desktopID: hello.desktopID,
                reconnectChallengeID: hello.challengeID,
                message: "The saved trust receipt is no longer valid. Pair this runner again."
            )))]
    }

    /// Authenticates ordered desktop traffic and enforces request ownership per connection.
    /// Ignores same-connection duplicate IDs, rejects cross-connection collisions, and accepts
    /// cancellation only for requests owned by this connection. Invalid secure input is ignored.
    private func handleSecure(
        _ envelope: DeveloperSecureEnvelope,
        connectionID: String
    ) async -> DeveloperHostTransportAction {
        guard let desktopID = authenticatedConnections[connectionID],
              var cipher = secureSessions[connectionID] else { return .respond([]) }
        let message: DeveloperAuthenticatedMessage
        do {
            message = try cipher.open(envelope, direction: .desktopToRunner)
            secureSessions[connectionID] = cipher
        } catch {
            return .respond([])
        }

        if let token = confirmationTokensByConnection[connectionID] {
            do {
                guard try await trustStore.confirmPairing(desktopID: desktopID, token: token) else {
                    let response = secureEnvelope(.disconnect(reason: "The pairing receipt was revoked."), connectionID: connectionID)
                    await connectionClosed(id: connectionID)
                    return .respond(response.map { [$0] } ?? [])
                }
            } catch {
                let response = secureEnvelope(.disconnect(reason: "The pairing receipt could not be confirmed."), connectionID: connectionID)
                await connectionClosed(id: connectionID)
                return .respond(response.map { [$0] } ?? [])
            }
            guard authenticatedConnections[connectionID] == desktopID else { return .respond([]) }
            confirmationTokensByConnection[connectionID] = nil
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

    /// Seals the next runner-to-desktop message and saves its advanced cipher state.
    /// Returns `nil` when no secure session exists or encoding/encryption fails.
    private func secureEnvelope(
        _ message: DeveloperAuthenticatedMessage,
        connectionID: String
    ) -> DeveloperRunnerEnvelope? {
        guard var cipher = secureSessions[connectionID],
              let secure = try? cipher.seal(message, direction: .runnerToDesktop) else { return nil }
        secureSessions[connectionID] = cipher
        return DeveloperRunnerEnvelope(message: .secure(secure))
    }

    /// Removes this connection's request ownership and requests cooperative registry cancellation.
    /// Removing ownership also prevents later operation completions from producing a response.
    private func cancelRequests(for connectionID: String) async {
        let requestIDs = requestIDsByConnection.removeValue(forKey: connectionID) ?? []
        for requestID in requestIDs {
            await registry.cancel(requestID: requestID)
        }
    }

    /// Builds a plaintext protocol/handshake failure using the supplied identity for both
    /// request and run IDs, because no admitted feature request is available.
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

    /// Builds a plaintext execution rejection preserving the request's IDs and feature key.
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
