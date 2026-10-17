import Foundation
@preconcurrency import MultipeerConnectivity
import Testing
@testable import FoundationEvalsDeveloper

@MainActor
struct DeveloperRunnerClientRecoveryTests {
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
