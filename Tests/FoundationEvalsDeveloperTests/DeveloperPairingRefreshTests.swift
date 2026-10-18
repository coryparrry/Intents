import Foundation
import Testing
@testable import FoundationEvalsDeveloper

@Suite("Pairing on existing connections")
struct DeveloperPairingRefreshTests {
    private let code = "0123-4567-89AB-CDEF-0123-4567-89AB-CDEF"

    @Test("Starting pairing after connection delivers a usable secure session")
    func connectBeforePairing() async throws {
        let host = makeHost()
        let opened = await host.connectionOpened(id: "desktop")
        #expect(pairingChallenge(in: opened) == nil)
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        let refreshed = await host.pairingChallenges(for: "desktop")
        try await verifyPairing(host: host, challenges: refreshed)
    }

    @Test("Starting pairing recovers rejected saved trust without reconnecting")
    func startPairingAfterRejectedTrust() async throws {
        let host = makeHost()
        let opened = await host.connectionOpened(id: "desktop")
        let reconnect = try #require(reconnectChallenge(in: opened))
        let rejected = await host.handle(
            .init(message: .desktopHello(.init(
                desktopID: UUID(), challengeID: reconnect.id,
                proof: Data(repeating: 0, count: 32)
            ))),
            connectionID: "desktop"
        )
        #expect(rejected.contains {
            if case .authenticationFailure = $0.message { true } else { false }
        })
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        try await verifyPairing(host: host, challenges: await host.pairingChallenges(for: "desktop"))
    }

    @Test("Starting pairing refreshes an expired connection challenge")
    func expiredConnectionChallenge() async throws {
        let host = makeHost()
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let opened = await host.connectionOpened(id: "desktop", now: connectedAt)
        let oldReconnect = try #require(reconnectChallenge(in: opened))
        let pairingAt = connectedAt.addingTimeInterval(600)
        _ = await host.beginPairingForTesting(endpoint: "sample", now: pairingAt, code: code)
        let refreshed = await host.pairingChallenges(for: "desktop", now: pairingAt)
        let reconnect = try #require(reconnectChallenge(in: refreshed))
        #expect(reconnect.id != oldReconnect.id)
        #expect(reconnect.expiresAt > pairingAt)
        try await verifyPairing(host: host, challenges: refreshed, now: pairingAt)
    }

    @Test("Renewing pairing publishes the current code session")
    func renewedPairing() async throws {
        let host = makeHost()
        _ = await host.beginPairingForTesting(endpoint: "sample", code: "old-code")
        let opened = await host.connectionOpened(id: "desktop")
        let oldPairing = try #require(pairingChallenge(in: opened))
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        let refreshed = await host.pairingChallenges(for: "desktop")
        let pairing = try #require(pairingChallenge(in: refreshed))
        #expect(pairing.pairingSessionID != oldPairing.pairingSessionID)
        #expect(pairing.nonce != oldPairing.nonce)
        try await verifyPairing(host: host, challenges: refreshed)
    }

    @Test("Refresh does not reopen closed connections or reset authenticated sessions")
    func refreshOnlyPendingConnections() async throws {
        let host = makeHost()
        _ = await host.connectionOpened(id: "closed")
        await host.connectionClosed(id: "closed")
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        #expect(await host.pairingChallenges(for: "closed").isEmpty)
        #expect(await host.pairingChallenges(for: "unknown").isEmpty)

        let opened = await host.connectionOpened(id: "desktop")
        try await verifyPairing(host: host, challenges: opened)
        let authenticatedDesktopID = await host.authenticatedDesktopID(for: "desktop")
        _ = await host.beginPairingForTesting(endpoint: "sample", code: code)
        #expect(await host.pairingChallenges(for: "desktop").isEmpty)
        #expect(await host.authenticatedDesktopID(for: "desktop") == authenticatedDesktopID)
    }

    @Test("Cancelled and expired pairing cannot be advertised to an existing connection")
    func noInactivePairingChallenge() async {
        let host = makeHost()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = await host.connectionOpened(id: "desktop", now: now)
        _ = await host.beginPairingForTesting(endpoint: "sample", duration: .seconds(1), now: now, code: code)
        #expect(await host.pairingChallenges(for: "desktop", now: now.addingTimeInterval(2)).isEmpty)
        _ = await host.beginPairingForTesting(endpoint: "sample", now: now, code: code)
        await host.stopPairing()
        #expect(await host.pairingChallenges(for: "desktop", now: now).isEmpty)
    }

    private func verifyPairing(
        host: DeveloperRunnerHostEngine,
        challenges: [DeveloperRunnerEnvelope],
        now: Date = Date()
    ) async throws {
        let reconnect = try #require(reconnectChallenge(in: challenges))
        let pairing = try #require(pairingChallenge(in: challenges))
        let desktopID = UUID()
        let responses = await host.handle(
            .init(message: .pairingRequest(.init(
                pairingSessionID: pairing.pairingSessionID,
                proof: DeveloperAuthentication.pairingProof(code: code, challenge: pairing, desktopID: desktopID),
                desktopID: desktopID
            ))),
            connectionID: "desktop", now: now
        )
        let receipt = try #require(responses.compactMap { envelope -> DeveloperPairingReceipt? in
            guard case .pairingReceipt(let receipt) = envelope.message else { return nil }
            return receipt
        }.first)
        let token = try DeveloperAuthentication.openTrustToken(
            receipt.sealedTrustToken, code: code, challenge: pairing, desktopID: desktopID
        )
        let secure = try #require(responses.compactMap { envelope -> DeveloperSecureEnvelope? in
            guard case .secure(let secure) = envelope.message else { return nil }
            return secure
        }.first)
        var cipher = DeveloperSessionCipher(token: token, challenge: reconnect, desktopID: desktopID)
        let message = try cipher.open(secure, direction: .runnerToDesktop)
        guard case .hello(let hello) = message else {
            Issue.record("Expected an authenticated runner hello")
            return
        }
        #expect(hello.desktopID == desktopID)
        #expect(hello.reconnectChallengeID == reconnect.id)
        #expect(DeveloperAuthentication.validatesRunnerProof(
            hello.runnerProof, token: token, challenge: reconnect, desktopID: desktopID
        ))
        #expect(await host.authenticatedDesktopID(for: "desktop") == desktopID)
    }

    private func pairingChallenge(in envelopes: [DeveloperRunnerEnvelope]) -> DeveloperPairingChallenge? {
        envelopes.compactMap {
            guard case .pairingChallenge(let value) = $0.message else { return nil }
            return value
        }.first
    }

    private func reconnectChallenge(in envelopes: [DeveloperRunnerEnvelope]) -> DeveloperReconnectChallenge? {
        envelopes.compactMap {
            guard case .reconnectChallenge(let value) = $0.message else { return nil }
            return value
        }.first
    }

    private func makeHost() -> DeveloperRunnerHostEngine {
        DeveloperRunnerHostEngine(
            identity: .init(
                id: UUID(), displayName: "Sample", platform: .iPhone,
                operatingSystem: "iOS 27", hardwareModel: "iPhone",
                appBundleIdentifier: "example.sample", appVersion: "1"
            ),
            registry: .init()
        )
    }
}
