import Foundation
import Network
import Observation

private struct DeveloperClientCandidate {
    var runnerID: UUID
    var endpoint: String
    var isDiscoverable = true
    var reconnectChallenge: DeveloperReconnectChallenge?
    var pairingChallenge: DeveloperPairingChallenge?
    var requestedPairingSessionID: UUID?
    var requestedPairingCode: String?
    var secureSession: DeveloperSessionCipher?
    var reconnectWasRejected = false
    var attemptedTransportAuthentication = false
}

private struct DeveloperStoredTrustReceipt: Codable {
    var runner: DeveloperRunnerIdentity
    var desktopID: UUID
    var trustToken: String
    var issuedAt: Date
}

private struct DeveloperDesktopTrustState: Codable {
    struct Entry: Codable {
        var endpoint: String
        var receipt: DeveloperStoredTrustReceipt
    }

    var entries: [Entry]
}

@MainActor
@Observable
public final class DeveloperRunnerClient {
    public let desktopID: UUID
    public private(set) var runners: [DeveloperRunnerSnapshot] = []
    public var selectedRunnerID: UUID?
    public private(set) var activeRuns: [UUID: DeveloperRunStatus] = [:]
    public private(set) var pendingPairingChallenges: [UUID: DeveloperPairingChallenge] = [:]
    public private(set) var isBrowsing = false
    public private(set) var lastError: String?

    @ObservationIgnored private let trustStoreURL: URL?
    @ObservationIgnored private let session = DeveloperNetworkSession()
    @ObservationIgnored private let browser = DeveloperNetworkBrowser()
    @ObservationIgnored private var selectedCandidatePeerByRunnerID: [UUID: DeveloperPeerID] = [:]
    @ObservationIgnored private var authenticatedPeersByRunnerID: [UUID: DeveloperPeerBox] = [:]
    @ObservationIgnored private var candidatesByPeer: [DeveloperPeerID: DeveloperClientCandidate] = [:]
    @ObservationIgnored private var trustByRunnerID: [UUID: DeveloperDesktopTrustState.Entry] = [:]
    @ObservationIgnored private var activeRunnerID: UUID?
    @ObservationIgnored private var connectingPeers: Set<DeveloperPeerID> = []
    @ObservationIgnored private var unauthenticatedSessionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<DeveloperFeatureExecutionResult, any Error>] = [:]
    @ObservationIgnored private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates the desktop transport and loads saved runner trust when it can be decoded.
    /// Browsing starts only when ``startBrowsing()`` is called. Trust data that cannot be read or
    /// decoded is ignored.
    /// - Parameters:
    ///   - desktopID: Stable desktop identity used in pairing and reconnect proofs.
    ///   - displayName: Legacy desktop label retained for source compatibility; TLS identities use `desktopID`.
    ///   - trustStoreURL: Optional JSON receipt file; `nil` keeps trust only in memory.
    public init(
        desktopID: UUID,
        displayName: String = "Intents",
        trustStoreURL: URL? = nil
    ) {
        self.desktopID = desktopID
        self.trustStoreURL = trustStoreURL

        if let trustStoreURL,
           let data = try? Data(contentsOf: trustStoreURL),
           let state = try? JSONDecoder().decode(DeveloperDesktopTrustState.self, from: data) {
            trustByRunnerID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.receipt.runner.id, $0) })
        }

        session.owner = self
        browser.owner = self
    }

    /// Starts nearby runner discovery once and clears the previous browsing error.
    /// Saved trusted runners may reconnect automatically when discovered.
    public func startBrowsing() {
        guard !isBrowsing else { return }
        browser.startBrowsing()
        isBrowsing = true
        lastError = nil
    }

    /// Stops nearby discovery without disconnecting the current transport session.
    public func stopBrowsing() {
        guard isBrowsing else { return }
        browser.stopBrowsing()
        isBrowsing = false
    }

    /// Stops discovery, disconnects the transport and clears connection/authentication state.
    /// Pending executions fail with `disconnected`, their timers are cancelled, and listed
    /// runners become disconnected. Saved trust remains available for a later connection.
    public func shutdown() {
        stopBrowsing()
        session.disconnect()
        authenticatedPeersByRunnerID = [:]
        candidatesByPeer = [:]
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        selectedCandidatePeerByRunnerID = [:]
        activeRunnerID = nil
        connectingPeers.removeAll()
        let pending = Array(continuations.keys)
        for requestID in pending {
            finish(
                requestID: requestID,
                throwing: DeveloperExecutionFailure(
                    code: .disconnected,
                    message: "Runner discovery was stopped."
                )
            )
        }
        for index in runners.indices {
            runners[index].state = .disconnected
            runners[index].availabilityDetail = "Runner discovery is stopped."
        }
    }

    /// Starts saved-trust connections, or requests a pairing code before opening first-contact TLS.
    /// Return does not confirm authentication; observe the runner's connection state.
    /// - Parameters:
    ///   - runnerID: Runner to connect, identified by its discovery snapshot.
    ///   - timeout: TLS and application authentication admission timeout in seconds.
    /// - Throws: `disconnected` if no endpoint is discoverable or another runner is active.
    public func connect(to runnerID: UUID, timeout: TimeInterval = 20) throws {
        let peers = try prepareConnection(to: runnerID)
        for peer in peers {
            try invite(peer, timeout: timeout)
        }
    }

    /// Records invitation ownership before asking the transport to connect.
    /// Kept separate so transport failure transitions can be tested without networking.
    func prepareConnection(to runnerID: UUID) throws -> [DeveloperPeerID] {
        let peers = candidatesByPeer.compactMap { peer, candidate in
            candidate.runnerID == runnerID && candidate.isDiscoverable ? peer : nil
        }
        guard !peers.isEmpty else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "The runner is no longer discoverable.")
        }
        if let activeRunnerID, activeRunnerID != runnerID {
            throw DeveloperExecutionFailure(
                code: .disconnected,
                message: "Disconnect the active runner before connecting another device."
            )
        }
        beginConnecting(to: runnerID, peers: peers)
        return peers
    }

    /// Claims the active runner and candidate invitations,
    /// and publishes the runner's connecting state before the transport is invited.
    private func beginConnecting(to runnerID: UUID, peers: [DeveloperPeerID]) {
        activeRunnerID = runnerID
        connectingPeers.formUnion(peers)
        updateRunner(runnerID) {
            $0.state = .connecting
            $0.availabilityDetail = nil
        }
    }

    /// Opens first-contact TLS with the complete code, then submits its application pairing proof.
    /// The receipt authenticates saved trust; execution waits for the authenticated runner greeting.
    /// - Parameters:
    ///   - runnerID: Discovered runner whose app displays the code.
    ///   - pairingCode: Complete 128-bit code; grouping and letter case are ignored.
    /// - Throws: Invalid code, unavailable runner, competing active runner, or transport errors.
    public func trustRunner(_ runnerID: UUID, pairingCode: String) throws {
        _ = try DeveloperTransportCredential.pairing(code: pairingCode, runnerID: runnerID)
        let peers = try prepareConnection(to: runnerID)
        for peer in peers {
            candidatesByPeer[peer]?.requestedPairingCode = pairingCode
            if let challenge = candidatesByPeer[peer]?.pairingChallenge,
               challenge.expiresAt > Date(), session.connectedPeers.contains(peer) {
                try submitPairingProof(pairingCode, challenge: challenge, peer: peer)
            } else {
                try invite(peer, timeout: 20)
            }
        }
    }

    /// Opens only authenticated TLS; first contact waits for the user's out-of-band code.
    private func invite(_ peer: DeveloperPeerID, timeout: TimeInterval) throws {
        guard let candidate = candidatesByPeer[peer], let endpoint = browser.endpoint(for: peer) else { return }
        let credential: DeveloperTransportCredential
        if let code = candidate.requestedPairingCode {
            credential = try .pairing(code: code, runnerID: candidate.runnerID)
        } else if let trust = trustByRunnerID[candidate.runnerID], !candidate.reconnectWasRejected {
            credential = .trusted(token: trust.receipt.trustToken, desktopID: desktopID, runnerID: candidate.runnerID)
        } else {
            updateRunner(candidate.runnerID) {
                $0.state = .pairingRequired
                $0.availabilityDetail = "Enter the complete code shown by the runner app to open an encrypted connection."
            }
            return
        }
        startUnauthenticatedSessionTimeoutIfNeeded()
        candidatesByPeer[peer]?.attemptedTransportAuthentication = true
        session.connect(peer, endpoint: endpoint, credential: credential, timeout: timeout)
    }

    /// Sends the original application proof after TLS first-contact authentication succeeds.
    private func submitPairingProof(_ code: String, challenge: DeveloperPairingChallenge, peer: DeveloperPeerID) throws {
        let request = DeveloperPairingRequest(pairingSessionID: challenge.pairingSessionID,
            proof: DeveloperAuthentication.pairingProof(code: code, challenge: challenge, desktopID: desktopID),
            desktopID: desktopID)
        candidatesByPeer[peer]?.requestedPairingSessionID = challenge.pairingSessionID
        candidatesByPeer[peer]?.requestedPairingCode = code
        try send(.init(message: .pairingRequest(request)), to: .init(peer))
    }

    /// Disconnects this runner, clears its authentication and fails pending executions.
    /// For an active runner it also asks the peer to disconnect and closes the shared transport.
    /// - Parameter runnerID: Runner to disconnect; unknown or already inactive runners have no effect.
    public func disconnect(_ runnerID: UUID) {
        guard activeRunnerID == runnerID || selectedCandidatePeerByRunnerID[runnerID] != nil || authenticatedPeersByRunnerID[runnerID] != nil else { return }
        guard activeRunnerID == runnerID else {
            markDisconnected(runnerID: runnerID, detail: "Disconnected by the user.")
            return
        }
        try? sendAuthenticated(.disconnect(reason: "Disconnected by the user."), runnerID: runnerID)
        session.disconnect()
        connectingPeers = connectingPeers.filter { candidatesByPeer[$0]?.runnerID != runnerID }
        activeRunnerID = nil
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        markDisconnected(runnerID: runnerID, detail: "Disconnected by the user.")
    }

    /// Removes saved trust and pending pairing state, clears candidate secure sessions,
    /// and marks the runner as requiring pairing again.
    /// - Parameter runnerID: Runner whose trust should be removed.
    /// - Throws: A persistence error after the in-memory trust has already been removed.
    public func forgetTrust(for runnerID: UUID) throws {
        guard candidatesByPeer.values.contains(where: { $0.runnerID == runnerID })
                || trustByRunnerID[runnerID] != nil else { return }
        trustByRunnerID[runnerID] = nil
        clearPairingState(for: runnerID)
        for peer in candidatesByPeer.compactMap({ $0.value.runnerID == runnerID ? $0.key : nil }) {
            candidatesByPeer[peer]?.reconnectChallenge = nil
            candidatesByPeer[peer]?.secureSession = nil
        }
        try persistTrust()
        updateRunner(runnerID) {
            $0.state = .pairingRequired
            $0.availabilityDetail = "Trust removed. Pair this runner again."
        }
    }

    /// Sends an execution over an authenticated connection and awaits its correlated result.
    /// Remote feature failures are returned in the result. Transport failures, local cancellation
    /// and the desktop timeout throw; cancellation and timeout also attempt a remote cancel.
    /// - Parameters:
    ///   - request: Invocation with a request ID unique among this client's pending executions.
    ///   - runnerID: Trusted runner whose snapshot is connected.
    ///   - timeout: Desktop wait limit, independent of the request's runner-side deadline.
    /// - Returns: The runner's terminal result, which may contain a feature failure.
    /// - Throws: `disconnected` when no authenticated connection exists, a send error, or a
    ///   local `cancelled`/`deadlineExceeded` execution failure.
    public func execute(
        _ request: DeveloperFeatureExecutionRequest,
        on runnerID: UUID,
        timeout: Duration = .seconds(120)
    ) async throws -> DeveloperFeatureExecutionResult {
        guard let peer = authenticatedPeersByRunnerID[runnerID],
              session.connectedPeers.contains(peer.peer),
              runners.first(where: { $0.id == runnerID })?.state == .connected else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "Connect the trusted runner before dispatching.")
        }

        activeRuns[request.runID] = .init(
            id: request.runID,
            runnerID: runnerID,
            featureID: request.featureID,
            phase: .dispatching,
            totalSamples: 1
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[request.id] = continuation
                timeoutTasks[request.id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.timeout(request: request, runnerID: runnerID)
                }
                do {
                    try sendAuthenticated(.execute(request), runnerID: runnerID)
                    activeRuns[request.runID]?.phase = .running
                } catch {
                    finish(requestID: request.id, throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: request.id, runID: request.runID, runnerID: runnerID)
            }
        }
    }

    /// Attempts remote cooperative cancellation and finishes the local pending request as cancelled.
    /// - Parameters:
    ///   - requestID: Execution identity used to route the cancel and pending continuation.
    ///   - runID: Run whose published phase becomes cancelled.
    ///   - runnerID: Runner to receive the cancel if it still has an authenticated peer.
    public func cancel(requestID: UUID, runID: UUID, runnerID: UUID) {
        if authenticatedPeersByRunnerID[runnerID] != nil {
            try? sendAuthenticated(.cancel(requestID: requestID), runnerID: runnerID)
        }
        activeRuns[runID]?.phase = .cancelled
        finish(
            requestID: requestID,
            throwing: DeveloperExecutionFailure(code: .cancelled, message: "The remote run was cancelled.")
        )
    }

    /// Records a discovered endpoint, supplies a placeholder or saved identity, and invites
    /// trusted candidates automatically when no different runner owns the session.
    /// Rediscovery only refreshes availability for an authenticated peer; its advertised
    /// runner ID cannot replace the identity, features or state established by authentication.
    func found(_ box: DeveloperPeerBox, runnerID advertisedRunnerID: UUID?, endpoint resolvedEndpoint: NWEndpoint? = nil) {
        if let resolvedEndpoint { browser.register(box.peer, endpoint: resolvedEndpoint) }
        let endpoint = box.peer.displayName
        if authenticatedPeersByRunnerID.values.contains(where: { $0.peer == box.peer }) {
            candidatesByPeer[box.peer]?.endpoint = endpoint
            candidatesByPeer[box.peer]?.isDiscoverable = true
            return
        }
        let runnerID = advertisedRunnerID ?? candidatesByPeer[box.peer]?.runnerID ?? UUID()
        if let authenticated = authenticatedPeersByRunnerID[runnerID], authenticated.peer != box.peer {
            candidatesByPeer[box.peer] = DeveloperClientCandidate(runnerID: runnerID, endpoint: endpoint)
            return
        }
        if candidatesByPeer[box.peer]?.runnerID == runnerID {
            candidatesByPeer[box.peer]?.endpoint = endpoint
            candidatesByPeer[box.peer]?.isDiscoverable = true
        } else {
            candidatesByPeer[box.peer] = DeveloperClientCandidate(runnerID: runnerID, endpoint: endpoint)
        }
        selectedCandidatePeerByRunnerID[runnerID] = box.peer

        if let entry = trustByRunnerID[runnerID] {
            upsertRunner(.init(
                identity: entry.receipt.runner,
                features: [],
                state: activeRunnerID == nil || activeRunnerID == runnerID ? .connecting : .discovered,
                availabilityDetail: activeRunnerID == nil || activeRunnerID == runnerID
                    ? "Reconnecting trusted runner…"
                    : "Disconnect the active runner before connecting this device."
            ))
            if activeRunnerID == nil || activeRunnerID == runnerID {
                beginConnecting(to: runnerID, peers: [box.peer])
                try? invite(box.peer, timeout: 20)
            }
        } else {
            let placeholder = DeveloperRunnerIdentity(
                id: runnerID,
                displayName: endpoint,
                platform: .unknown,
                operatingSystem: "Unknown until paired",
                hardwareModel: "Unknown until paired",
                appBundleIdentifier: "unknown",
                appVersion: "unknown"
            )
            upsertRunner(.init(
                identity: placeholder,
                features: [],
                state: .discovered,
                availabilityDetail: "Connect, then enter the code shown by the runner app."
            ))
            if activeRunnerID == runnerID {
                beginConnecting(to: runnerID, peers: [box.peer])
                try? invite(box.peer, timeout: 20)
            }
        }
    }

    /// Marks an endpoint undiscoverable, retaining connected or in-flight candidates.
    /// Evicts an otherwise unused candidate and releases failed connection ownership if needed.
    func lostPeer(_ box: DeveloperPeerBox) {
        guard let runnerID = candidatesByPeer[box.peer]?.runnerID else { return }
        candidatesByPeer[box.peer]?.isDiscoverable = false
        // Discovery describes availability for new invitations, not an existing session.
        guard authenticatedPeersByRunnerID[runnerID]?.peer != box.peer,
              !session.connectedPeers.contains(box.peer),
              !connectingPeers.contains(box.peer) else { return }
        evictCandidate(box, runnerID: runnerID)
        releaseFailedConnectionIfNeeded(runnerID)
    }

    /// Offers replacement pairing only for a rejected TLS credential, preserving trust on path failures.
    func transportRejected(_ box: DeveloperPeerBox) {
        guard let runnerID = candidatesByPeer[box.peer]?.runnerID,
              authenticatedPeersByRunnerID[runnerID] == nil else { return }
        candidatesByPeer[box.peer]?.reconnectWasRejected = true
    }

    /// Updates connection state from transport callbacks, retaining discoverable endpoints
    /// after failed invitations so an explicit retry remains possible.
    func peerChanged(_ box: DeveloperPeerBox, state: DeveloperSessionState) {
        guard let runnerID = candidatesByPeer[box.peer]?.runnerID else { return }
        switch state {
        case .connected:
            startUnauthenticatedSessionTimeoutIfNeeded()
            updateRunner(runnerID) {
                $0.state = .connecting
                $0.availabilityDetail = trustByRunnerID[runnerID] == nil
                    ? "Waiting for an active pairing code from the runner."
                    : "Authenticating saved trust…"
            }
        case .connecting:
            updateRunner(runnerID) { $0.state = .connecting }
        case .notConnected:
            connectingPeers.remove(box.peer)
            candidatesByPeer[box.peer]?.reconnectChallenge = nil
            candidatesByPeer[box.peer]?.secureSession = nil
            if authenticatedPeersByRunnerID[runnerID]?.peer == box.peer {
                authenticatedPeersByRunnerID[runnerID] = nil
                activeRunnerID = nil
                markDisconnected(runnerID: runnerID, detail: "Runner disconnected.")
            } else {
                // A failed invitation does not remove an endpoint that the browser
                // still discovers. Keep it available for an explicit retry.
                if candidatesByPeer[box.peer]?.isDiscoverable != true {
                    evictCandidate(box, runnerID: runnerID)
                }
                releaseFailedConnectionIfNeeded(runnerID)
                if candidatesByPeer[box.peer]?.attemptedTransportAuthentication == true,
                   candidatesByPeer[box.peer]?.reconnectWasRejected == true
                     || candidatesByPeer[box.peer]?.requestedPairingCode != nil {
                    candidatesByPeer[box.peer]?.attemptedTransportAuthentication = false
                    clearPairingState(for: runnerID)
                    lastError = "The encrypted runner connection failed. Check the runner and its pairing code, then try again."
                    updateRunner(runnerID) {
                        $0.state = .pairingRequired
                        $0.availabilityDetail = "Enter the current pairing code to reconnect."
                    }
                }
            }

        }
    }

    /// Decodes compatible envelopes and advances pairing, saved-trust and secure-message handling.
    /// Only authenticated payloads reach normal result handling; malformed or unauthenticated
    /// messages are ignored or recorded as connection errors.
    func received(_ data: Data, from box: DeveloperPeerBox) {
        guard var runnerID = candidatesByPeer[box.peer]?.runnerID else { return }
        let envelope: DeveloperRunnerEnvelope
        do {
            envelope = try JSONDecoder().decode(DeveloperRunnerEnvelope.self, from: data)
        } catch {
            lastError = "A runner message could not be decoded."
            return
        }
        guard DeveloperProtocolVersion.current.canRead(envelope.protocolVersion) else {
            updateRunner(runnerID) {
                $0.state = .incompatible
                $0.availabilityDetail = "Runner protocol is incompatible."
            }
            return
        }

        switch envelope.message {
        case .reconnectChallenge(let challenge):
            guard bindCandidate(box, to: challenge.runner.id) else { return }
            runnerID = challenge.runner.id
            guard challenge.expiresAt > Date() else { return }
            candidatesByPeer[box.peer]?.reconnectChallenge = challenge
            guard let entry = trustByRunnerID[runnerID] else { return }
            candidatesByPeer[box.peer]?.secureSession = DeveloperSessionCipher(
                token: entry.receipt.trustToken,
                challenge: challenge,
                desktopID: desktopID
            )
            let proof = DeveloperAuthentication.desktopProof(
                token: entry.receipt.trustToken,
                challenge: challenge,
                desktopID: desktopID
            )
            do {
                try send(
                    .init(message: .desktopHello(.init(
                        desktopID: desktopID,
                        challengeID: challenge.id,
                        proof: proof
                    ))),
                    to: box
                )
            } catch {
                lastError = error.localizedDescription
            }
        case .pairingChallenge(let challenge):
            guard bindCandidate(box, to: challenge.runner.id) else { return }
            runnerID = challenge.runner.id
            candidatesByPeer[box.peer]?.pairingChallenge = challenge
            pendingPairingChallenges[challenge.runner.id] = challenge
            guard trustByRunnerID[runnerID] == nil
                    || candidatesByPeer[box.peer]?.reconnectWasRejected == true else { return }
            upsertRunner(.init(
                identity: challenge.runner,
                features: [],
                state: .pairingRequired,
                availabilityDetail: "Enter the pairing code before \(challenge.expiresAt.formatted())."
            ))
            if let code = candidatesByPeer[box.peer]?.requestedPairingCode {
                do { try submitPairingProof(code, challenge: challenge, peer: box.peer) }
                catch { lastError = error.localizedDescription }
            }
        case .pairingReceipt(let receipt):
            guard bindCandidate(box, to: receipt.runner.id) else { return }
            runnerID = receipt.runner.id
            guard receipt.desktopID == desktopID,
                  candidatesByPeer[box.peer]?.requestedPairingSessionID == receipt.pairingSessionID,
                  let pairingChallenge = candidatesByPeer[box.peer]?.pairingChallenge,
                  let pairingCode = candidatesByPeer[box.peer]?.requestedPairingCode else {
                lastError = "The runner sent an unsolicited pairing receipt."
                return
            }
            let token: String
            do {
                token = try DeveloperAuthentication.openTrustToken(
                    receipt.sealedTrustToken,
                    code: pairingCode,
                    challenge: pairingChallenge,
                    desktopID: desktopID
                )
            } catch {
                lastError = "The runner could not prove the pairing code."
                return
            }
            let storedReceipt = DeveloperStoredTrustReceipt(
                runner: receipt.runner,
                desktopID: receipt.desktopID,
                trustToken: token,
                issuedAt: receipt.issuedAt
            )
            guard let reconnectChallenge = candidatesByPeer[box.peer]?.reconnectChallenge else {
                lastError = "The runner did not establish a secure session."
                return
            }
            let previous = trustByRunnerID[runnerID]
            trustByRunnerID[runnerID] = .init(endpoint: box.peer.displayName, receipt: storedReceipt)
            do { try persistTrust() }
            catch {
                trustByRunnerID[runnerID] = previous
                candidatesByPeer[box.peer]?.secureSession = nil
                candidatesByPeer[box.peer]?.attemptedTransportAuthentication = false
                clearPairingState(for: runnerID)
                session.disconnect(box.peer)
                lastError = "The trust receipt could not be saved. Check the trust-store location and pair again."
                updateRunner(runnerID) {
                    $0.state = .disconnected
                    $0.availabilityDetail = "The pairing receipt could not be saved."
                }
                return
            }
            candidatesByPeer[box.peer]?.secureSession = DeveloperSessionCipher(
                token: token, challenge: reconnectChallenge, desktopID: desktopID)
            clearPairingState(for: runnerID)
            candidatesByPeer[box.peer]?.reconnectWasRejected = false
            pendingPairingChallenges[receipt.runner.id] = nil
        case .secure(let secure):
            guard var cipher = candidatesByPeer[box.peer]?.secureSession else { return }
            do {
                let message = try cipher.open(secure, direction: .runnerToDesktop)
                candidatesByPeer[box.peer]?.secureSession = cipher
                handleAuthenticated(message, from: box, runnerID: runnerID)
            } catch {
                lastError = "A secure runner message failed authentication."
            }
        case .authenticationFailure(let failure):
            guard failure.desktopID == desktopID,
                  failure.runnerID == runnerID,
                  candidatesByPeer[box.peer]?.reconnectChallenge?.id == failure.reconnectChallengeID else { return }
            candidatesByPeer[box.peer]?.reconnectWasRejected = true
            candidatesByPeer[box.peer]?.secureSession = nil
            lastError = failure.message
            updateRunner(runnerID) {
                $0.state = .pairingRequired
                $0.availabilityDetail = "Saved trust was rejected. Start pairing on the runner and enter its new code."
            }
        case .result(let result):
            guard candidatesByPeer[box.peer]?.requestedPairingSessionID == result.requestID,
                  let failure = result.failure else { return }
            lastError = failure.message
        case .hello, .disconnect:
            break
        case .pairingRequest, .desktopHello, .execute, .cancel:
            break
        }
    }

    /// Publishes a browser startup failure and clears the browsing flag.
    func browserFailed(_ detail: String) {
        isBrowsing = false
        lastError = detail
    }

    /// Checks the secure runner greeting before selecting its peer, then handles correlated
    /// results and disconnects from that authenticated peer. Competing candidates are evicted.
    private func handleAuthenticated(
        _ message: DeveloperAuthenticatedMessage,
        from box: DeveloperPeerBox,
        runnerID: UUID
    ) {
        switch message {
        case .hello(let hello):
            guard hello.runner.id == runnerID,
                  hello.desktopID == desktopID,
                  let challenge = candidatesByPeer[box.peer]?.reconnectChallenge,
                  challenge.id == hello.reconnectChallengeID,
                  challenge.expiresAt > Date(),
                  let entry = trustByRunnerID[runnerID],
                  DeveloperAuthentication.validatesRunnerProof(
                    hello.runnerProof,
                    token: entry.receipt.trustToken,
                    challenge: challenge,
                    desktopID: desktopID
                  ) else {
                lastError = "The runner could not prove its saved trust. Pair it again."
                updateRunner(runnerID) {
                    $0.state = .pairingRequired
                    $0.availabilityDetail = "Runner authentication failed."
                }
                return
            }
            guard authenticatedPeersByRunnerID[runnerID] == nil
                    || authenticatedPeersByRunnerID[runnerID]?.peer == box.peer else {
                evictCandidate(box, runnerID: runnerID)
                return
            }
            session.authenticated(box.peer)
            authenticatedPeersByRunnerID[runnerID] = box
            selectedCandidatePeerByRunnerID[runnerID] = box.peer
            unauthenticatedSessionTimeoutTask?.cancel()
            unauthenticatedSessionTimeoutTask = nil
            candidatesByPeer[box.peer]?.reconnectChallenge = nil
            evictCompetingCandidates(for: runnerID, keeping: box.peer)
            pendingPairingChallenges[runnerID] = nil
            upsertRunner(.init(
                identity: hello.runner,
                features: hello.features,
                state: .connected,
                availabilityDetail: nil
            ))
        case .result(let result):
            guard authenticatedPeersByRunnerID[runnerID]?.peer == box.peer,
                  continuations[result.requestID] != nil else { return }
            if var status = activeRuns[result.runID] {
                status.phase = result.failure == nil ? .completed : phase(for: result.failure?.code)
                status.completedSamples = result.failure == nil ? 1 : 0
                status.detail = result.failure?.message
                activeRuns[result.runID] = status
            }
            finish(requestID: result.requestID, returning: result)
        case .disconnect(let reason):
            guard authenticatedPeersByRunnerID[runnerID]?.peer == box.peer else { return }
            markDisconnected(runnerID: runnerID, detail: reason)
            if activeRunnerID == runnerID { activeRunnerID = nil }
            session.disconnect(box.peer)
        case .execute, .cancel:
            break
        }
    }

    /// Seals a desktop-to-runner message and reliably sends it to the authenticated peer.
    /// Throws when the peer or cipher is missing, or when sealing/transport fails.
    private func sendAuthenticated(_ message: DeveloperAuthenticatedMessage, runnerID: UUID) throws {
        guard let peer = authenticatedPeersByRunnerID[runnerID] else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "The runner connection closed.")
        }
        guard var cipher = candidatesByPeer[peer.peer]?.secureSession else {
            throw DeveloperExecutionFailure(code: .untrustedPeer, message: "The secure runner session is unavailable.")
        }
        let secure = try cipher.seal(message, direction: .desktopToRunner)
        try send(.init(message: .secure(secure)), to: peer)
        candidatesByPeer[peer.peer]?.secureSession = cipher
    }

    /// JSON-encodes an envelope for reliable data transport to a still-connected peer.
    /// Throws `disconnected` for a closed peer, otherwise propagates encoding or send errors.
    private func send(_ envelope: DeveloperRunnerEnvelope, to box: DeveloperPeerBox) throws {
        let peer = box.peer
        guard
              session.connectedPeers.contains(peer) else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "The runner connection closed.")
        }
        try session.send(JSONEncoder().encode(envelope), to: peer)
    }

    /// Expires a still-pending request, attempts remote cancellation and publishes a timed-out phase.
    /// Completes the local wait with `deadlineExceeded`; late timer firings have no effect.
    private func timeout(
        request: DeveloperFeatureExecutionRequest,
        runnerID: UUID
    ) {
        guard continuations[request.id] != nil else { return }
        if authenticatedPeersByRunnerID[runnerID] != nil {
            try? sendAuthenticated(.cancel(requestID: request.id), runnerID: runnerID)
        }
        activeRuns[request.runID]?.phase = .timedOut
        activeRuns[request.runID]?.detail = "The runner did not return before the desktop timeout."
        finish(
            requestID: request.id,
            throwing: DeveloperExecutionFailure(
                code: .deadlineExceeded,
                message: "The runner did not return before the desktop timeout."
            )
        )
    }

    /// Cancels the request timer and resumes its pending continuation once with the result.
    private func finish(requestID: UUID, returning result: DeveloperFeatureExecutionResult) {
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = nil
        continuations.removeValue(forKey: requestID)?.resume(returning: result)
    }

    /// Cancels the request timer and resumes its pending continuation once with an error.
    private func finish(requestID: UUID, throwing error: any Error) {
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = nil
        continuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    /// Clears the runner's authentication and pairing state, marks its running statuses
    /// disconnected, and fails all client continuations with the supplied connection detail.
    private func markDisconnected(runnerID: UUID, detail: String) {
        if let peer = authenticatedPeersByRunnerID[runnerID]?.peer {
            candidatesByPeer[peer]?.secureSession = nil
            candidatesByPeer[peer]?.reconnectChallenge = nil
        }
        authenticatedPeersByRunnerID[runnerID] = nil
        clearPairingState(for: runnerID)
        updateRunner(runnerID) {
            $0.state = .disconnected
            $0.availabilityDetail = detail
            $0.lastSeen = Date()
        }
        let runIDs = activeRuns.values.filter { $0.runnerID == runnerID && $0.phase == .running }.map(\.id)
        for runID in runIDs {
            activeRuns[runID]?.phase = .disconnected
            activeRuns[runID]?.detail = detail
        }
        let requestIDs = continuations.keys
        for requestID in requestIDs {
            finish(
                requestID: requestID,
                throwing: DeveloperExecutionFailure(code: .disconnected, message: detail)
            )
        }
    }

    /// Maps cancellation, deadline and disconnect failures to their matching run phases;
    /// other failure codes, including a missing code, map to failed.
    private func phase(for code: DeveloperExecutionErrorCode?) -> DeveloperRunPhase {
        switch code {
        case .cancelled: .cancelled
        case .deadlineExceeded: .timedOut
        case .disconnected: .disconnected
        default: .failed
        }
    }

    /// Replaces the runner's snapshot by ID and restores localized display-name ordering.
    private func upsertRunner(_ snapshot: DeveloperRunnerSnapshot) {
        runners.removeAll { $0.id == snapshot.id }
        runners.append(snapshot)
        runners.sort { $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending }
    }

    /// Mutates an existing runner snapshot and refreshes its last-seen timestamp.
    private func updateRunner(_ id: UUID, update: (inout DeveloperRunnerSnapshot) -> Void) {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        update(&runners[index])
        runners[index].lastSeen = Date()
    }

    /// Binds an endpoint to a handshake's runner ID unless another peer is authenticated for it.
    /// Removes obsolete placeholder identity and promotes remaining old candidates when rebinding.
    private func bindCandidate(_ box: DeveloperPeerBox, to runnerID: UUID) -> Bool {
        if let authenticated = authenticatedPeersByRunnerID[runnerID], authenticated.peer != box.peer {
            return false
        }
        if let previousID = candidatesByPeer[box.peer]?.runnerID, previousID != runnerID {
            if selectedCandidatePeerByRunnerID[previousID] == box.peer {
                selectedCandidatePeerByRunnerID[previousID] = nil
                promoteCandidate(for: previousID, excluding: box.peer)
            }
            if authenticatedPeersByRunnerID[previousID] == nil {
                runners.removeAll { $0.id == previousID }
            }
            candidatesByPeer[box.peer] = DeveloperClientCandidate(
                runnerID: runnerID,
                endpoint: box.peer.displayName
            )
        } else if candidatesByPeer[box.peer] == nil {
            candidatesByPeer[box.peer] = DeveloperClientCandidate(
                runnerID: runnerID,
                endpoint: box.peer.displayName
            )
        }
        selectedCandidatePeerByRunnerID[runnerID] = box.peer
        activeRunnerID = runnerID
        return true
    }

    /// Starts one 60-second authentication timer while no peer is authenticated.
    private func startUnauthenticatedSessionTimeoutIfNeeded() {
        guard unauthenticatedSessionTimeoutTask == nil,
              authenticatedPeersByRunnerID.isEmpty else { return }
        unauthenticatedSessionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self, self.authenticatedPeersByRunnerID.isEmpty else { return }
            self.resetUnauthenticatedSession()
        }
    }

    /// Disconnects an unauthenticated session, retaining discoverable endpoints for retry
    /// while clearing challenge, cipher, pairing and invitation ownership state.
    private func resetUnauthenticatedSession() {
        let runnerIDs = Set(candidatesByPeer.values.map(\.runnerID))
        session.disconnect()
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        candidatesByPeer = candidatesByPeer.filter { $0.value.isDiscoverable }
        for peer in candidatesByPeer.keys {
            candidatesByPeer[peer]?.reconnectChallenge = nil
            candidatesByPeer[peer]?.secureSession = nil
        }
        selectedCandidatePeerByRunnerID = selectedCandidatePeerByRunnerID.filter { candidatesByPeer[$0.value] != nil }
        activeRunnerID = nil
        connectingPeers.removeAll()
        for runnerID in runnerIDs {
            clearPairingState(for: runnerID)
            updateRunner(runnerID) {
                $0.state = .disconnected
                $0.availabilityDetail = "Authentication timed out. Reconnect to try again."
            }
        }
    }

    /// Releases the active runner after its last invitation and transport connection fail,
    /// then marks it disconnected so another runner can use the session.
    private func releaseFailedConnectionIfNeeded(_ runnerID: UUID) {
        guard activeRunnerID == runnerID,
              authenticatedPeersByRunnerID[runnerID] == nil,
              !connectingPeers.contains(where: { candidatesByPeer[$0]?.runnerID == runnerID }),
              !session.connectedPeers.contains(where: { candidatesByPeer[$0]?.runnerID == runnerID }) else { return }
        activeRunnerID = nil
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        markDisconnected(runnerID: runnerID, detail: "The connection failed. Reconnect to try again.")
    }

    /// Removes a candidate endpoint and promotes another connected endpoint if it was selected.
    private func evictCandidate(_ box: DeveloperPeerBox, runnerID: UUID) {
        candidatesByPeer[box.peer] = nil
        connectingPeers.remove(box.peer)
        session.disconnect(box.peer)
        if selectedCandidatePeerByRunnerID[runnerID] == box.peer {
            selectedCandidatePeerByRunnerID[runnerID] = nil
            promoteCandidate(for: runnerID, excluding: box.peer)
        }
    }

    /// Evicts other endpoints for an authenticated runner while retaining the chosen peer.
    private func evictCompetingCandidates(for runnerID: UUID, keeping peer: DeveloperPeerID) {
        let competingPeers = candidatesByPeer.compactMap { candidatePeer, candidate in
            candidate.runnerID == runnerID && candidatePeer != peer ? candidatePeer : nil
        }
        for candidatePeer in competingPeers {
            evictCandidate(DeveloperPeerBox(candidatePeer), runnerID: runnerID)
        }
        selectedCandidatePeerByRunnerID[runnerID] = peer
    }

    /// Selects another connected candidate for a runner that has no authenticated peer.
    private func promoteCandidate(for runnerID: UUID, excluding peer: DeveloperPeerID) {
        guard authenticatedPeersByRunnerID[runnerID] == nil else { return }
        guard let candidatePeer = candidatesByPeer.first(where: { candidatePeer, candidate in
            candidate.runnerID == runnerID
                && candidatePeer != peer
                && session.connectedPeers.contains(candidatePeer)
        })?.key else { return }
        selectedCandidatePeerByRunnerID[runnerID] = candidatePeer
    }

    /// Clears all pending pairing challenges, requested codes and session IDs for this runner.
    private func clearPairingState(for runnerID: UUID) {
        let peers = candidatesByPeer.compactMap { peer, candidate in
            candidate.runnerID == runnerID ? peer : nil
        }
        for peer in peers {
            candidatesByPeer[peer]?.pairingChallenge = nil
            candidatesByPeer[peer]?.requestedPairingSessionID = nil
            candidatesByPeer[peer]?.requestedPairingCode = nil
        }
        pendingPairingChallenges[runnerID] = nil
    }

    /// Atomically writes desktop trust receipts when a store URL is configured.
    /// Creates the parent directory and attempts owner-only permissions; encoding or write errors propagate.
    private func persistTrust() throws {
        guard let trustStoreURL else { return }
        try FileManager.default.createDirectory(
            at: trustStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries = Array(trustByRunnerID.values)
        let data = try JSONEncoder().encode(DeveloperDesktopTrustState(entries: entries))
        try data.write(to: trustStoreURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: trustStoreURL.path
        )
    }
}

extension DeveloperRunnerClient: DeveloperSessionOwner {}
