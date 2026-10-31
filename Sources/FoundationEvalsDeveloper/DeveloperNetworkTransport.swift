import Foundation
import CryptoKit
import Network
import Security

let developerRunnerServiceType = "_intents-v2._tcp"

/// A transport endpoint identity, deliberately separate from an authenticated runner identity.
struct DeveloperPeerID: Hashable, Sendable {
    let id = UUID()
    let displayName: String
}

struct DeveloperPeerBox: Sendable {
    let peer: DeveloperPeerID
    /// Carries an immutable endpoint identity through transport and engine callbacks.
    init(_ peer: DeveloperPeerID) { self.peer = peer }
}

enum DeveloperSessionState: Sendable { case connecting, connected, notConnected }

@MainActor
protocol DeveloperSessionOwner: AnyObject, Sendable {
    /// Applies a connection state after the transport has checked its TLS authentication.
    func peerChanged(_ peer: DeveloperPeerBox, state: DeveloperSessionState)
    /// Reports a TLS authentication failure separately from path or DNS availability failures.
    func transportRejected(_ peer: DeveloperPeerBox)
    /// Accepts one complete, bounded wire message from an authenticated TLS connection.
    func received(_ data: Data, from peer: DeveloperPeerBox)
}

extension DeveloperSessionOwner {
    /// Runner hosts do not publish desktop trust until application authentication completes.
    func transportRejected(_ peer: DeveloperPeerBox) {}
}

/// Domain-separated transport keys; application pairing proofs and AEAD remain independent.
struct DeveloperTransportCredential: Equatable, Sendable {
    let identity: String
    let key: Data

    /// Derives the first-contact TLS key from a complete, random 128-bit pairing code.
    static func pairing(code: String, runnerID: UUID) throws -> Self {
        let normalized = code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard normalized.utf8.count == 32,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw DeveloperExecutionFailure(code: .invalidInput, message: "Enter the complete pairing code shown by the runner.")
        }
        return derive(secret: normalized, identity: "pairing:\(runnerID.uuidString)")
    }

    /// Derives a reconnect TLS key for a particular trusted desktop and runner.
    static func trusted(token: String, desktopID: UUID, runnerID: UUID) -> Self {
        let selector = SHA256.hash(data: Data(("Intents.TLSIdentity.v2:" + token).utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return derive(secret: token, identity: "trusted:\(runnerID.uuidString):\(desktopID.uuidString):\(selector)")
    }

    /// Uses HKDF and an explicit identity/context to keep TLS keys separate from wire proofs.
    private static func derive(secret: String, identity: String) -> Self {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data("Intents.NetworkTransport.v2".utf8), info: Data(identity.utf8), outputByteCount: 32)
        return Self(identity: identity, key: key.withUnsafeBytes { Data($0) })
    }

    /// Configures authenticated TLS 1.2 PSK with no certificate fallback, tickets or resumption.
    static func parameters(_ credentials: [Self]) -> NWParameters {
        let options = NWProtocolTLS.Options()
        let tls = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(tls, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(tls, false)
        sec_protocol_options_set_tls_resumption_enabled(tls, false)
        sec_protocol_options_append_tls_ciphersuite(tls, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        for credential in credentials {
            let key = credential.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(credential.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tls, key as __DispatchData, identity as __DispatchData)
        }
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Owns bounded, length-framed TLS connections. Every callback is checked against its socket generation.
@MainActor
final class DeveloperNetworkSession {
    nonisolated static let maximumMessageBytes = 16 * 1_024 * 1_024
    weak var owner: (any DeveloperSessionOwner)?
    private struct Socket {
        let connection: NWConnection
        let generation = UUID()
        var ready = false
        var timeout: Task<Void, Never>?
    }
    private var sockets: [DeveloperPeerID: Socket] = [:]
    var connectedPeers: [DeveloperPeerID] { sockets.compactMap { $0.value.ready ? $0.key : nil } }

    /// Starts an outbound connection with exactly the credential selected by the caller.
    func connect(_ peer: DeveloperPeerID, endpoint: NWEndpoint, credential: DeveloperTransportCredential, timeout: TimeInterval) {
        guard sockets[peer] == nil else { return }
        attach(NWConnection(to: endpoint, using: DeveloperTransportCredential.parameters([credential])), peer: peer, timeout: timeout)
    }

    /// Admits a listener socket with a cap on concurrent handshakes and connections.
    func accept(_ connection: NWConnection) {
        guard sockets.count < 16 else { connection.cancel(); return }
        attach(connection, peer: DeveloperPeerID(displayName: "Intents desktop"), timeout: 20)
    }

    /// Starts transport callbacks and a finite handshake timer for this socket generation.
    private func attach(_ connection: NWConnection, peer: DeveloperPeerID, timeout: TimeInterval) {
        let socket = Socket(connection: connection)
        let generation = socket.generation
        sockets[peer] = socket
        owner?.peerChanged(.init(peer), state: .connecting)
        sockets[peer]?.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, timeout))) } catch { return }
            self?.close(peer, generation: generation)
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.changed(state, peer: peer, generation: generation) }
        }
        connection.start(queue: .main)
    }

    /// Requires the expected PSK cipher before exposing a ready connection to application code.
    private func changed(_ state: NWConnection.State, peer: DeveloperPeerID, generation: UUID) {
        guard let socket = sockets[peer], socket.generation == generation else { return }
        switch state {
        case .ready:
            guard let metadata = socket.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                  sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12,
                  sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata) == tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))! else {
                close(peer, generation: generation)
                return
            }
            sockets[peer]?.ready = true
            owner?.peerChanged(.init(peer), state: .connected)
            receiveHeader(peer, generation: generation)
        case .waiting(let error), .failed(let error):
            if case .tls(let status) = error,
               status == errSSLBadRecordMac || status == errSSLPeerBadRecordMac || status == errSSLUnknownPSKIdentity {
                owner?.transportRejected(.init(peer))
            }
            close(peer, generation: generation)
        case .cancelled:
            close(peer, generation: generation)
        default: break
        }
    }

    /// Reads the next four-byte big-endian length without allocating an unbounded message buffer.
    private func receiveHeader(_ peer: DeveloperPeerID, generation: UUID) {
        receive(4, peer: peer, generation: generation) { [weak self] header in
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumMessageBytes else {
                self?.close(peer, generation: generation)
                return
            }
            self?.receive(length, peer: peer, generation: generation) { [weak self] message in
                guard let self else { return }
                self.owner?.received(message, from: .init(peer))
                self.receiveHeader(peer, generation: generation)
            }
        }
    }

    /// Delivers exactly one bounded header or body; EOF and truncated frames close only their socket.
    private func receive(_ count: Int, peer: DeveloperPeerID, generation: UUID,
                         body: @escaping @MainActor (Data) -> Void) {
        guard let socket = sockets[peer], socket.generation == generation else { return }
        socket.connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.sockets[peer]?.generation == generation else { return }
                guard error == nil, let data, data.count == count else {
                    self.close(peer, generation: generation)
                    return
                }
                body(data)
            }
        }
    }

    /// Ends the admission timer only after application-level runner or desktop proof succeeds.
    func authenticated(_ peer: DeveloperPeerID) {
        sockets[peer]?.timeout?.cancel()
        sockets[peer]?.timeout = nil
    }

    /// Queues one complete frame in order on its connection, closing it if asynchronous delivery fails.
    func send(_ data: Data, to peer: DeveloperPeerID) throws {
        guard let socket = sockets[peer], socket.ready else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "The runner connection closed.")
        }
        guard !data.isEmpty, data.count <= Self.maximumMessageBytes else {
            close(peer, generation: socket.generation)
            throw DeveloperExecutionFailure(code: .invalidInput, message: "The runner message exceeds the 16 MiB transport limit.")
        }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        socket.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.close(peer, generation: socket.generation) }
        })
    }

    /// Removes the socket before notifying its owner, preventing duplicate or stale close callbacks.
    private func close(_ peer: DeveloperPeerID, generation: UUID) {
        guard let socket = sockets[peer], socket.generation == generation else { return }
        sockets[peer] = nil
        socket.timeout?.cancel()
        socket.connection.cancel()
        owner?.peerChanged(.init(peer), state: .notConnected)
    }

    /// Closes one evicted candidate while preserving other authenticated connections.
    func disconnect(_ peer: DeveloperPeerID) {
        if let socket = sockets[peer] { close(peer, generation: socket.generation) }
    }

    /// Closes every socket and emits each connection's terminal callback once.
    func disconnect() {
        for (peer, socket) in sockets { close(peer, generation: socket.generation) }
    }
}

/// Discovers only the new wire transport; advertised names and IDs remain untrusted hints.
@MainActor
final class DeveloperNetworkBrowser {
    weak var owner: DeveloperRunnerClient?
    private var browser: NWBrowser?
    private var peers: [NWEndpoint: DeveloperPeerID] = [:]

    /// Starts Bonjour discovery on the local network, including peer-to-peer interfaces.
    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: developerRunnerServiceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.update(results)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            let error: NWError
            switch state {
            case .failed(let failure), .waiting(let failure): error = failure
            default: return
            }
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.browser?.cancel()
                self.browser = nil
                self.owner?.browserFailed(error.localizedDescription)
            }
        }
        browser.start(queue: .main)
    }

    /// Reconciles endpoints while retaining each discovered endpoint's local identity.
    private func update(_ results: Set<NWBrowser.Result>) {
        let endpoints = Set(results.map(\.endpoint))
        for (endpoint, peer) in peers where !endpoints.contains(endpoint) {
            peers[endpoint] = nil
            owner?.lostPeer(.init(peer))
        }
        for endpoint in endpoints {
            guard case .service(let name, _, _, _) = endpoint,
                  let runnerID = UUID(uuidString: String(name.prefix(36))) else { continue }
            let peer = peers[endpoint] ?? DeveloperPeerID(displayName: String(name.dropFirst(37)))
            peers[endpoint] = peer
            owner?.found(.init(peer), runnerID: runnerID)
        }
    }

    /// Registers an explicitly resolved endpoint, also used by loopback integration fixtures.
    func register(_ peer: DeveloperPeerID, endpoint: NWEndpoint) {
        for (oldEndpoint, knownPeer) in peers where knownPeer == peer && oldEndpoint != endpoint {
            peers[oldEndpoint] = nil
        }
        peers[endpoint] = peer
    }

    /// Resolves a discovered peer to its current Bonjour endpoint.
    func endpoint(for peer: DeveloperPeerID) -> NWEndpoint? {
        peers.first { $0.value == peer }?.key
    }

    /// Stops discovery without closing established connections or changing endpoint identities.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
}
