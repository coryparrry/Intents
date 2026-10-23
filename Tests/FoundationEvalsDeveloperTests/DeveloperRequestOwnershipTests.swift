import Foundation
import Testing
@testable import FoundationEvalsDeveloper

@Suite("Developer request ownership")
struct DeveloperRequestOwnershipTests {
    @Test("Duplicate registry IDs do not replace cancellation ownership")
    func duplicateRegistryRequest() async throws {
        let registry = DeveloperFeatureRegistry()
        let gate = RequestOwnershipGate()
        await registerFeatures(registry, gate: gate)
        let request = try request()
        let original = await registry.start(request)
        await gate.waitUntilStarted()
        var duplicate = request
        duplicate.featureID = "fast"
        let duplicateTask = await registry.start(duplicate)
        let rejected = await duplicateTask.value
        #expect(rejected.failure?.code == .invalidInput)

        await registry.cancel(requestID: request.id)
        await gate.release()
        #expect(await original.value.failure?.code == .cancelled)
    }

    @Test("Authenticated peers cannot cancel another connection's request")
    func foreignCancellation() async throws {
        let registry = DeveloperFeatureRegistry()
        let gate = RequestOwnershipGate()
        await registerFeatures(registry, gate: gate)
        let host = DeveloperRunnerHostEngine(identity: identity(), registry: registry)
        var owner = try await connect(host, connectionID: "owner")
        var other = try await connect(host, connectionID: "other")
        let request = try request()
        let action = await host.accept(
            .init(message: .secure(try owner.seal(.execute(request), direction: .desktopToRunner))),
            connectionID: "owner"
        )
        await gate.waitUntilStarted()
        _ = await host.handle(
            .init(message: .secure(try other.seal(.cancel(requestID: request.id), direction: .desktopToRunner))),
            connectionID: "other"
        )
        await gate.release()
        let envelopes = await host.resolve(action, connectionID: "owner")
        let result = try result(envelopes, cipher: &owner)
        #expect(result.failure == nil)
        #expect(result.output?.response == "finished")
    }

    @Test("Duplicate host IDs preserve the original result", arguments: ["owner", "other"])
    func duplicateHostRequest(connectionID: String) async throws {
        let registry = DeveloperFeatureRegistry()
        let gate = RequestOwnershipGate()
        await registerFeatures(registry, gate: gate)
        let host = DeveloperRunnerHostEngine(identity: identity(), registry: registry)
        var owner = try await connect(host, connectionID: "owner")
        var other = try await connect(host, connectionID: "other")
        let request = try request()
        let action = await host.accept(
            .init(message: .secure(try owner.seal(.execute(request), direction: .desktopToRunner))),
            connectionID: "owner"
        )
        await gate.waitUntilStarted()
        var duplicate = request
        duplicate.featureID = "fast"
        var sender = connectionID == "owner" ? owner : other
        let envelopes = await host.handle(
            .init(message: .secure(try sender.seal(.execute(duplicate), direction: .desktopToRunner))),
            connectionID: connectionID
        )
        if connectionID == "owner" {
            #expect(envelopes.isEmpty)
        } else {
            let rejected = try result(envelopes, cipher: &sender)
            #expect(rejected.failure?.code == .invalidInput)
        }
        if connectionID == "owner" { owner = sender } else { other = sender }
        // Closing a peer whose duplicate was rejected must not cancel the owner.
        if connectionID == "other" { await host.connectionClosed(id: "other") }
        await gate.release()
        let original = try result(await host.resolve(action, connectionID: "owner"), cipher: &owner)
        #expect(original.failure == nil)
        #expect(original.output?.response == "finished")
    }

    private func registerFeatures(_ registry: DeveloperFeatureRegistry, gate: RequestOwnershipGate) async {
        await registry.registerTextFeature(id: "slow", displayName: "Slow", version: "1") { _, _ in
            await gate.waitForRelease()
            return .init(response: "finished")
        }
        await registry.registerTextFeature(id: "fast", displayName: "Fast", version: "1") { _, _ in
            .init(response: "duplicate")
        }
    }

    private func request() throws -> DeveloperFeatureExecutionRequest {
        .init(runID: UUID(), featureID: "slow", featureVersion: "1",
              encodedInput: try JSONEncoder().encode(DeveloperTextFeatureInput(
                caseID: UUID(), instructions: "", prompt: "input", expected: "", repetition: 1
              )), inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
              deadline: Date().addingTimeInterval(30))
    }

    private func identity() -> DeveloperRunnerIdentity {
        .init(id: UUID(), displayName: "Test", platform: .mac,
              operatingSystem: "macOS", hardwareModel: "Mac",
              appBundleIdentifier: "example.test", appVersion: "1")
    }

    private func connect(_ host: DeveloperRunnerHostEngine, connectionID: String) async throws -> DeveloperSessionCipher {
        let desktopID = UUID()
        let token = DeveloperAuthentication.makeToken()
        try await host.trustStore.trust(desktopID: desktopID, token: token)
        let envelopes = await host.connectionOpened(id: connectionID)
        let challenge = try #require(envelopes.compactMap { envelope -> DeveloperReconnectChallenge? in
            guard case .reconnectChallenge(let challenge) = envelope.message else { return nil }
            return challenge
        }.first)
        let hello = DeveloperDesktopHello(
            desktopID: desktopID, challengeID: challenge.id,
            proof: DeveloperAuthentication.desktopProof(token: token, challenge: challenge, desktopID: desktopID)
        )
        let replies = await host.handle(.init(message: .desktopHello(hello)), connectionID: connectionID)
        var cipher = DeveloperSessionCipher(token: token, challenge: challenge, desktopID: desktopID)
        let secure = try #require(replies.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        _ = try cipher.open(secure, direction: .runnerToDesktop)
        return cipher
    }

    private func result(_ envelopes: [DeveloperRunnerEnvelope], cipher: inout DeveloperSessionCipher) throws -> DeveloperFeatureExecutionResult {
        let secure = try #require(envelopes.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        let message = try cipher.open(secure, direction: .runnerToDesktop)
        guard case .result(let result) = message else {
            throw DeveloperExecutionFailure(code: .executionFailed, message: "Expected execution result")
        }
        return result
    }
}

private actor RequestOwnershipGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForRelease() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
