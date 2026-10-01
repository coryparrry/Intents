import Foundation
import Testing
@testable import FoundationEvalsDeveloper

@Suite("Developer protocol")
struct DeveloperProtocolTests {
    @Test("Versioned envelopes round-trip")
    func envelopeRoundTrip() throws {
        let request = DeveloperFeatureExecutionRequest(
            id: UUID(),
            runID: UUID(),
            featureID: "com.example.summary",
            featureVersion: "2",
            encodedInput: Data("input".utf8),
            inputTypeName: "Example.Input",
            deadline: Date(timeIntervalSince1970: 2_000)
        )
        let envelope = DeveloperRunnerEnvelope(
            id: UUID(),
            sentAt: Date(timeIntervalSince1970: 1_000),
            message: .execute(request)
        )

        let decoded = try JSONDecoder().decode(
            DeveloperRunnerEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        #expect(decoded == envelope)
        #expect(DeveloperProtocolVersion.current.canRead(decoded.protocolVersion))
        #expect(!DeveloperProtocolVersion.current.canRead(.init(major: 2, minor: 0)))
    }

    @Test("Authenticated envelopes reject replay and tampering")
    func secureEnvelopeIntegrity() throws {
        let runner = DeveloperRunnerIdentity(
            id: UUID(),
            displayName: "Sample",
            platform: .iPhone,
            operatingSystem: "iOS 27",
            hardwareModel: "iPhone",
            appBundleIdentifier: "com.example.Sample",
            appVersion: "1"
        )
        let challenge = DeveloperReconnectChallenge(
            runner: runner,
            nonce: Data(repeating: 0xA5, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        let desktopID = UUID()
        var sender = DeveloperSessionCipher(token: "saved-secret", challenge: challenge, desktopID: desktopID)
        var receiver = DeveloperSessionCipher(token: "saved-secret", challenge: challenge, desktopID: desktopID)

        let first = try sender.seal(.disconnect(reason: "done"), direction: .desktopToRunner)
        #expect(try receiver.open(first, direction: .desktopToRunner) == .disconnect(reason: "done"))

        var replayWasRejected = false
        do {
            _ = try receiver.open(first, direction: .desktopToRunner)
        } catch {
            replayWasRejected = true
        }
        #expect(replayWasRejected)

        var tampered = try sender.seal(.cancel(requestID: UUID()), direction: .desktopToRunner)
        tampered.sealedMessage[tampered.sealedMessage.startIndex] ^= 0x01
        var tamperingWasRejected = false
        do {
            _ = try receiver.open(tampered, direction: .desktopToRunner)
        } catch {
            tamperingWasRejected = true
        }
        #expect(tamperingWasRejected)
    }

    @Test("Concurrent secure responses are emitted in sequence order")
    func secureEnvelopeBuffering() {
        let sessionID = UUID()
        func envelope(_ sequence: UInt64) -> DeveloperRunnerEnvelope {
            .init(message: .secure(.init(
                sessionID: sessionID,
                sequence: sequence,
                sealedMessage: Data([UInt8(sequence)])
            )))
        }
        var buffer = DeveloperSecureEnvelopeBuffer()

        #expect(buffer.insert(envelope(1)).isEmpty)
        let firstBatch = buffer.insert(envelope(0))
        #expect(firstBatch.compactMap { item -> UInt64? in
            guard case .secure(let secure) = item.message else { return nil }
            return secure.sequence
        } == [0, 1])
        #expect(buffer.insert(envelope(1)).isEmpty)
        #expect(buffer.insert(envelope(2)).count == 1)
    }
}

@Suite("Feature registry")
struct DeveloperFeatureRegistryTests {
    private struct Input: Codable, Sendable { var value: String }
    private struct Output: Codable, Sendable { var normalized: String }

    @Test("Typed registration preserves encoded application values")
    func typedFeature() async throws {
        let registry = DeveloperFeatureRegistry()
        let descriptor = DeveloperFeatureDescriptor(
            id: "normalize",
            displayName: "Normalize",
            version: "1",
            inputTypeName: String(reflecting: Input.self),
            outputTypeName: String(reflecting: Output.self),
            capabilityNames: ["application-closure"]
        )
        await registry.register(descriptor, input: Input.self, output: Output.self) { input, context in
            try context.checkCancellation()
            return Output(normalized: input.value.uppercased())
        } response: { $0.normalized }

        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: descriptor.id,
            featureVersion: descriptor.version,
            encodedInput: try JSONEncoder().encode(Input(value: "real app value")),
            inputTypeName: descriptor.inputTypeName,
            deadline: Date().addingTimeInterval(10)
        )
        let result = await registry.execute(request)

        #expect(result.failure == nil)
        #expect(result.output?.response == "REAL APP VALUE")
        let encoded = try #require(result.output?.encodedValue)
        #expect(try JSONDecoder().decode(Output.self, from: encoded).normalized == "REAL APP VALUE")
    }

    @Test("Feature version mismatches fail without invoking application code")
    func versionMismatch() async throws {
        let registry = DeveloperFeatureRegistry()
        let invoked = InvocationCounter()
        await registry.registerTextFeature(id: "summary", displayName: "Summary", version: "3") { _, _ in
            await invoked.increment()
            return .init(response: "unexpected")
        }
        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "summary",
            featureVersion: "2",
            encodedInput: try JSONEncoder().encode(textInput()),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(10)
        )

        let result = await registry.execute(request)

        #expect(result.failure?.code == .incompatibleFeatureVersion)
        #expect(await invoked.value == 0)
    }

    @Test("Expired requests fail before invoking application code")
    func expiredRequest() async throws {
        let registry = DeveloperFeatureRegistry()
        let invoked = InvocationCounter()
        await registry.registerTextFeature(id: "summary", displayName: "Summary", version: "1") { _, _ in
            await invoked.increment()
            return .init(response: "unexpected")
        }
        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "summary",
            featureVersion: "1",
            encodedInput: try JSONEncoder().encode(textInput()),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(-1)
        )

        let result = await registry.execute(request)

        #expect(result.failure?.code == .deadlineExceeded)
        #expect(await invoked.value == 0)
    }

    @Test("Cancellation reaches an in-flight application closure")
    func cancellation() async throws {
        let registry = DeveloperFeatureRegistry()
        let gate = ExecutionStartGate()
        await registry.registerTextFeature(id: "slow", displayName: "Slow", version: "1") { _, _ in
            await gate.markStarted()
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }
        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "slow",
            featureVersion: "1",
            encodedInput: try JSONEncoder().encode(textInput()),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(30)
        )
        let task = Task { await registry.execute(request) }
        await gate.waitUntilStarted()

        await registry.cancel(requestID: request.id)
        let result = await task.value

        #expect(result.failure?.code == .cancelled)
    }

    private func textInput() -> DeveloperTextFeatureInput {
        .init(caseID: UUID(), instructions: "", prompt: "Hello", expected: "", repetition: 1)
    }
}

private actor InvocationCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor ExecutionStartGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("Pairing and trust")
struct DeveloperRunnerHostEngineTests {
    @Test("Public pairing always generates a high-entropy code")
    func pairingCodeGeneration() async {
        let host = DeveloperRunnerHostEngine(identity: runnerIdentity(), registry: .init())
        let state = await host.beginPairing(endpoint: "sample")
        guard case .advertising(let code, _, _) = state else {
            Issue.record("Expected advertising state")
            return
        }
        #expect(code.filter { $0.isHexDigit }.count == 32)
    }

    @Test("Rejected saved trust can pair on the same connection")
    func staleTrustRecovery() async throws {
        let host = DeveloperRunnerHostEngine(identity: runnerIdentity(), registry: .init())
        let code = "0123-4567-89AB-CDEF-0123-4567-89AB-CDEF"
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        let desktopID = UUID()
        let opened = await host.connectionOpened(id: "stale")
        let reconnect = try #require(opened.compactMap { envelope -> DeveloperReconnectChallenge? in
            guard case .reconnectChallenge(let challenge) = envelope.message else { return nil }
            return challenge
        }.first)
        let pairing = try #require(opened.compactMap { envelope -> DeveloperPairingChallenge? in
            guard case .pairingChallenge(let challenge) = envelope.message else { return nil }
            return challenge
        }.first)

        let rejected = await host.handle(
            .init(message: .desktopHello(.init(
                desktopID: desktopID,
                challengeID: reconnect.id,
                proof: Data(repeating: 0, count: 32)
            ))),
            connectionID: "stale"
        )
        #expect(rejected.contains { envelope in
            if case .authenticationFailure = envelope.message { true } else { false }
        })

        let paired = await host.handle(
            .init(message: .pairingRequest(.init(
                pairingSessionID: pairing.pairingSessionID,
                proof: DeveloperAuthentication.pairingProof(
                    code: code,
                    challenge: pairing,
                    desktopID: desktopID
                ),
                desktopID: desktopID
            ))),
            connectionID: "stale"
        )
        #expect(paired.contains { envelope in
            if case .pairingReceipt = envelope.message { true } else { false }
        })
    }

    @Test("Pairing is explicit and a saved receipt reconnects")
    func pairAndReconnect() async throws {
        let registry = DeveloperFeatureRegistry()
        await registry.registerTextFeature(id: "summary", displayName: "Summary", version: "1") { input, _ in
            .init(response: input.prompt.uppercased())
        }
        let identity = runnerIdentity()
        let host = DeveloperRunnerHostEngine(identity: identity, registry: registry)
        let desktopID = UUID()
        let fixedCode = "0123-4567-89AB-CDEF-0123-4567-89AB-CDEF"
        let state = await host.beginPairingForTesting(endpoint: "sample", duration: .seconds(60), code: fixedCode)
        guard case .advertising(let code, let endpoint, _) = state else {
            Issue.record("Expected advertising state")
            return
        }
        #expect(code == fixedCode)
        #expect(endpoint == "sample")

        let firstConnection = await host.connectionOpened(id: "first")
        let challengeEnvelope = try #require(firstConnection.first { envelope in
            if case .pairingChallenge = envelope.message { true } else { false }
        })
        guard case .pairingChallenge(let challenge) = challengeEnvelope.message else {
            Issue.record("Expected pairing challenge")
            return
        }
        let pairingRequest = DeveloperPairingRequest(
            pairingSessionID: challenge.pairingSessionID,
            proof: DeveloperAuthentication.pairingProof(
                code: code,
                challenge: challenge,
                desktopID: desktopID
            ),
            desktopID: desktopID
        )
        let encodedRequest = try JSONEncoder().encode(pairingRequest)
        #expect(!String(decoding: encodedRequest, as: UTF8.self).contains(code))
        let responses = await host.handle(
            .init(message: .pairingRequest(pairingRequest)),
            connectionID: "first"
        )
        let receipt = try #require(responses.compactMap { envelope -> DeveloperPairingReceipt? in
            guard case .pairingReceipt(let receipt) = envelope.message else { return nil }
            return receipt
        }.first)
        #expect(receipt.runner == identity)
        let trustToken = try DeveloperAuthentication.openTrustToken(
            receipt.sealedTrustToken,
            code: code,
            challenge: challenge,
            desktopID: desktopID
        )

        await host.connectionClosed(id: "first")
        let secondConnection = await host.connectionOpened(id: "second")
        let reconnectChallenge = try #require(secondConnection.compactMap { envelope -> DeveloperReconnectChallenge? in
            guard case .reconnectChallenge(let challenge) = envelope.message else { return nil }
            return challenge
        }.first)
        let hello = DeveloperDesktopHello(
            desktopID: desktopID,
            challengeID: reconnectChallenge.id,
            proof: DeveloperAuthentication.desktopProof(
                token: trustToken,
                challenge: reconnectChallenge,
                desktopID: desktopID
            )
        )
        let reconnect = await host.handle(
            .init(message: .desktopHello(hello)),
            connectionID: "second"
        )
        var desktopCipher = DeveloperSessionCipher(
            token: trustToken,
            challenge: reconnectChallenge,
            desktopID: desktopID
        )
        let secureHello = try #require(reconnect.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        let authenticatedHello = try desktopCipher.open(secureHello, direction: .runnerToDesktop)
        guard case .hello(let runnerHello) = authenticatedHello else {
            Issue.record("Expected secure runner hello")
            return
        }
        #expect(DeveloperAuthentication.validatesRunnerProof(
            runnerHello.runnerProof,
            token: trustToken,
            challenge: reconnectChallenge,
            desktopID: desktopID
        ))

        _ = await host.connectionOpened(id: "replay")
        let replay = await host.handle(
            .init(message: .desktopHello(hello)),
            connectionID: "replay"
        )
        let replayFailure = try #require(replay.compactMap { envelope -> DeveloperAuthenticationFailure? in
            guard case .authenticationFailure(let failure) = envelope.message else { return nil }
            return failure
        }.first)
        #expect(replayFailure.runnerID == identity.id)
        #expect(replayFailure.desktopID == desktopID)

        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "summary",
            featureVersion: "1",
            encodedInput: try JSONEncoder().encode(DeveloperTextFeatureInput(
                caseID: UUID(), instructions: "", prompt: "device", expected: "", repetition: 1
            )),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(10)
        )
        let secureRequest = try desktopCipher.seal(.execute(request), direction: .desktopToRunner)
        let resultEnvelopes = await host.handle(
            .init(message: .secure(secureRequest)),
            connectionID: "second"
        )
        let secureResult = try #require(resultEnvelopes.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        let authenticatedResult = try desktopCipher.open(secureResult, direction: .runnerToDesktop)
        guard case .result(let result) = authenticatedResult else {
            Issue.record("Expected execution result")
            return
        }
        #expect(result.output?.response == "DEVICE")

        let gate = ExecutionStartGate()
        await registry.registerTextFeature(id: "slow", displayName: "Slow", version: "1") { _, _ in
            await gate.markStarted()
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }
        let slowRequest = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "slow",
            featureVersion: "1",
            encodedInput: try JSONEncoder().encode(DeveloperTextFeatureInput(
                caseID: UUID(), instructions: "", prompt: "device", expected: "", repetition: 1
            )),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(30)
        )
        let secureSlowRequest = try desktopCipher.seal(.execute(slowRequest), direction: .desktopToRunner)
        let slowAction = await host.accept(
            .init(message: .secure(secureSlowRequest)),
            connectionID: "second"
        )
        guard case .execute = slowAction else {
            Issue.record("Expected accepted execution action")
            return
        }
        await gate.waitUntilStarted()
        let secureCancel = try desktopCipher.seal(.cancel(requestID: slowRequest.id), direction: .desktopToRunner)
        let cancelAction = await host.accept(.init(message: .secure(secureCancel)), connectionID: "second")
        let cancelResponses = await host.resolve(cancelAction, connectionID: "second")
        #expect(cancelResponses.isEmpty)

        let cancelledEnvelopes = await host.resolve(slowAction, connectionID: "second")
        let cancelledSecure = try #require(cancelledEnvelopes.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        let cancelledMessage = try desktopCipher.open(cancelledSecure, direction: .runnerToDesktop)
        guard case .result(let cancelledResult) = cancelledMessage else {
            Issue.record("Expected cancelled result")
            return
        }
        #expect(cancelledResult.failure?.code == .cancelled)
    }

    @Test("Untrusted connections cannot execute features")
    func rejectsUntrustedExecution() async throws {
        let registry = DeveloperFeatureRegistry()
        let host = DeveloperRunnerHostEngine(identity: runnerIdentity(), registry: registry)
        let request = DeveloperFeatureExecutionRequest(
            runID: UUID(),
            featureID: "missing",
            featureVersion: "1",
            encodedInput: Data(),
            inputTypeName: "Input",
            deadline: Date().addingTimeInterval(10)
        )

        let responses = await host.handle(.init(message: .execute(request)), connectionID: "unknown")

        guard case .result(let result) = try #require(responses.first).message else {
            Issue.record("Expected failure result")
            return
        }
        #expect(result.failure?.code == .untrustedPeer)
    }

    private func runnerIdentity() -> DeveloperRunnerIdentity {
        .init(
            id: UUID(),
            displayName: "Sample",
            platform: .iPhone,
            operatingSystem: "iOS 27",
            hardwareModel: "iPhone",
            appBundleIdentifier: "com.example.Sample",
            appVersion: "1"
        )
    }

    @Test("Pairing attempts are throttled and capped")
    func pairingAttemptsAreBounded() async throws {
        let host = DeveloperRunnerHostEngine(identity: runnerIdentity(), registry: .init())
        let now = Date(timeIntervalSince1970: 1_000)
        let state = await host.beginPairingForTesting(
            endpoint: "sample",
            duration: .seconds(300),
            now: now,
            code: "0123-4567-89AB-CDEF-0123-4567-89AB-CDEF"
        )
        guard case .advertising(_, _, _) = state else {
            Issue.record("Expected advertising state")
            return
        }
        let connection = await host.connectionOpened(id: "attacker", now: now)
        let challenge = try #require(connection.compactMap { envelope -> DeveloperPairingChallenge? in
            guard case .pairingChallenge(let challenge) = envelope.message else { return nil }
            return challenge
        }.first)

        for attempt in 0..<5 {
            let attackerID = UUID()
            _ = await host.handle(
                .init(message: .pairingRequest(.init(
                    pairingSessionID: challenge.pairingSessionID,
                    proof: DeveloperAuthentication.pairingProof(
                        code: "FFFF-FFFF-FFFF-FFFF-FFFF-FFFF-FFFF-FFFF",
                        challenge: challenge,
                        desktopID: attackerID
                    ),
                    desktopID: attackerID
                ))),
                connectionID: "attacker",
                now: now.addingTimeInterval(Double(attempt * 2))
            )
        }

        #expect(await host.pairingState(now: now.addingTimeInterval(10)) == .idle)
    }

    @Test("Peer display names stay within Multipeer's UTF-8 limit")
    func boundedPeerDisplayName() {
        let value = developerPeerDisplayName(String(repeating: "é🚀", count: 80), id: UUID())
        #expect(value.utf8.count <= 63)
        #expect(String(decoding: value.utf8, as: UTF8.self) == value)
    }
}
