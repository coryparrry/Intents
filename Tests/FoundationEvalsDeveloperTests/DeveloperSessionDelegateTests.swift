import Foundation
@preconcurrency import MultipeerConnectivity
import Testing
@testable import FoundationEvalsDeveloper

private enum DeveloperSessionEvent: Sendable {
    case state(DeveloperPeerBox, MCSessionState)
    case data(DeveloperPeerBox, Data)
}

@MainActor
private final class DeveloperSessionRecorder: DeveloperSessionOwner {
    private let continuation: AsyncStream<DeveloperSessionEvent>.Continuation
    private(set) var events: [DeveloperSessionEvent] = []

    /// Records forwarded callbacks and makes each arrival awaitable by the test.
    init(continuation: AsyncStream<DeveloperSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Verifies main-actor delivery while preserving the forwarded peer and state.
    func peerChanged(_ peer: DeveloperPeerBox, state: MCSessionState) {
        MainActor.preconditionIsolated()
        let event = DeveloperSessionEvent.state(peer, state)
        events.append(event)
        continuation.yield(event)
    }

    /// Verifies main-actor delivery while preserving the forwarded message bytes.
    func received(_ data: Data, from peer: DeveloperPeerBox) {
        MainActor.preconditionIsolated()
        let event = DeveloperSessionEvent.data(peer, data)
        events.append(event)
        continuation.yield(event)
    }
}

/// Exercises unsupported transport callbacks without starting any nearby transport activity.
private func emitUnsupportedSessionCallbacks(
    _ delegate: DeveloperSessionDelegate,
    session: MCSession,
    peer: MCPeerID
) {
    delegate.session(session, didReceive: InputStream(data: Data([1])), withName: "unused", fromPeer: peer)
    delegate.session(
        session, didStartReceivingResourceWithName: "unused", fromPeer: peer,
        with: Progress(totalUnitCount: 1)
    )
    delegate.session(
        session, didFinishReceivingResourceWithName: "unused", fromPeer: peer,
        at: nil, withError: CocoaError(.fileReadUnknown)
    )
}

@MainActor
@Suite("Shared nearby session callbacks", .timeLimit(.minutes(1)))
struct DeveloperSessionDelegateTests {
    /// Delivers background state and data callbacks to the owner in order on MainActor.
    @Test func backgroundCallbacksPreservePeerStateAndData() async throws {
        let (stream, continuation) = AsyncStream<DeveloperSessionEvent>.makeStream()
        defer { continuation.finish() }
        var events = stream.makeAsyncIterator()
        let owner = DeveloperSessionRecorder(continuation: continuation)
        let delegate = DeveloperSessionDelegate()
        delegate.owner = owner
        let peer = await Task.detached {
            let peer = MCPeerID(displayName: "Remote runner")
            let session = MCSession(peer: MCPeerID(displayName: "Local desktop"))
            delegate.session(session, peer: peer, didChange: .connecting)
            return DeveloperPeerBox(peer)
        }.value
        let stateEvent = try #require(await events.next())
        guard case .state(let changedPeer, let state) = stateEvent else {
            Issue.record("Expected the transport state callback first.")
            return
        }
        #expect(changedPeer.peer === peer.peer)
        #expect(state == .connecting)

        let payload = Data([0, 1, 127, 255])
        await Task.detached {
            let session = MCSession(peer: MCPeerID(displayName: "Local desktop"))
            emitUnsupportedSessionCallbacks(delegate, session: session, peer: peer.peer)
            delegate.session(session, didReceive: payload, fromPeer: peer.peer)
        }.value
        let dataEvent = try #require(await events.next())
        guard case .data(let sender, let received) = dataEvent else {
            Issue.record("Expected the message callback after the transport state.")
            return
        }
        #expect(sender.peer === peer.peer)
        #expect(received == payload)
        #expect(owner.events.count == 2)
        #expect(delegate.owner === owner)
    }

    /// Queued callbacks capture an absent owner and cannot be delivered to a later owner.
    @Test func nilOwnerCallbacksStayIgnoredAndUnsupportedHooksDoNothing() async throws {
        let (stream, continuation) = AsyncStream<DeveloperSessionEvent>.makeStream()
        defer { continuation.finish() }
        var events = stream.makeAsyncIterator()
        let delegate = DeveloperSessionDelegate()
        let peer = MCPeerID(displayName: "Remote runner")
        let session = MCSession(peer: MCPeerID(displayName: "Local desktop"))
        delegate.session(session, peer: peer, didChange: .connecting)
        delegate.session(session, didReceive: Data([99]), fromPeer: peer)
        emitUnsupportedSessionCallbacks(delegate, session: session, peer: peer)

        let owner = DeveloperSessionRecorder(continuation: continuation)
        delegate.owner = owner
        emitUnsupportedSessionCallbacks(delegate, session: session, peer: peer)
        delegate.session(session, peer: peer, didChange: .notConnected)
        let event = try #require(await events.next())
        guard case .state(let changedPeer, let state) = event else {
            Issue.record("A callback queued without an owner reached the replacement owner.")
            return
        }
        #expect(changedPeer.peer === peer)
        #expect(state == .notConnected)
        #expect(owner.events.count == 1)
    }

    /// Neither the delegate nor already queued callback tasks keep an owner alive.
    @Test func queuedCallbacksDoNotRetainTheOwner() async {
        let (stream, continuation) = AsyncStream<DeveloperSessionEvent>.makeStream()
        var events = stream.makeAsyncIterator()
        let delegate = DeveloperSessionDelegate()
        var owner: DeveloperSessionRecorder? = DeveloperSessionRecorder(continuation: continuation)
        weak var weakOwner = owner
        delegate.owner = owner
        let peer = MCPeerID(displayName: "Remote runner")
        let session = MCSession(peer: MCPeerID(displayName: "Local desktop"))
        delegate.session(session, peer: peer, didChange: .connected)
        delegate.session(session, didReceive: Data([1, 2, 3]), fromPeer: peer)
        owner = nil
        #expect(weakOwner == nil)
        #expect(delegate.owner == nil)
        continuation.finish()
        #expect(await events.next() == nil)
    }
}
