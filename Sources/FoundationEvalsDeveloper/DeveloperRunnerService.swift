import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

let developerRunnerServiceType = "fnd-evals"

private final class DeveloperRunnerPeerBox: @unchecked Sendable {
    let peer: MCPeerID
    init(_ peer: MCPeerID) { self.peer = peer }
}

private final class DeveloperRunnerSessionDelegate: NSObject, MCSessionDelegate, @unchecked Sendable {
    weak var owner: DeveloperRunnerService?
    var session: MCSession?

    // MultipeerConnectivity calls these methods on its own queues. The proxy is
    // @unchecked Sendable because it only copies Data/String values across to
    // MainActor, while `session` is assigned once before advertising begins.
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = DeveloperRunnerPeerBox(peerID)
        Task { @MainActor [weak owner] in
            owner?.peerChanged(peer, state: state)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peer = DeveloperRunnerPeerBox(peerID)
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

private final class DeveloperRunnerAdvertiserDelegate: NSObject, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {
    weak var owner: DeveloperRunnerService?
    var session: MCSession?

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
    @ObservationIgnored private let sessionDelegate: DeveloperRunnerSessionDelegate
    @ObservationIgnored private let advertiserDelegate: DeveloperRunnerAdvertiserDelegate
    @ObservationIgnored private let advertiser: MCNearbyServiceAdvertiser
    @ObservationIgnored private var connectionIDs: [MCPeerID: String] = [:]
    @ObservationIgnored private var secureEnvelopeBuffersByPeer: [MCPeerID: DeveloperSecureEnvelopeBuffer] = [:]
    @ObservationIgnored private var inboundAcceptanceTasksByPeer: [MCPeerID: Task<Void, Never>] = [:]

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
        sessionDelegate = DeveloperRunnerSessionDelegate()
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
        sessionDelegate.session = session
        advertiserDelegate.owner = self
        advertiserDelegate.session = session
        session.delegate = sessionDelegate
        advertiser.delegate = advertiserDelegate
    }

    public func start() {
        guard !isAdvertising else { return }
        advertiser.startAdvertisingPeer()
        isAdvertising = true
        lastError = nil
    }

    public func refreshFeatures() async {
        features = await registry.descriptors
    }

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
            let peerBox = DeveloperRunnerPeerBox(peer)
            for challenge in challenges {
                send(challenge, peer: peerBox)
            }
        }
        return state
    }

    public func cancelPairing() async {
        await engine.stopPairing()
        pairingState = .idle
    }

    public func refreshPairingState() async {
        pairingState = await engine.pairingState()
    }

    fileprivate func peerChanged(_ peer: DeveloperRunnerPeerBox, state: MCSessionState) {
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

    fileprivate func received(_ data: Data, from peer: DeveloperRunnerPeerBox) {
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

    private func perform(
        _ action: DeveloperHostTransportAction,
        connectionID: String,
        peer: DeveloperRunnerPeerBox
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

    fileprivate func advertisingFailed(_ detail: String) {
        isAdvertising = false
        lastError = detail
    }

    private func updateAuthenticatedPeer(name: String, authenticated: Bool) {
        if authenticated {
            if !connectedDesktopNames.contains(name) {
                connectedDesktopNames.append(name)
            }
        } else {
            connectedDesktopNames.removeAll { $0 == name }
        }
    }

    private func send(_ envelope: DeveloperRunnerEnvelope, peer: DeveloperRunnerPeerBox) {
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

    private func sendImmediately(_ envelope: DeveloperRunnerEnvelope, peer: DeveloperRunnerPeerBox) {
        guard session.connectedPeers.contains(peer.peer) else { return }
        do {
            try session.send(JSONEncoder().encode(envelope), toPeers: [peer.peer], with: .reliable)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
