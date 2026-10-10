#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import IntentsAutomationCore

@MainActor final class AutomationSecretConsentPresenterTests: XCTestCase {
    private actor Probe {
        private var drains = 0
        func drained() { drains += 1 }
        func count() -> Int { drains }
    }
    private struct MissingPanel: Error {}
    private struct Fixture {
        let review: AutomationSecretConsentReview
        let model: AutomationSecretConsentModel
        let presenter: AutomationSecretConsentPresenter
        let probe: Probe
        let root: URL
    }
    private func approval() -> RunApproval {
        var app = AppIdentity(logicalID: "subject", bundleID: "test.SecretApp", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2; app.canonicalBundlePath = "/synthetic/SecretApp.app"
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-gui-session")
        return RunApproval(runID: "secret-presenter", app: app, target: target, environmentID: "synthetic",
            effects: [.observe, .navigate, .externalWrite], maximumActions: 10, disposable: false,
            approvedCaseDigest: String(repeating: "b", count: 64))
    }
    private func review(scope: AutomationScope? = nil) throws -> AutomationSecretConsentReview {
        try .init(approval: approval(), scope: scope ?? .init(runID: "secret-presenter", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1),
            sinkID: "secure-field", sinkFingerprint: String(repeating: "c", count: 64))
    }
    private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let approval = approval()
        let leases = AutomationDeviceLeaseManager()
        let lease = try await leases.acquire(runID: approval.runID, target: approval.target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: AutomationFoundationController(), artifacts: artifacts)
        let session = AutomationSecretFillSession(approval: approval, lease: lease, leases: leases, authority: authority, artifacts: artifacts)
        let review = try review(scope: scope)
        let model = AutomationSecretConsentModel(review: review, session: session, validateSink: { _ in })
        let probe = Probe()
        let presenter = AutomationSecretConsentPresenter(model: model, drainNativeOwner: { await probe.drained() })
        return .init(review: review, model: model, presenter: presenter, probe: probe, root: root)
    }
    private func request(_ review: AutomationSecretConsentReview, scope: AutomationScope? = nil, sinkID: String? = nil,
                         sinkFingerprint: String? = nil) -> AutomationSecretFillRequest {
        .init(reference: .init(id: UUID()), scope: scope ?? review.scope, sinkID: sinkID ?? review.sinkID,
              sinkFingerprint: sinkFingerprint ?? review.sinkFingerprint)
    }
    private func panel(of presenter: AutomationSecretConsentPresenter) async -> NSWindow? {
        for _ in 0..<200 {
            if let panel = NSApplication.shared.windows.first(where: { ($0.delegate as AnyObject?) === presenter }) { return panel }
            await Task.yield()
        }
        return nil
    }
    private func expect(_ failure: AutomationSecretFillSession.Failure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(failure)") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, failure) }
    }
    private func presented(_ f: Fixture) async throws -> (Task<AutomationSecretFillRequest, Error>, NSWindow) {
        let pending = Task { try await f.presenter.present() }
        guard let panel = await panel(of: f.presenter) else {
            pending.cancel(); _ = await pending.result
            XCTFail("Consent panel was not created"); throw MissingPanel()
        }
        return (pending, panel)
    }

    func testApprovalGuardRequiresKeyPanelApprovedStateAndReviewedSink() throws {
        let review = try review()
        XCTAssertTrue(AutomationSecretConsentPresenter.accepts(request(review), review: review, state: .approved, panelIsKey: true))
        XCTAssertFalse(AutomationSecretConsentPresenter.accepts(request(review), review: review, state: .approved, panelIsKey: false))
        for state: AutomationSecretConsentModel.State in [.idle, .verifying, .ready, .authorizing, .cancelled, .failed] {
            XCTAssertFalse(AutomationSecretConsentPresenter.accepts(request(review), review: review, state: state, panelIsKey: true), "\(state)")
        }
        var scopes: [AutomationScope] = []
        var scope = review.scope; scope.runId = "other-run"; scopes.append(scope)
        scope = review.scope; scope.attemptId = "other-attempt"; scopes.append(scope)
        scope = review.scope; scope.segmentId = "other-segment"; scopes.append(scope)
        scope = review.scope; scope.leaseGeneration += 1; scopes.append(scope)
        for scope in scopes {
            XCTAssertFalse(AutomationSecretConsentPresenter.accepts(request(review, scope: scope), review: review, state: .approved, panelIsKey: true))
        }
        XCTAssertFalse(AutomationSecretConsentPresenter.accepts(request(review, sinkID: "other-field"), review: review, state: .approved, panelIsKey: true))
        XCTAssertFalse(AutomationSecretConsentPresenter.accepts(request(review, sinkFingerprint: String(repeating: "d", count: 64)),
            review: review, state: .approved, panelIsKey: true))
    }
    func testPresentAfterCancelIsDeniedWithoutOpeningPanel() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.presenter.cancelAndDrain()
        await expect(.denied) { _ = try await f.presenter.present() }
        let opened = NSApplication.shared.windows.contains { ($0.delegate as AnyObject?) === f.presenter }; XCTAssertFalse(opened)
        XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
    }
    func testCancelledCallerIsDeniedBeforePresentation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await f.presenter.present() }
        await expect(.denied) { _ = try await pending.value }
        let drains = await f.probe.count(); XCTAssertEqual(drains, 0)
    }
    func testSecondPresentationIsDeniedAndCancelRevokesFirst() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (pending, panel) = try await presented(f)
        await expect(.denied) { _ = try await f.presenter.present() }
        await f.presenter.cancelAndDrain(); await f.presenter.cancelAndDrain()
        await expect(.revoked) { _ = try await pending.value }
        XCTAssertFalse(panel.isVisible); XCTAssertNil(panel.delegate)
        XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
    }
    func testWindowCloseRevokesAndDrainsOnce() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (pending, panel) = try await presented(f)
        XCTAssertFalse(f.presenter.windowShouldClose(panel))
        await expect(.revoked) { _ = try await pending.value }
        await f.presenter.cancelAndDrain()
        XCTAssertFalse(panel.isVisible); XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
    }
    func testResignKeyBeforeFinishRevokesAndDrainsOnce() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (pending, panel) = try await presented(f)
        f.presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        await expect(.revoked) { _ = try await pending.value }
        await f.presenter.cancelAndDrain()
        XCTAssertFalse(panel.isVisible); XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
        await expect(.denied) { _ = try await f.presenter.present() }
    }
    func testCallerCancellationRevokesAndDrainsOnce() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (pending, panel) = try await presented(f)
        pending.cancel()
        await expect(.revoked) { _ = try await pending.value }
        await f.presenter.cancelAndDrain()
        XCTAssertFalse(panel.isVisible); XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
    }
    func testApprovalCallbackForUnreviewedSinkRevokesInsteadOfReturning() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (pending, panel) = try await presented(f)
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<AutomationSecretConsentView>)
        view.rootView.onApproved(request(f.review, sinkFingerprint: String(repeating: "d", count: 64)))
        await expect(.revoked) { _ = try await pending.value }
        await f.presenter.cancelAndDrain()
        XCTAssertFalse(panel.isVisible); XCTAssertEqual(f.model.state, .cancelled)
        let drains = await f.probe.count(); XCTAssertEqual(drains, 1)
    }
}
#endif
