#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor final class AutomationSecretConsentTests: XCTestCase {
    private let sentinel = "SYNTHETIC-NATIVE-CONSENT-CREDENTIAL"
    private actor Gate {
        private var entered = false
        private var listeners: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; listeners.forEach { $0.resume() }; listeners.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
        func resume() { release?.resume(); release = nil }
    }
    private actor Probe {
        private var checks = 0
        private var drained = false
        func checked() { checks += 1 }
        func count() -> Int { checks }
        func finish() { drained = true }
        func finished() -> Bool { drained }
    }
    private struct Fixture {
        let approval: RunApproval
        let scope: AutomationScope
        let leases: AutomationDeviceLeaseManager
        let lease: AutomationDeviceLeaseManager.Lease
        let artifacts: AutomationArtifactRegistry
        let session: AutomationSecretFillSession
        let root: URL
    }
    private func fixture(leaseObservation: (@Sendable () async -> Void)? = nil) async throws -> Fixture {
        var app = AppIdentity(logicalID: "subject", bundleID: "test.SecretApp", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2; app.canonicalBundlePath = "/synthetic/SecretApp.app"
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-gui-session")
        let approval = RunApproval(runID: "secret-consent", app: app, target: target, environmentID: "synthetic",
            effects: [.observe, .navigate, .externalWrite], maximumActions: 10, disposable: false,
            approvedCaseDigest: String(repeating: "b", count: 64))
        let leases = AutomationDeviceLeaseManager()
        let lease = try await leases.acquire(runID: approval.runID, target: target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: AutomationFoundationController(), artifacts: artifacts)
        let check: (@Sendable () async -> Bool)?
        if let observe = leaseObservation { check = { await observe(); return await leases.isCurrent(lease) } }
        else { check = nil }
        let session = AutomationSecretFillSession(approval: approval, lease: lease, leases: leases, authority: authority, artifacts: artifacts, isCurrent: check)
        return .init(approval: approval, scope: scope, leases: leases, lease: lease, artifacts: artifacts, session: session, root: root)
    }
    private func review(_ f: Fixture, approval: RunApproval? = nil, scope: AutomationScope? = nil) throws -> AutomationSecretConsentReview {
        try .init(approval: approval ?? f.approval, scope: scope ?? f.scope, sinkID: "secure-field", sinkFingerprint: String(repeating: "c", count: 64))
    }
    private func denied(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
    }
    func testReviewRequiresStrongMacCaseSessionAndWritableEffect() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var variants: [RunApproval] = []
        var changed = f.approval; changed.app.productDigestVersion = 1; variants.append(changed)
        changed = f.approval; changed.app.platform = "ios"; variants.append(changed)
        changed = f.approval; changed.app.productDigest = nil; variants.append(changed)
        changed = f.approval; changed.target.loginSession = nil; variants.append(changed)
        changed = f.approval; changed.approvedCaseDigest = nil; variants.append(changed)
        changed = f.approval; changed.effects = [.observe, .navigate]; variants.append(changed)
        changed = f.approval; changed.effects = [.navigate, .fixtureWrite]; variants.append(changed)
        for approval in variants { XCTAssertThrowsError(try review(f, approval: approval)) }
        var scope = f.scope; scope.runId = "other"
        XCTAssertThrowsError(try review(f, scope: scope))
    }
    func testPrepareWithholdsEvidenceBeforeInputAndConfirmReturnsOnlyBoundHandle() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in await probe.checked() })
        await denied { _ = try await model.confirm(self.sentinel) }
        try await model.prepare(); XCTAssertEqual(model.state, .ready)
        let exposed = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(exposed)
        let request = try await model.confirm(sentinel)
        XCTAssertEqual(model.state, .approved); XCTAssertEqual(request.scope, f.scope)
        let checks = await probe.count(); XCTAssertEqual(checks, 2)
        try await f.session.validateBound(request)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(sentinel))
        await denied { _ = try await model.confirm(self.sentinel) }
        await model.cancelAndDrain()
        do { try await f.session.validateBound(request); XCTFail("Cancelled consent survived") } catch {}
    }
    func testDifferentFullApprovalCannotReachSinkReviewOrCollectInput() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var changed = f.approval; changed.environmentID = "different"
        let probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f, approval: changed), session: f.session, validateSink: { _ in await probe.checked() })
        await denied { try await model.prepare() }; XCTAssertEqual(model.state, .failed)
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let exposed = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertTrue(exposed)
    }
    func testChangedGenerationCannotPrepare() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var scope = f.scope; scope.leaseGeneration += 1
        let model = AutomationSecretConsentModel(review: try review(f, scope: scope), session: f.session, validateSink: { _ in XCTFail("Stale lease reached native validation") })
        await denied { try await model.prepare() }
    }
    func testFreshSinkFailureAfterPrepareSanitizesErrorAndRevokesSession() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), message = sentinel
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in
            await probe.checked()
            if await probe.count() == 2 { throw NSError(domain: message, code: 1) }
        })
        try await model.prepare()
        await denied { _ = try await model.confirm(self.sentinel) }; XCTAssertEqual(model.state, .failed)
        await denied { try await f.session.validateConsentContext(approval: f.approval, scope: f.scope) }
    }
    func testLeaseReleaseDuringFreshConsentCheckCannotDiscloseHandle() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(), probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in
            await probe.checked(); if await probe.count() == 2 { await gate.hold() }
        })
        try await model.prepare()
        let pending = Task { try await model.confirm(self.sentinel) }
        await gate.wait()
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
        await gate.resume()
        do { _ = try await pending.value; XCTFail("Released lease disclosed a handle") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
        XCTAssertEqual(model.state, .failed)
    }
    func testLeaseReleaseDuringBoundHandleValidationCannotPublishConsent() async throws {
        let gate = Gate(), probe = Probe()
        let f = try await fixture(leaseObservation: {
            await probe.checked(); if await probe.count() == 6 { await gate.hold() }
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in })
        try await model.prepare()
        let pending = Task { try await model.confirm(self.sentinel) }
        await gate.wait()
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
        await gate.resume()
        do { _ = try await pending.value; XCTFail("Bound stale handle was published") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
        XCTAssertEqual(model.state, .failed)
        await denied { try await f.session.validateConsentContext(approval: f.approval, scope: f.scope) }
    }
    func testCancelDrainsHeldPrepareWithoutLateReadiness() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(), probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in await gate.hold() })
        let pending = Task { try await model.prepare() }
        await gate.wait()
        let stop = Task { await model.cancelAndDrain(); await probe.finish() }
        for _ in 0..<20 { await Task.yield() }
        let early = await probe.finished(); XCTAssertFalse(early)
        await gate.resume(); await stop.value
        do { try await pending.value; XCTFail("Late readiness") } catch {}
        XCTAssertEqual(model.state, .cancelled)
    }
    func testCancelDrainsHeldConfirmWithoutDisclosingHandle() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(), probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in
            await probe.checked(); if await probe.count() == 2 { await gate.hold() }
        })
        try await model.prepare()
        let pending = Task { try await model.confirm(self.sentinel) }
        await gate.wait()
        let stop = Task { await model.cancelAndDrain(); await probe.finish() }
        for _ in 0..<20 { await Task.yield() }
        let early = await probe.finished(); XCTAssertFalse(early)
        await gate.resume(); await stop.value
        do { _ = try await pending.value; XCTFail("Late handle disclosure") } catch {}
        XCTAssertEqual(model.state, .cancelled)
    }
    func testCallerCancellationRetainsUncooperativeValidationUntilDrained() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(), probe = Probe()
        let model = AutomationSecretConsentModel(review: try review(f), session: f.session, validateSink: { _ in await gate.hold() })
        let pending = Task { do { try await model.prepare() } catch {}; await probe.finish() }
        await gate.wait(); pending.cancel()
        for _ in 0..<20 { await Task.yield() }
        let early = await probe.finished(); XCTAssertFalse(early)
        await gate.resume(); await pending.value
        await model.cancelAndDrain(); XCTAssertEqual(model.state, .cancelled)
    }
}
#endif
