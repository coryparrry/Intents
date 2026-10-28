import Foundation
@preconcurrency import MultipeerConnectivity
import Testing
@testable import FoundationEvalsDeveloper

@MainActor
struct DeveloperRunnerClientRecoveryTests {
    /// Keeps authenticated identity and features across discovery loss, changed hints and competitors.
    @Test(arguments: [false, true])
    func authenticatedRediscoveryPreservesTheConnectedRunner(changedAdvertisement: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desktopID = UUID()
        let runner = DeveloperRunnerIdentity(
            id: UUID(), displayName: "Authenticated runner", platform: .mac,
            operatingSystem: "macOS", hardwareModel: "Mac",
            appBundleIdentifier: "example.rediscovery", appVersion: "1"
        )
        let features = [DeveloperFeatureDescriptor(
            id: "summarize", displayName: "Summarize", version: "1",
            inputTypeName: "String", outputTypeName: "String"
        )]
        let token = "synthetic-rediscovery-trust"
        let trustStoreURL = directory.appendingPathComponent("trust.json")
        let state = SavedTrustFixture(entries: [.init(
            endpoint: "Runner endpoint",
            receipt: .init(runner: runner, desktopID: desktopID, trustToken: token, issuedAt: Date())
        )])
        try JSONEncoder().encode(state).write(to: trustStoreURL)
        let client = DeveloperRunnerClient(desktopID: desktopID, trustStoreURL: trustStoreURL)
        defer { client.shutdown() }
        let peer = DeveloperPeerBox(MCPeerID(displayName: "Runner endpoint"))
        try authenticate(client, peer: peer, runner: runner, features: features, token: token)
        let authenticated = try #require(client.runners.first(where: { $0.id == runner.id }))
        #expect(authenticated.state == .connected)
        #expect(authenticated.features == features)

        client.lostPeer(peer)
        #expect(client.runners == [authenticated])
        client.found(peer, runnerID: changedAdvertisement ? UUID() : runner.id)
        #expect(client.runners == [authenticated])

        let competitor = DeveloperPeerBox(MCPeerID(displayName: "Competing endpoint"))
        client.found(competitor, runnerID: runner.id)
        client.peerChanged(competitor, state: .notConnected)
        #expect(client.runners == [authenticated])

        client.peerChanged(peer, state: .notConnected)
        #expect(client.runners.first(where: { $0.id == runner.id })?.state == .disconnected)
    }

    /// Mirrors the persisted desktop receipt format using only synthetic trust data.
    private struct SavedTrustFixture: Encodable {
        struct Entry: Encodable {
            struct Receipt: Encodable {
                let runner: DeveloperRunnerIdentity
                let desktopID: UUID
                let trustToken: String
                let issuedAt: Date
            }

            let endpoint: String
            let receipt: Receipt
        }

        let entries: [Entry]
    }

    /// Establishes saved-trust authentication through encoded challenge and encrypted hello messages.
    /// Discovery stays untrusted until the challenge arrives, so no transport invitation is needed.
    private func authenticate(
        _ client: DeveloperRunnerClient,
        peer: DeveloperPeerBox,
        runner: DeveloperRunnerIdentity,
        features: [DeveloperFeatureDescriptor],
        token: String
    ) throws {
        client.found(peer, runnerID: nil)
        let challenge = DeveloperReconnectChallenge(
            runner: runner, nonce: Data(repeating: 0xA5, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        client.received(try JSONEncoder().encode(DeveloperRunnerEnvelope(message: .reconnectChallenge(challenge))), from: peer)
        var cipher = DeveloperSessionCipher(token: token, challenge: challenge, desktopID: client.desktopID)
        let hello = DeveloperRunnerHello(
            runner: runner, features: features, desktopID: client.desktopID,
            reconnectChallengeID: challenge.id,
            runnerProof: DeveloperAuthentication.runnerProof(
                token: token, challenge: challenge, desktopID: client.desktopID
            )
        )
        let secure = try cipher.seal(.hello(hello), direction: .runnerToDesktop)
        client.received(try JSONEncoder().encode(DeveloperRunnerEnvelope(message: .secure(secure))), from: peer)
    }

    @Test func failedInvitationCanRetryTheSameDiscoverableRunner() throws {
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { client.shutdown() }
        let runnerID = UUID(), peer = DeveloperPeerBox(MCPeerID(displayName: "Runner"))
        client.found(peer, runnerID: runnerID)
        _ = try client.prepareConnection(to: runnerID)
        client.peerChanged(peer, state: .notConnected)
        #expect(client.runners.first(where: { $0.id == runnerID })?.state == .disconnected)
        #expect(try client.prepareConnection(to: runnerID) == [peer.peer])
    }

    @Test func failedInvitationReleasesAdmissionForAnotherRunner() throws {
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { client.shutdown() }
        let first = UUID(), second = UUID()
        let peer = DeveloperPeerBox(MCPeerID(displayName: "First"))
        let other = DeveloperPeerBox(MCPeerID(displayName: "Second"))
        client.found(peer, runnerID: first)
        client.found(other, runnerID: second)
        _ = try client.prepareConnection(to: first)
        client.peerChanged(peer, state: .notConnected)
        #expect(try client.prepareConnection(to: second) == [other.peer])
    }

    @Test func oneFailedCandidateDoesNotReleaseOtherPendingInvitations() throws {
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { client.shutdown() }
        let runnerID = UUID(), otherID = UUID()
        let first = DeveloperPeerBox(MCPeerID(displayName: "First endpoint"))
        let second = DeveloperPeerBox(MCPeerID(displayName: "Second endpoint"))
        let other = DeveloperPeerBox(MCPeerID(displayName: "Other runner"))
        client.found(first, runnerID: runnerID)
        client.found(second, runnerID: runnerID)
        client.found(other, runnerID: otherID)
        _ = try client.prepareConnection(to: runnerID)
        client.peerChanged(first, state: .notConnected)
        #expect(throws: DeveloperExecutionFailure.self) { try client.prepareConnection(to: otherID) }
        client.peerChanged(second, state: .notConnected)
        #expect(try client.prepareConnection(to: otherID) == [other.peer])
    }

    @Test func pendingInvitationCanBeCancelledAndRetried() throws {
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { client.shutdown() }
        let runnerID = UUID(), peer = DeveloperPeerBox(MCPeerID(displayName: "Runner"))
        client.found(peer, runnerID: runnerID)
        _ = try client.prepareConnection(to: runnerID)
        client.disconnect(runnerID)
        #expect(client.runners.first(where: { $0.id == runnerID })?.state == .disconnected)
        #expect(try client.prepareConnection(to: runnerID) == [peer.peer])
    }

    @Test func lostDiscoveryDuringInvitationStillAllowsTransportFailureToReleaseAdmission() throws {
        let client = DeveloperRunnerClient(desktopID: UUID())
        defer { client.shutdown() }
        let first = UUID(), second = UUID()
        let peer = DeveloperPeerBox(MCPeerID(displayName: "Lost endpoint"))
        let other = DeveloperPeerBox(MCPeerID(displayName: "Other runner"))
        client.found(peer, runnerID: first)
        client.found(other, runnerID: second)
        _ = try client.prepareConnection(to: first)
        client.lostPeer(peer)
        client.peerChanged(peer, state: .notConnected)
        #expect(throws: DeveloperExecutionFailure.self) { try client.prepareConnection(to: first) }
        #expect(try client.prepareConnection(to: second) == [other.peer])
    }
}
