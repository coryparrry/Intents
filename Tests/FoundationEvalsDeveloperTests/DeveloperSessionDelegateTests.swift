import Foundation
import Network
import Testing
@testable import FoundationEvalsDeveloper

private actor TransportOperationProbe {
    var started = false
    var cancelled = false
    /// Blocks real registered work until a cancel message reaches the runner registry.
    func run(_ value: String) async throws -> String {
        if value == "oversize" { return String(repeating: "x", count: 13 * 1_024 * 1_024) }
        guard value == "wait" else { return value.uppercased() }
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true; throw error }
        return value
    }
}

@MainActor
private final class TransportRecorder: DeveloperSessionOwner {
    var states: [DeveloperSessionState] = []
    var messages: [Data] = []
    var listenerReady = false
    var clientReady = false
    var otherClientReady = false
    /// Records states emitted only after the real TLS transport checks authentication.
    func peerChanged(_ peer: DeveloperPeerBox, state: DeveloperSessionState) { states.append(state) }
    /// Retains complete frames to verify byte boundaries and receive ordering.
    func received(_ data: Data, from peer: DeveloperPeerBox) { messages.append(data) }
}

@MainActor
@Suite("Network runner transport", .serialized, .timeLimit(.minutes(1)))
struct DeveloperSessionDelegateTests {
    /// Exercises real TLS sockets, both application handshakes, remote cancellation, and persisted reconnect trust.
    @Test func pairsExecutesCancelsAndReconnectsOverAuthenticatedTLS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runnerID = UUID(), desktopID = UUID()
        let identity = DeveloperRunnerIdentity(id: runnerID, displayName: "Loopback runner", platform: .mac,
            operatingSystem: "Fixture", hardwareModel: "Loopback", appBundleIdentifier: "test.transport", appVersion: "2")
        let registry = DeveloperFeatureRegistry()
        let probe = TransportOperationProbe()
        await registry.register(.init(id: "echo", displayName: "Echo", version: "1", inputTypeName: "String", outputTypeName: "String"),
            input: String.self, output: String.self, operation: { value, _ in try await probe.run(value) }, response: { $0 })
        let service = DeveloperRunnerService(identity: identity, registry: registry,
            trustStoreURL: directory.appendingPathComponent("runner.json"))
        let clientURL = directory.appendingPathComponent("desktop.json")
        let client = DeveloperRunnerClient(desktopID: desktopID, trustStoreURL: clientURL)
        var reconnected: DeveloperRunnerClient?
        do {
            let state = await service.beginPairing()
            guard case .advertising(let code, _, _) = state else { throw CocoaError(.featureUnsupported) }
            try await waitUntil("listener ready") { service.isAdvertising }
            let port = try #require(service.listeningPort)
            let peer = DeveloperPeerBox(DeveloperPeerID(displayName: "Loopback runner"))
            client.found(peer, runnerID: runnerID, endpoint: .hostPort(host: "127.0.0.1", port: port))
            try client.connect(to: runnerID)
            #expect(client.runners.first?.state == .pairingRequired)
            let wrongCode = (code.first == "0" ? "1" : "0") + code.dropFirst()
            try client.trustRunner(runnerID, pairingCode: wrongCode)
            try await waitUntil("wrong TLS key rejected") { client.runners.first?.state == .pairingRequired }
            #expect(client.runners.first?.features.isEmpty == true)
            try client.trustRunner(runnerID, pairingCode: code)
            try await waitUntil("application authentication") { client.runners.first?.state == .connected }
            #expect(client.runners.first?.features.map(\.id) == ["echo"])
            let runnerFile = directory.appendingPathComponent("runner.json")
            let backup = directory.appendingPathComponent("runner-backup.json")
            try FileManager.default.moveItem(at: runnerFile, to: backup)
            try FileManager.default.createDirectory(at: runnerFile, withIntermediateDirectories: true)
            do {
                _ = try await client.execute(request("cannot confirm"), on: runnerID)
                Issue.record("Expected failed receipt confirmation to disconnect")
            } catch let failure as DeveloperExecutionFailure { #expect(failure.code == .disconnected) }
            try FileManager.default.removeItem(at: runnerFile)
            try FileManager.default.moveItem(at: backup, to: runnerFile)
            try await waitUntil("listener after storage failure") { service.isAdvertising }
            let recoveredPort = try #require(service.listeningPort)
            client.found(peer, runnerID: runnerID, endpoint: .hostPort(host: "127.0.0.1", port: recoveredPort))
            try await waitUntil("reconnect after confirmation write failure") { client.runners.first?.state == .connected }
            try await waitUntil("rotated listener ready") { service.isAdvertising }
            let rotatedPort = try #require(service.listeningPort)
            client.lostPeer(peer)
            client.found(.init(.init(displayName: "Rediscovered endpoint")), runnerID: runnerID,
                endpoint: .hostPort(host: "127.0.0.1", port: rotatedPort))
            try await waitUntil("authenticated desktop reporting") { !service.connectedDesktopNames.isEmpty }
            let connectedBeforeRejection = service.connectedDesktopNames
            let intruder = DeveloperRunnerClient(desktopID: UUID())
            intruder.found(.init(.init(displayName: "Wrong-key endpoint")), runnerID: runnerID,
                endpoint: .hostPort(host: "127.0.0.1", port: rotatedPort))
            try intruder.trustRunner(runnerID, pairingCode: wrongCode)
            try await waitUntil("unrelated wrong key rejected") { intruder.runners.first?.state == .pairingRequired }
            intruder.shutdown()
            #expect(service.connectedDesktopNames == connectedBeforeRejection)
            let oversize = try await client.execute(request("oversize"), on: runnerID)
            #expect(oversize.output == nil)
            #expect(oversize.failure?.code == .executionFailed)
            let result = try await client.execute(request("hello"), on: runnerID)
            #expect(result.output?.response == "HELLO")
            let waiting = try request("wait")
            let execution = Task { try await client.execute(waiting, on: runnerID) }
            try await waitUntil("remote operation started") { await probe.started }
            client.cancel(requestID: waiting.id, runID: waiting.runID, runnerID: runnerID)
            do { _ = try await execution.value; Issue.record("Expected local cancellation") }
            catch let failure as DeveloperExecutionFailure { #expect(failure.code == .cancelled) }
            try await waitUntil("remote cancellation delivered") { await probe.cancelled }
            client.disconnect(runnerID)
            try client.connect(to: runnerID)
            try await waitUntil("rediscovered standby reconnect") { client.runners.first?.state == .connected }
            client.shutdown()
            // Pairing rotates the listener's keys; connect to its current port with reloaded trust.
            try await waitUntil("trusted listener ready") { service.isAdvertising }
            let trustedPort = try #require(service.listeningPort)
            let saved = DeveloperRunnerClient(desktopID: desktopID, trustStoreURL: clientURL)
            reconnected = saved
            saved.found(.init(.init(displayName: "Reloaded runner")), runnerID: runnerID,
                endpoint: .hostPort(host: "127.0.0.1", port: trustedPort))
            try await waitUntil("saved trust reconnect") { saved.runners.first?.state == .connected }
            #expect(try await saved.execute(request("again"), on: runnerID).output?.response == "AGAIN")
            await service.stop()
            try await waitUntil("runner disconnect") { saved.runners.first?.state == .disconnected }
            saved.shutdown()
        } catch {
            client.shutdown()
            reconnected?.shutdown()
            await service.stop()
            throw error
        }
    }

    /// Recovers discovery and advertising from network waits, then pairs over Bonjour after a failed receipt write.
    @Test func bonjourDiscoveryPairsAnInitiallyUntrustedRunner() async throws {
        let runnerID = UUID()
        let service = DeveloperRunnerService(identity: .init(id: runnerID, displayName: "Bonjour fixture", platform: .mac,
            operatingSystem: "Fixture", hardwareModel: "Loopback", appBundleIdentifier: "test.bonjour", appVersion: "2"),
            registry: .init())
        let desktop = UUID()
        let unwritableFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unwritableFile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unwritableFile) }
        let failedWriter = DeveloperRunnerClient(desktopID: desktop, trustStoreURL: unwritableFile)
        let client = DeveloperRunnerClient(desktopID: desktop)
        do {
            service.start()
            try await waitUntil("empty-trust listener") { service.isAdvertising }
            let retainedListener = try #require(service.listener)
            service.listenerStateChanged(.waiting(.posix(.ENETDOWN)), listener: retainedListener)
            #expect(service.listener === retainedListener)
            #expect(!service.isAdvertising && service.lastError != nil)
            service.listenerStateChanged(.ready, listener: retainedListener)
            #expect(service.isAdvertising && service.lastError == nil)
            failedWriter.startBrowsing()
            let retainedBrowser = try #require(failedWriter.browser.browser)
            failedWriter.browser.stateChanged(.waiting(.posix(.ENETDOWN)), browser: retainedBrowser)
            #expect(failedWriter.browser.browser === retainedBrowser)
            #expect(failedWriter.isBrowsing && failedWriter.lastError != nil)
            failedWriter.browser.stateChanged(.ready, browser: retainedBrowser)
            #expect(failedWriter.lastError == nil)
            try await waitUntil("failed writer discovery") { failedWriter.runners.contains { $0.id == runnerID } }
            let firstPairing = await service.beginPairing()
            guard case .advertising(let firstCode, _, _) = firstPairing else { throw CocoaError(.featureUnsupported) }
            try await waitUntil("first pairing listener") { service.isAdvertising }
            try failedWriter.connect(to: runnerID)
            try failedWriter.trustRunner(runnerID, pairingCode: firstCode)
            try await waitUntil("desktop receipt write rejected") { failedWriter.lastError?.contains("could not be saved") == true }
            #expect(failedWriter.runners.first { $0.id == runnerID }?.state != .connected)
            try await waitUntil("failed writer closed") { service.connectedDesktopNames.isEmpty }
            failedWriter.shutdown()
            client.startBrowsing()
            try await waitUntil("Bonjour discovery") { client.runners.contains { $0.id == runnerID } }
            let state = await service.beginPairing()
            guard case .advertising(let code, _, _) = state else { throw CocoaError(.featureUnsupported) }
            try await waitUntil("pairing listener rotation") { service.isAdvertising }
            try client.connect(to: runnerID)
            try client.trustRunner(runnerID, pairingCode: code)
            try await waitUntil("Bonjour pairing") { client.runners.first { $0.id == runnerID }?.state == .connected }
            client.shutdown()
            await service.stop()
        } catch {
            failedWriter.shutdown()
            client.shutdown()
            await service.stop()
            throw error
        }
    }

    /// Restores the pairing prompt when a TLS-authenticated runner closes before sending its application challenge.
    @Test func pairingRetrySurvivesAnUnclassifiedTransportClose() async throws {
        let runner = UUID()
        let code = DeveloperAuthentication.makePairingCode()
        let credential = try DeveloperTransportCredential.pairing(code: code, runnerID: runner)
        let listener = try NWListener(using: DeveloperTransportCredential.parameters([credential]))
        let recorder = TransportRecorder()
        listener.stateUpdateHandler = { state in
            if case .ready = state { Task { @MainActor in recorder.listenerReady = true } }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { [weak connection] state in
                if case .ready = state { connection?.cancel() }
            }
            connection.start(queue: .main)
        }
        let client = DeveloperRunnerClient(desktopID: UUID())
        listener.start(queue: .main)
        defer { listener.cancel(); client.shutdown() }
        try await waitUntil("early-close listener") { recorder.listenerReady }
        let port = try #require(listener.port)
        client.found(.init(.init(displayName: "Early-close runner")), runnerID: runner,
            endpoint: .hostPort(host: "127.0.0.1", port: port))
        try client.trustRunner(runner, pairingCode: code)
        try await waitUntil("pairing retry after early TLS close") { client.runners.first?.state == .pairingRequired }
        #expect(client.lastError?.contains("pairing code") == true)
        #expect(client.runners.first?.features.isEmpty == true)
    }

    /// Keeps the surviving endpoint's pairing code when another endpoint for the same runner disappears and closes.
    @Test func pairingContinuesOnTheSurvivingEndpoint() async throws {
        let runner = DeveloperRunnerIdentity(id: UUID(), displayName: "Two endpoints", platform: .mac,
            operatingSystem: "Fixture", hardwareModel: "Loopback", appBundleIdentifier: "test.endpoints", appVersion: "2")
        let code = DeveloperAuthentication.makePairingCode()
        let credential = try DeveloperTransportCredential.pairing(code: code, runnerID: runner.id)
        let first = DeveloperNetworkSession(), second = DeveloperNetworkSession()
        let firstRecorder = TransportRecorder(), secondRecorder = TransportRecorder()
        first.owner = firstRecorder
        second.owner = secondRecorder
        /// Opens a real TLS endpoint while withholding its application challenge until the test sends it.
        func listen(_ session: DeveloperNetworkSession, recorder: TransportRecorder) throws -> NWListener {
            let listener = try NWListener(using: DeveloperTransportCredential.parameters([credential]))
            listener.newConnectionHandler = { connection in Task { @MainActor in session.accept(connection) } }
            listener.stateUpdateHandler = { state in
                if case .ready = state { Task { @MainActor in recorder.listenerReady = true } }
            }
            listener.start(queue: .main)
            return listener
        }
        let a = try listen(first, recorder: firstRecorder), b = try listen(second, recorder: secondRecorder)
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { a.cancel(); b.cancel(); first.disconnect(); second.disconnect(); client.shutdown() }
        try await waitUntil("both endpoint listeners") { firstRecorder.listenerReady && secondRecorder.listenerReady }
        let lost = DeveloperPeerBox(DeveloperPeerID(displayName: "Disappearing endpoint"))
        client.found(lost, runnerID: runner.id, endpoint: .hostPort(host: "127.0.0.1", port: try #require(a.port)))
        client.found(.init(.init(displayName: "Surviving endpoint")), runnerID: runner.id,
            endpoint: .hostPort(host: "127.0.0.1", port: try #require(b.port)))
        try client.trustRunner(runner.id, pairingCode: code)
        try await waitUntil("both endpoint TLS connections") { client.session.connectedPeers.count == 2 }
        client.lostPeer(lost)
        first.disconnect()
        try await waitUntil("lost endpoint closed") { !client.session.connectedPeers.contains(lost.peer) }
        let challenge = DeveloperPairingChallenge(runner: runner, pairingSessionID: UUID(),
            nonce: DeveloperAuthentication.makeNonce(), expiresAt: Date().addingTimeInterval(30))
        let peer = try #require(second.connectedPeers.first)
        try second.send(JSONEncoder().encode(DeveloperRunnerEnvelope(message: .pairingChallenge(challenge))), to: peer)
        try await waitUntil("surviving endpoint pairing proof") { !secondRecorder.messages.isEmpty }
        let response = try JSONDecoder().decode(DeveloperRunnerEnvelope.self, from: #require(secondRecorder.messages.first))
        guard case .pairingRequest(let request) = response.message else { Issue.record("Expected pairing proof"); return }
        #expect(DeveloperAuthentication.validatesPairingProof(request.proof, code: code,
            challenge: challenge, desktopID: request.desktopID))
    }

    /// Exercises fragmented and coalesced TCP messages, then rejects an oversized wire length before allocation.
    @Test func framedTLSDeliversOrderedMessagesAndRejectsInvalidLengths() async throws {
        let desktop = UUID(), runner = UUID()
        let store = DeveloperTrustStore()
        try await store.trust(desktopID: desktop, token: "confirmed-fixture")
        let pending = try await store.stagePairing(desktopID: desktop)
        let credential = DeveloperTransportCredential.trusted(token: "confirmed-fixture", desktopID: desktop, runnerID: runner)
        let replacement = DeveloperTransportCredential.trusted(token: pending, desktopID: desktop, runnerID: runner)
        let session = DeveloperNetworkSession()
        let recorder = TransportRecorder()
        session.owner = recorder
        let parameters = DeveloperTransportCredential.parameters(await store.transportCredentials(runnerID: runner))
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in Task { @MainActor in session.accept(connection) } }
        listener.stateUpdateHandler = { state in
            if case .ready = state { Task { @MainActor in recorder.listenerReady = true } }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); session.disconnect() }
        try await waitUntil("framing listener") { recorder.listenerReady }
        let port = try #require(listener.port)
        let raw = NWConnection(host: "127.0.0.1", port: port, using: DeveloperTransportCredential.parameters([credential]))
        raw.stateUpdateHandler = { state in
            if case .ready = state { Task { @MainActor in recorder.clientReady = true } }
        }
        raw.start(queue: .main)
        defer { raw.cancel() }
        try await waitUntil("framing TLS authentication") { recorder.clientReady && !session.connectedPeers.isEmpty }
        try await sendRaw(Data([0, 0]), connection: raw)
        // Complete the split header/body and include the next complete frame in the same write.
        try await sendRaw(Data([0, 3, 1, 2, 3, 0, 0, 0, 2, 4, 5]), connection: raw)
        try await waitUntil("ordered frames") { recorder.messages.count == 2 }
        #expect(recorder.messages == [Data([1, 2, 3]), Data([4, 5])])
        let other = NWConnection(host: "127.0.0.1", port: port, using: DeveloperTransportCredential.parameters([replacement]))
        other.stateUpdateHandler = { state in
            if case .ready = state { Task { @MainActor in recorder.otherClientReady = true } }
        }
        other.start(queue: .main)
        defer { other.cancel() }
        try await waitUntil("pending receipt TLS authentication") { recorder.otherClientReady && session.connectedPeers.count == 2 }
        try await sendRaw(Data([0, 0, 0, 1, 6]), connection: other)
        try await waitUntil("pending receipt frame") { recorder.messages.count == 3 }
        #expect(recorder.messages.last == Data([6]))
        try await sendRaw(Data(repeating: 255, count: 4), connection: raw)
        try await waitUntil("invalid frame closed only its socket") { session.connectedPeers.count == 1 }
        try await sendRaw(Data([0, 0, 0, 1, 7]), connection: other)
        try await waitUntil("other receipt remains connected") { recorder.messages.count == 4 }
        #expect(recorder.messages.last == Data([7]))
    }

    /// Completes a raw TLS write before the next fragmentation step is submitted.
    private func sendRaw(_ bytes: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Lost and repeated replacement receipts preserve the old credential until the new one is actually proved.
    @Test func lostReplacementReceiptsRemainRecoverableAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("trust.json"), desktop = UUID()
        let store = DeveloperTrustStore(fileURL: file)
        try await store.trust(desktopID: desktop, token: "confirmed-fixture")
        let identity = DeveloperRunnerIdentity(id: UUID(), displayName: "Receipt fixture", platform: .mac,
            operatingSystem: "Fixture", hardwareModel: "Loopback", appBundleIdentifier: "test.receipts", appVersion: "2")
        let engine = DeveloperRunnerHostEngine(identity: identity, registry: .init(), trustStore: store)
        let pending = try await droppedReceipt(engine, desktop: desktop, connection: "lost-one")
        let repeated = try await droppedReceipt(engine, desktop: desktop, connection: "lost-two")
        #expect(pending == repeated)
        let restored = DeveloperTrustStore(fileURL: file)
        #expect(Set(await restored.tokens(for: desktop)) == ["confirmed-fixture", pending])
        let restarted = DeveloperRunnerHostEngine(identity: identity, registry: .init(), trustStore: restored)
        for (connection, token) in [("old-receipt", "confirmed-fixture"), ("new-receipt", pending)] {
            let messages = await restarted.connectionOpened(id: connection)
            let challenge = try #require(messages.compactMap { envelope -> DeveloperReconnectChallenge? in
                if case .reconnectChallenge(let value) = envelope.message { return value }; return nil
            }.first)
            let hello = DeveloperDesktopHello(desktopID: desktop, challengeID: challenge.id,
                proof: DeveloperAuthentication.desktopProof(token: token, challenge: challenge, desktopID: desktop))
            let responses = await restarted.handle(.init(message: .desktopHello(hello)), connectionID: connection)
            #expect(!responses.isEmpty)
            #expect(await restarted.authenticatedDesktopID(for: connection) == desktop)
            if token == "confirmed-fixture" { #expect(Set(await restored.tokens(for: desktop)) == [token, pending]) }
            await restarted.connectionClosed(id: connection)
        }
        #expect(await DeveloperTrustStore(fileURL: file).tokens(for: desktop) == [pending])
        try await restored.revoke(desktopID: desktop)
        #expect(try await restored.confirmPairing(desktopID: desktop, token: pending) == false)
        #expect(await DeveloperTrustStore(fileURL: file).tokens(for: desktop).isEmpty)
    }

    /// Runs the pairing protocol but drops its responses at the transport boundary, inspecting only the sealed receipt in the harness.
    private func droppedReceipt(_ engine: DeveloperRunnerHostEngine, desktop: UUID, connection: String) async throws -> String {
        let state = await engine.beginPairing(endpoint: "Receipt fixture")
        guard case .advertising(let code, _, _) = state else { throw CocoaError(.featureUnsupported) }
        let messages = await engine.connectionOpened(id: connection)
        let challenge = try #require(messages.compactMap { envelope -> DeveloperPairingChallenge? in
            if case .pairingChallenge(let value) = envelope.message { return value }; return nil
        }.first)
        let request = DeveloperPairingRequest(pairingSessionID: challenge.pairingSessionID,
            proof: DeveloperAuthentication.pairingProof(code: code, challenge: challenge, desktopID: desktop), desktopID: desktop)
        let responses = await engine.handle(.init(message: .pairingRequest(request)), connectionID: connection)
        let receipt = try #require(responses.compactMap { envelope -> DeveloperPairingReceipt? in
            if case .pairingReceipt(let value) = envelope.message { return value }; return nil
        }.first)
        await engine.connectionClosed(id: connection)
        return try DeveloperAuthentication.openTrustToken(receipt.sealedTrustToken, code: code, challenge: challenge, desktopID: desktop)
    }

    /// Makes a real feature request with a deadline independent of the test's bounded waits.
    private func request(_ input: String) throws -> DeveloperFeatureExecutionRequest {
        .init(runID: UUID(), featureID: "echo", featureVersion: "1", encodedInput: try JSONEncoder().encode(input),
            inputTypeName: "String", deadline: Date().addingTimeInterval(30))
    }

    /// Waits for a semantic transport or operation transition, failing with the missing stage.
    private func waitUntil(_ stage: String, condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw DeveloperExecutionFailure(code: .deadlineExceeded, message: "Timed out awaiting \(stage).")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
