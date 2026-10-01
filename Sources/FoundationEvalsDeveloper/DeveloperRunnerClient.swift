import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

private final class DeveloperPeerBox: @unchecked Sendable {
    let peer: MCPeerID
    init(_ peer: MCPeerID) { self.peer = peer }
}

private struct DeveloperClientCandidate {
    var runnerID: UUID
    var endpoint: String
    var reconnectChallenge: DeveloperReconnectChallenge?
    var pairingChallenge: DeveloperPairingChallenge?
    var requestedPairingSessionID: UUID?
    var requestedPairingCode: String?
    var secureSession: DeveloperSessionCipher?
    var reconnectWasRejected = false
}

private final class DeveloperClientSessionDelegate: NSObject, MCSessionDelegate, @unchecked Sendable {
    weak var owner: DeveloperRunnerClient?

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = DeveloperPeerBox(peerID)
        Task { @MainActor [weak owner] in
            owner?.peerChanged(peer, state: state)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peer = DeveloperPeerBox(peerID)
        Task { @MainActor [weak owner] in
            owner?.received(data, from: peer)
        }
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}
}

private final class DeveloperClientBrowserDelegate: NSObject, MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    weak var owner: DeveloperRunnerClient?

    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let box = DeveloperPeerBox(peerID)
        let runnerID = info?["runnerID"].flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak owner] in
            owner?.found(box, runnerID: runnerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let box = DeveloperPeerBox(peerID)
        Task { @MainActor [weak owner] in
            owner?.lostPeer(box)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        let detail = error.localizedDescription
        Task { @MainActor [weak owner] in
            owner?.browserFailed(detail)
        }
    }
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

struct DeveloperIntentionalDisconnects {
    private var peers: Set<MCPeerID> = []

    mutating func begin(for peer: MCPeerID) {
        peers.insert(peer)
    }

    mutating func consume(for peer: MCPeerID) -> Bool {
        peers.remove(peer) != nil
    }

    mutating func forget(_ peer: MCPeerID) {
        peers.remove(peer)
    }

    mutating func removeAll() {
        peers.removeAll()
    }
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
    @ObservationIgnored private let peerID: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private let sessionDelegate: DeveloperClientSessionDelegate
    @ObservationIgnored private let browserDelegate: DeveloperClientBrowserDelegate
    @ObservationIgnored private let browser: MCNearbyServiceBrowser
    @ObservationIgnored private var selectedCandidatePeerByRunnerID: [UUID: MCPeerID] = [:]
    @ObservationIgnored private var authenticatedPeersByRunnerID: [UUID: DeveloperPeerBox] = [:]
    @ObservationIgnored private var candidatesByPeer: [MCPeerID: DeveloperClientCandidate] = [:]
    @ObservationIgnored private var trustByRunnerID: [UUID: DeveloperDesktopTrustState.Entry] = [:]
    @ObservationIgnored private var activeRunnerID: UUID?
    @ObservationIgnored private var intentionalDisconnects = DeveloperIntentionalDisconnects()
    @ObservationIgnored private var unauthenticatedSessionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<DeveloperFeatureExecutionResult, any Error>] = [:]
    @ObservationIgnored private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        desktopID: UUID,
        displayName: String = "Foundation Evals",
        trustStoreURL: URL? = nil
    ) {
        self.desktopID = desktopID
        self.trustStoreURL = trustStoreURL
        peerID = MCPeerID(displayName: developerPeerDisplayName(displayName, id: desktopID))
        sessionDelegate = DeveloperClientSessionDelegate()
        browserDelegate = DeveloperClientBrowserDelegate()
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: developerRunnerServiceType)

        if let trustStoreURL,
           let data = try? Data(contentsOf: trustStoreURL),
           let state = try? JSONDecoder().decode(DeveloperDesktopTrustState.self, from: data) {
            trustByRunnerID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.receipt.runner.id, $0) })
        }

        sessionDelegate.owner = self
        browserDelegate.owner = self
        session.delegate = sessionDelegate
        browser.delegate = browserDelegate
    }

    public func startBrowsing() {
        guard !isBrowsing else { return }
        browser.startBrowsingForPeers()
        isBrowsing = true
        lastError = nil
    }

    public func stopBrowsing() {
        guard isBrowsing else { return }
        browser.stopBrowsingForPeers()
        isBrowsing = false
    }

    public func shutdown() {
        stopBrowsing()
        session.disconnect()
        authenticatedPeersByRunnerID = [:]
        candidatesByPeer = [:]
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        selectedCandidatePeerByRunnerID = [:]
        activeRunnerID = nil
        intentionalDisconnects.removeAll()
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

    public func connect(to runnerID: UUID, timeout: TimeInterval = 20) throws {
        let peers = candidatesByPeer.compactMap { peer, candidate in
            candidate.runnerID == runnerID ? peer : nil
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
        activeRunnerID = runnerID
        updateRunner(runnerID) {
            $0.state = .connecting
            $0.availabilityDetail = nil
        }
        for peer in peers {
            browser.invitePeer(peer, to: session, withContext: nil, timeout: timeout)
        }
    }

    public func trustRunner(_ runnerID: UUID, pairingCode: String) throws {
        let candidates = candidatesByPeer.compactMap { peer, candidate -> (DeveloperPeerBox, DeveloperPairingChallenge)? in
            guard candidate.runnerID == runnerID,
                  let challenge = candidate.pairingChallenge,
                  challenge.expiresAt > Date(),
                  session.connectedPeers.contains(peer) else { return nil }
            return (DeveloperPeerBox(peer), challenge)
        }
        guard !candidates.isEmpty else {
            throw DeveloperExecutionFailure(
                code: .untrustedPeer,
                message: "The runner is not offering an active pairing session."
            )
        }

        var sendFailures: [any Error] = []
        for (peer, challenge) in candidates {
            let request = DeveloperPairingRequest(
                pairingSessionID: challenge.pairingSessionID,
                proof: DeveloperAuthentication.pairingProof(
                    code: pairingCode,
                    challenge: challenge,
                    desktopID: desktopID
                ),
                desktopID: desktopID
            )
            candidatesByPeer[peer.peer]?.requestedPairingSessionID = challenge.pairingSessionID
            candidatesByPeer[peer.peer]?.requestedPairingCode = pairingCode
            do {
                try send(.init(message: .pairingRequest(request)), to: peer)
            } catch {
                candidatesByPeer[peer.peer]?.requestedPairingSessionID = nil
                candidatesByPeer[peer.peer]?.requestedPairingCode = nil
                sendFailures.append(error)
            }
        }
        if sendFailures.count == candidates.count, let failure = sendFailures.first { throw failure }
    }

    public func disconnect(_ runnerID: UUID) {
        guard selectedCandidatePeerByRunnerID[runnerID] != nil || authenticatedPeersByRunnerID[runnerID] != nil else { return }
        guard activeRunnerID == runnerID else {
            markDisconnected(runnerID: runnerID, detail: "Disconnected by the user.")
            return
        }
        try? sendAuthenticated(.disconnect(reason: "Disconnected by the user."), runnerID: runnerID)
        if let peer = authenticatedPeersByRunnerID[runnerID]?.peer {
            intentionalDisconnects.begin(for: peer)
        }
        session.disconnect()
        activeRunnerID = nil
        markDisconnected(runnerID: runnerID, detail: "Disconnected by the user.")
    }

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

    fileprivate func found(_ box: DeveloperPeerBox, runnerID advertisedRunnerID: UUID?) {
        let endpoint = box.peer.displayName
        let runnerID = advertisedRunnerID ?? candidatesByPeer[box.peer]?.runnerID ?? UUID()
        if let authenticated = authenticatedPeersByRunnerID[runnerID], authenticated.peer != box.peer { return }
        if candidatesByPeer[box.peer]?.runnerID == runnerID {
            candidatesByPeer[box.peer]?.endpoint = endpoint
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
                activeRunnerID = runnerID
                browser.invitePeer(box.peer, to: session, withContext: nil, timeout: 20)
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
                browser.invitePeer(box.peer, to: session, withContext: nil, timeout: 20)
            }
        }
    }

    fileprivate func lostPeer(_ box: DeveloperPeerBox) {
        intentionalDisconnects.forget(box.peer)
        guard let runnerID = candidatesByPeer[box.peer]?.runnerID else { return }
        candidatesByPeer[box.peer] = nil
        if selectedCandidatePeerByRunnerID[runnerID] == box.peer {
            selectedCandidatePeerByRunnerID[runnerID] = nil
            promoteCandidate(for: runnerID, excluding: box.peer)
        }
        if authenticatedPeersByRunnerID[runnerID]?.peer == box.peer {
            authenticatedPeersByRunnerID[runnerID] = nil
            activeRunnerID = nil
            markDisconnected(runnerID: runnerID, detail: "Runner discovery was lost.")
        }
    }

    fileprivate func peerChanged(_ box: DeveloperPeerBox, state: MCSessionState) {
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
            let retainDiscoveredCandidate = intentionalDisconnects.consume(for: box.peer)
            candidatesByPeer[box.peer]?.reconnectChallenge = nil
            candidatesByPeer[box.peer]?.secureSession = nil
            if authenticatedPeersByRunnerID[runnerID]?.peer == box.peer {
                authenticatedPeersByRunnerID[runnerID] = nil
                activeRunnerID = nil
                markDisconnected(runnerID: runnerID, detail: "Runner disconnected.")
            } else if !retainDiscoveredCandidate {
                evictCandidate(box, runnerID: runnerID)
            }
        @unknown default:
            if authenticatedPeersByRunnerID[runnerID]?.peer == box.peer {
                authenticatedPeersByRunnerID[runnerID] = nil
                activeRunnerID = nil
                markDisconnected(runnerID: runnerID, detail: "Runner entered an unknown connection state.")
            }
        }
    }

    fileprivate func received(_ data: Data, from box: DeveloperPeerBox) {
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
            trustByRunnerID[runnerID] = .init(endpoint: box.peer.displayName, receipt: storedReceipt)
            guard let reconnectChallenge = candidatesByPeer[box.peer]?.reconnectChallenge else {
                lastError = "The runner did not establish a secure session."
                return
            }
            candidatesByPeer[box.peer]?.secureSession = DeveloperSessionCipher(
                token: token,
                challenge: reconnectChallenge,
                desktopID: desktopID
            )
            clearPairingState(for: runnerID)
            candidatesByPeer[box.peer]?.reconnectWasRejected = false
            pendingPairingChallenges[receipt.runner.id] = nil
            do {
                try persistTrust()
            } catch {
                lastError = "The runner paired, but its trust receipt could not be saved."
            }
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

    fileprivate func browserFailed(_ detail: String) {
        isBrowsing = false
        lastError = detail
    }

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
        case .execute, .cancel:
            break
        }
    }

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

    private func send(_ envelope: DeveloperRunnerEnvelope, to box: DeveloperPeerBox) throws {
        let peer = box.peer
        guard
              session.connectedPeers.contains(peer) else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "The runner connection closed.")
        }
        try session.send(JSONEncoder().encode(envelope), toPeers: [peer], with: .reliable)
    }

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

    private func finish(requestID: UUID, returning result: DeveloperFeatureExecutionResult) {
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = nil
        continuations.removeValue(forKey: requestID)?.resume(returning: result)
    }

    private func finish(requestID: UUID, throwing error: any Error) {
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = nil
        continuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

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

    private func phase(for code: DeveloperExecutionErrorCode?) -> DeveloperRunPhase {
        switch code {
        case .cancelled: .cancelled
        case .deadlineExceeded: .timedOut
        case .disconnected: .disconnected
        default: .failed
        }
    }

    private func upsertRunner(_ snapshot: DeveloperRunnerSnapshot) {
        runners.removeAll { $0.id == snapshot.id }
        runners.append(snapshot)
        runners.sort { $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending }
    }

    private func updateRunner(_ id: UUID, update: (inout DeveloperRunnerSnapshot) -> Void) {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        update(&runners[index])
        runners[index].lastSeen = Date()
    }

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

    private func resetUnauthenticatedSession() {
        let runnerIDs = Set(candidatesByPeer.values.map(\.runnerID))
        session.disconnect()
        unauthenticatedSessionTimeoutTask?.cancel()
        unauthenticatedSessionTimeoutTask = nil
        candidatesByPeer = [:]
        selectedCandidatePeerByRunnerID = [:]
        activeRunnerID = nil
        intentionalDisconnects.removeAll()
        for runnerID in runnerIDs {
            pendingPairingChallenges[runnerID] = nil
            updateRunner(runnerID) {
                $0.state = .disconnected
                $0.availabilityDetail = "Authentication timed out. Reconnect to try again."
            }
        }
    }

    private func evictCandidate(_ box: DeveloperPeerBox, runnerID: UUID) {
        candidatesByPeer[box.peer] = nil
        if selectedCandidatePeerByRunnerID[runnerID] == box.peer {
            selectedCandidatePeerByRunnerID[runnerID] = nil
            promoteCandidate(for: runnerID, excluding: box.peer)
        }
    }

    private func evictCompetingCandidates(for runnerID: UUID, keeping peer: MCPeerID) {
        let competingPeers = candidatesByPeer.compactMap { candidatePeer, candidate in
            candidate.runnerID == runnerID && candidatePeer != peer ? candidatePeer : nil
        }
        for candidatePeer in competingPeers {
            evictCandidate(DeveloperPeerBox(candidatePeer), runnerID: runnerID)
        }
        selectedCandidatePeerByRunnerID[runnerID] = peer
    }

    private func promoteCandidate(for runnerID: UUID, excluding peer: MCPeerID) {
        guard authenticatedPeersByRunnerID[runnerID] == nil else { return }
        guard let candidatePeer = candidatesByPeer.first(where: { candidatePeer, candidate in
            candidate.runnerID == runnerID
                && candidatePeer != peer
                && session.connectedPeers.contains(candidatePeer)
        })?.key else { return }
        selectedCandidatePeerByRunnerID[runnerID] = candidatePeer
    }

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
