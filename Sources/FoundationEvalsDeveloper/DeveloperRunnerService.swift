import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

let developerRunnerServiceType = "fnd-evals"

private final class DeveloperRunnerAdvertiserDelegate: NSObject, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {
    weak var owner: DeveloperRunnerService?
    var session: MCSession?

    /// Accepts the transport invitation when a session is available; host-level code proofs
    /// and saved trust still gate authentication and execution after transport connection.
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard let session else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    /// Copies the advertising failure description into main-actor service state.
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        let detail = error.localizedDescription
        Task { @MainActor [weak owner] in
            owner?.advertisingFailed(detail)
        }
    }
}

@MainActor
@Observable
public final class DeveloperRunnerService {
    public let identity: DeveloperRunnerIdentity
    public let registry: DeveloperFeatureRegistry
    public private(set) var isAdvertising = false
    public private(set) var pairingState: DeveloperPairingPresentationState = .idle
    public private(set) var connectedDesktopNames: [String] = []
    public private(set) var features: [DeveloperFeatureDescriptor] = []
    public private(set) var lastError: String?

    @ObservationIgnored private let engine: DeveloperRunnerHostEngine
    @ObservationIgnored private let peerID: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private let sessionDelegate: DeveloperSessionDelegate
    @ObservationIgnored private let advertiserDelegate: DeveloperRunnerAdvertiserDelegate
    @ObservationIgnored private let advertiser: MCNearbyServiceAdvertiser
    @ObservationIgnored private var connectionIDs: [MCPeerID: String] = [:]
    @ObservationIgnored private var secureEnvelopeBuffersByPeer: [MCPeerID: DeveloperSecureEnvelopeBuffer] = [:]
    @ObservationIgnored private var inboundAcceptanceTasksByPeer: [MCPeerID: Task<Void, Never>] = [:]

    /// Creates an encrypted nearby transport and host engine without starting advertising.
    /// - Parameters:
    ///   - identity: Runner identity used for discovery labels and authenticated handshakes.
    ///   - registry: App-owned features available to authenticated desktops.
    ///   - trustStoreURL: Optional token file; `nil` retains trust only for this service instance.
    public init(
        identity: DeveloperRunnerIdentity,
        registry: DeveloperFeatureRegistry,
        trustStoreURL: URL? = nil
    ) {
        self.identity = identity
        self.registry = registry
        engine = DeveloperRunnerHostEngine(
            identity: identity,
            registry: registry,
            trustStore: DeveloperTrustStore(fileURL: trustStoreURL)
        )
        peerID = MCPeerID(displayName: developerPeerDisplayName(identity.displayName, id: identity.id))
        sessionDelegate = DeveloperSessionDelegate()
        advertiserDelegate = DeveloperRunnerAdvertiserDelegate()
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["runnerID": identity.id.uuidString],
            serviceType: developerRunnerServiceType
        )
        sessionDelegate.owner = self
        advertiserDelegate.owner = self
        advertiserDelegate.session = session
        session.delegate = sessionDelegate
        advertiser.delegate = advertiserDelegate
    }

    /// Starts nearby advertising once and clears the previous advertising error.
    public func start() {
        guard !isAdvertising else { return }
        advertiser.startAdvertisingPeer()
        isAdvertising = true
        lastError = nil
    }

    /// Refreshes the published feature list from the registry for companion UI presentation.
    public func refreshFeatures() async {
        features = await registry.descriptors
    }

    /// Stops advertising and transport connections, requests cancellation of all active feature
    /// operations, ends pairing and clears published connection and inbound-queue state.
    /// Cooperative cancellation is requested without waiting for feature operations to finish.
    public func stop() async {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        await registry.cancelAll()
        await engine.stopPairing()
        isAdvertising = false
        pairingState = .idle
        connectedDesktopNames = []
        connectionIDs = [:]
        secureEnvelopeBuffersByPeer = [:]
        inboundAcceptanceTasksByPeer.values.forEach { $0.cancel() }
        inboundAcceptanceTasksByPeer = [:]
    }

    /// Starts advertising and replaces pairing with a new code, refreshing challenges
    /// for connections that are already open and unauthenticated.
    /// - Parameter duration: Pairing code lifetime passed to the host engine.
    /// - Returns: The new pairing presentation state also stored in `pairingState`.
    @discardableResult
    public func beginPairing(duration: Duration = .seconds(300)) async -> DeveloperPairingPresentationState {
        start()
        let state = await engine.beginPairing(
            endpoint: peerID.displayName,
            duration: duration
        )
        pairingState = state
        for (peer, connectionID) in connectionIDs {
            let challenges = await engine.pairingChallenges(for: connectionID)
            guard connectionIDs[peer] == connectionID else { continue }
            let peerBox = DeveloperPeerBox(peer)
            for challenge in challenges {
                send(challenge, peer: peerBox)
            }
        }
        return state
    }

    /// Ends the current pairing session and resets its presentation without stopping advertising.
    public func cancelPairing() async {
        await engine.stopPairing()
        pairingState = .idle
    }

    /// Refreshes published pairing state, allowing the host engine to expire an elapsed code.
    public func refreshPairingState() async {
        pairingState = await engine.pairingState()
    }

    /// Tracks transport connections, starts handshake challenges on connection and informs
    /// the host engine on closure so owned requests can be cancelled.
    func peerChanged(_ peer: DeveloperPeerBox, state: MCSessionState) {
        let name = peer.peer.displayName
        switch state {
        case .connected:
            let connectionID = connectionIDs[peer.peer] ?? UUID().uuidString
            connectionIDs[peer.peer] = connectionID
            secureEnvelopeBuffersByPeer[peer.peer] = .init()
            Task { @concurrent [weak self] in
                guard let self else { return }
                let challenges = await self.engine.connectionOpened(id: connectionID)
                for challenge in challenges {
                    await self.send(challenge, peer: peer)
                }
            }
        case .notConnected:
            connectedDesktopNames.removeAll { $0 == name }
            let connectionID = connectionIDs.removeValue(forKey: peer.peer)
            secureEnvelopeBuffersByPeer[peer.peer] = nil
            inboundAcceptanceTasksByPeer[peer.peer] = nil
            Task { @concurrent [weak self] in
                if let connectionID {
                    await self?.engine.connectionClosed(id: connectionID)
                }
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    /// Decodes wire data and serializes admission behind earlier messages from the same peer.
    /// Execution completion runs separately, allowing later cancellation to reach the host engine;
    /// authentication and pairing presentation are refreshed after admission.
    func received(_ data: Data, from peer: DeveloperPeerBox) {
        let envelope: DeveloperRunnerEnvelope
        do {
            envelope = try JSONDecoder().decode(DeveloperRunnerEnvelope.self, from: data)
        } catch {
            lastError = "A runner message could not be decoded."
            return
        }
        guard connectionIDs[peer.peer] != nil else {
            lastError = "A message arrived before the runner connection was established."
            return
        }
        let previous = inboundAcceptanceTasksByPeer[peer.peer]
        inboundAcceptanceTasksByPeer[peer.peer] = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  let connectionID = self.connectionIDs[peer.peer] else { return }
            let action = await self.engine.accept(envelope, connectionID: connectionID)
            self.perform(action, connectionID: connectionID, peer: peer)
            let authenticated = await self.engine.authenticatedDesktopID(for: connectionID) != nil
            self.updateAuthenticatedPeer(name: peer.peer.displayName, authenticated: authenticated)
            await self.refreshPairingState()
        }
    }

    /// Sends immediate host responses or resolves accepted executions in a separate task,
    /// keeping the inbound acceptance queue available for subsequent messages.
    private func perform(
        _ action: DeveloperHostTransportAction,
        connectionID: String,
        peer: DeveloperPeerBox
    ) {
        switch action {
        case .respond(let responses):
            for response in responses {
                send(response, peer: peer)
            }
        case .execute:
            Task { @concurrent [weak self] in
                guard let self else { return }
                let responses = await self.engine.resolve(action, connectionID: connectionID)
                for response in responses {
                    await self.send(response, peer: peer)
                }
            }
        }
    }

    /// Publishes an advertising failure and clears the active-advertising flag.
    fileprivate func advertisingFailed(_ detail: String) {
        isAdvertising = false
        lastError = detail
    }

    /// Adds or removes a peer's display name according to host-level authentication state.
    private func updateAuthenticatedPeer(name: String, authenticated: Bool) {
        if authenticated {
            if !connectedDesktopNames.contains(name) {
                connectedDesktopNames.append(name)
            }
        } else {
            connectedDesktopNames.removeAll { $0 == name }
        }
    }

    /// Orders outbound secure envelopes by sequence before sending their contiguous prefix.
    /// Handshake messages bypass this secure-message buffer.
    private func send(_ envelope: DeveloperRunnerEnvelope, peer: DeveloperPeerBox) {
        if case .secure = envelope.message {
            var buffer = secureEnvelopeBuffersByPeer[peer.peer, default: .init()]
            let ready = buffer.insert(envelope)
            secureEnvelopeBuffersByPeer[peer.peer] = buffer
            for readyEnvelope in ready {
                sendImmediately(readyEnvelope, peer: peer)
            }
            return
        }
        sendImmediately(envelope, peer: peer)
    }

    /// Reliably sends an encoded envelope to a still-connected peer, recording send/encoding
    /// errors in `lastError` and silently dropping messages after transport disconnect.
    private func sendImmediately(_ envelope: DeveloperRunnerEnvelope, peer: DeveloperPeerBox) {
        guard session.connectedPeers.contains(peer.peer) else { return }
        do {
            try session.send(JSONEncoder().encode(envelope), toPeers: [peer.peer], with: .reliable)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension DeveloperRunnerService: DeveloperSessionOwner {}
