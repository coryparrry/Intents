import Foundation
import Network
import Observation

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
    @ObservationIgnored private let session = DeveloperNetworkSession()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerCredentials: [DeveloperTransportCredential]?
    @ObservationIgnored private var listenerGeneration = UUID()
    @ObservationIgnored private var advertisingRequested = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var authenticatedDesktopsByPeer: [DeveloperPeerID: UUID] = [:]
    @ObservationIgnored private var connectionIDs: [DeveloperPeerID: String] = [:]
    @ObservationIgnored private var secureEnvelopeBuffersByPeer: [DeveloperPeerID: DeveloperSecureEnvelopeBuffer] = [:]
    @ObservationIgnored private var inboundAcceptanceTasksByPeer: [DeveloperPeerID: Task<Void, Never>] = [:]

    /// The current listener port, for explicit loopback transport integration.
    var listeningPort: NWEndpoint.Port? { listener?.port }

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
        session.owner = self
    }

    /// Starts nearby advertising once and clears the previous advertising error.
    public func start() {
        guard !advertisingRequested || listener == nil else { return }
        advertisingRequested = true
        lastError = nil
        Task { [weak self] in await self?.refreshListener() }
    }

    /// Replaces the listener only when active pairing or saved reconnect keys change.
    /// Existing accepted sockets retain their own generation and engine admission checks.
    private func refreshListener() async {
        guard advertisingRequested else { return }
        let generation = UUID()
        listenerGeneration = generation
        var credentials = await engine.trustStore.transportCredentials(runnerID: identity.id)
        if case .advertising(let code, _, let expiresAt) = pairingState, expiresAt > Date(),
           let credential = try? DeveloperTransportCredential.pairing(code: code, runnerID: identity.id) {
            credentials.append(credential)
        }
        credentials.sort { $0.identity < $1.identity }
        guard advertisingRequested, listenerGeneration == generation else { return }
        guard credentials != listenerCredentials else { return }
        listener?.cancel()
        listener = nil
        isAdvertising = false
        listenerCredentials = credentials
        expiryTask?.cancel()
        if case .advertising(_, _, let expiry) = pairingState {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
                await self?.refreshPairingState()
            }
        }
        do {
            let listener = try NWListener(using: DeveloperTransportCredential.parameters(credentials))
            listener.service = NWListener.Service(name: developerBonjourServiceName(identity.displayName, id: identity.id),
                type: developerRunnerServiceType)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, self.listener === listener else { connection.cancel(); return }
                    self.session.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.isAdvertising = true
                    case .failed(let error), .waiting(let error):
                        self.isAdvertising = false
                        self.lastError = error.localizedDescription
                        self.listenerCredentials = nil
                        self.listener?.cancel()
                        self.listener = nil
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        } catch {
            listenerCredentials = nil
            lastError = error.localizedDescription
        }
    }

    /// Refreshes the published feature list from the registry for companion UI presentation.
    public func refreshFeatures() async {
        features = await registry.descriptors
    }

    /// Stops advertising and transport connections, requests cancellation of all active feature
    /// operations, ends pairing and clears published connection and inbound-queue state.
    /// Cooperative cancellation is requested without waiting for feature operations to finish.
    public func stop() async {
        advertisingRequested = false
        listenerGeneration = UUID()
        listener?.cancel()
        listener = nil
        listenerCredentials = nil
        expiryTask?.cancel()
        expiryTask = nil
        session.disconnect()
        await registry.cancelAll()
        await engine.stopPairing()
        isAdvertising = false
        pairingState = .idle
        connectedDesktopNames = []
        authenticatedDesktopsByPeer = [:]
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
            endpoint: identity.displayName,
            duration: duration
        )
        pairingState = state
        await refreshListener()
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
        await refreshListener()
    }

    /// Refreshes published pairing state, allowing the host engine to expire an elapsed code.
    public func refreshPairingState() async {
        pairingState = await engine.pairingState()
        await refreshListener()
    }

    /// Tracks transport connections, starts handshake challenges on connection and informs
    /// the host engine on closure so owned requests can be cancelled.
    func peerChanged(_ peer: DeveloperPeerBox, state: DeveloperSessionState) {
        switch state {
        case .connected:
            let connectionID = connectionIDs[peer.peer] ?? UUID().uuidString
            connectionIDs[peer.peer] = connectionID
            secureEnvelopeBuffersByPeer[peer.peer] = .init()
            Task { [weak self] in
                guard let self else { return }
                let challenges = await self.engine.connectionOpened(id: connectionID)
                guard self.connectionIDs[peer.peer] == connectionID else {
                    await self.engine.connectionClosed(id: connectionID)
                    return
                }
                for challenge in challenges { self.send(challenge, peer: peer) }
            }
        case .notConnected:
            updateAuthenticatedPeer(peer.peer, desktopID: nil)
            let connectionID = connectionIDs.removeValue(forKey: peer.peer)
            secureEnvelopeBuffersByPeer[peer.peer] = nil
            inboundAcceptanceTasksByPeer[peer.peer] = nil
            Task { [weak self] in
                guard let self else { return }
                if let connectionID { await self.engine.connectionClosed(id: connectionID) }
                await self.refreshPairingState()
            }
        case .connecting:
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
            guard self.connectionIDs[peer.peer] == connectionID else {
                await self.engine.connectionClosed(id: connectionID)
                await self.refreshPairingState()
                return
            }
            self.perform(action, connectionID: connectionID, peer: peer)
            let desktopID = await self.engine.authenticatedDesktopID(for: connectionID)
            guard self.connectionIDs[peer.peer] == connectionID else { return }
            if desktopID != nil { self.session.authenticated(peer.peer) }
            self.updateAuthenticatedPeer(peer.peer, desktopID: desktopID)
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

    /// Derives trusted desktop labels from authenticated connections; unrelated failures cannot remove them.
    private func updateAuthenticatedPeer(_ peer: DeveloperPeerID, desktopID: UUID?) {
        authenticatedDesktopsByPeer[peer] = desktopID
        connectedDesktopNames = Set(authenticatedDesktopsByPeer.values).map { "Desktop \($0.uuidString.prefix(8))" }.sorted()
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
            try session.send(JSONEncoder().encode(envelope), to: peer.peer)
        } catch {
            lastError = error.localizedDescription
            session.disconnect(peer.peer)
        }
    }
}

extension DeveloperRunnerService: DeveloperSessionOwner {}
