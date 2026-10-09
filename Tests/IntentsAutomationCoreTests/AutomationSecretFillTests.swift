import XCTest
@testable import IntentsAutomationCore

final class AutomationSecretFillTests: XCTestCase, @unchecked Sendable {
    private let sentinel = "SYNTHETIC-CREDENTIAL-DO-NOT-EXPORT"
    private let fingerprint = String(repeating: "a", count: 64)
    private actor Probe {
        var values: [String] = []
        func submit(_ value: String) { values.append(value) }
        func count() -> Int { values.count }
    }
    private actor Gate {
        var entered = false
        var listeners: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; listeners.forEach { $0.resume() }; listeners.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
        func resume() { release?.resume(); release = nil }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { value } }
        func advance() { lock.withLock { value += .seconds(60) } }
    }
    private struct Fixture {
        let approval: RunApproval
        let leases: AutomationDeviceLeaseManager
        let lease: AutomationDeviceLeaseManager.Lease
        let scope: AutomationScope
        let authority: AutomationRunAuthority
        let artifacts: AutomationArtifactRegistry
        let session: AutomationSecretFillSession
        let root: URL
    }
    private func fixture(adapter: AutomationSecretFillAdapter? = nil,
                         controller: any AutomationControllerDecisionProvider = AutomationFoundationController(),
                         leaseObservation: (@Sendable () async -> Void)? = nil,
                         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) async throws -> Fixture {
        let app = AppIdentity(logicalID: "app", bundleID: "test.App", platform: "ios")
        let target = TargetIdentity(id: "device", kind: .simulator)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "synthetic",
                                   effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: controller, artifacts: artifacts)
        let check: (@Sendable () async -> Bool)?
        if let observe = leaseObservation { check = { await observe(); return await leases.isCurrent(lease) } }
        else { check = nil }
        let session = AutomationSecretFillSession(approval: approval, lease: lease, leases: leases,
            authority: authority, artifacts: artifacts, adapter: adapter, now: now, isCurrent: check)
        return .init(approval: approval, leases: leases, lease: lease, scope: scope, authority: authority,
                     artifacts: artifacts, session: session, root: root)
    }
    private func bind(_ f: Fixture, approval: RunApproval? = nil, scope: AutomationScope? = nil,
                      expires: ContinuousClock.Instant = .now + .seconds(30), uses: Int = 1) async throws -> AutomationSecretFillRequest {
        try await f.session.bind(sentinel, consent: .init(approval: approval ?? f.approval, scope: scope ?? f.scope,
            sinkID: "password-field", sinkFingerprint: fingerprint, expires: expires, maximumUses: uses))
    }
    private func grant(_ request: AutomationSecretFillRequest, fixture f: Fixture, authority: AutomationRunAuthority? = nil, approval: RunApproval? = nil, additional: [AutomationSecretFillRequest] = []) async throws {
        let authority = authority ?? f.authority, approval = approval ?? f.approval
        let segment = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "secretFill",
                                        effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        try await authority.approve(scope: f.scope, lease: f.lease, segment: segment,
            actions: [.activate] + ([request] + additional).map { .fillSecret(referenceID: $0.reference.id.uuidString, sinkID: $0.sinkID) })
        var fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(f.scope)).object!
        fields["effect"] = .string("activate")
        fields["target"] = .object(["id": .string("device"), "platform": .string("ios"), "kind": .string("simulator"),
            "bundleId": .string(approval.app.bundleID), "bundlePath": .null, "loginSession": .null])
        let result = await authority.review(method: "policy.reviewAction", params: .object(fields))
        XCTAssertEqual(result, .object(["allowed": .bool(true)]))
    }
    private func denied(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected refusal") } catch {}
    }
    func testOpaqueBindingAndReceiptNeverSerializeCredentialAndConsentIsOneUse() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let receipt = try await f.session.fill(request)
        XCTAssertEqual(receipt.disposition, "submittedUnconfirmed")
        for data in [try JSONEncoder().encode(request), try JSONEncoder().encode(receipt)] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(sentinel))
        }
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 1)
        for path in try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil) {
            XCTAssertFalse(String(decoding: try Data(contentsOf: path), as: UTF8.self).contains(sentinel))
        }
    }
    func testDefaultBackendRefusesWithoutResolvingOrTainting() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f)
        await denied { _ = try await f.session.fill(request) }
        let available = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertTrue(available)
    }
    func testChangedAppTargetEnvironmentScopeAndUseBudgetCannotBind() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var other = f.approval; other.environmentID = "production"
        await denied { _ = try await self.bind(f, approval: other) }
        other = f.approval; other.app.bundleID = "other.App"
        await denied { _ = try await self.bind(f, approval: other) }
        other = f.approval; other.target.id = "other-device"
        await denied { _ = try await self.bind(f, approval: other) }
        var scope = f.scope; scope.leaseGeneration += 1
        await denied { _ = try await self.bind(f, scope: scope) }
        await denied { _ = try await self.bind(f, uses: 2) }
        await denied { _ = try await self.bind(f, expires: .now - .seconds(1)) }
    }
    func testAlteredReferenceSinkAndFingerprintCannotDispatch() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f)
        for altered in [AutomationSecretFillRequest(reference: .init(id: UUID()), scope: request.scope, sinkID: request.sinkID, sinkFingerprint: fingerprint),
                        .init(reference: request.reference, scope: request.scope, sinkID: "different-field", sinkFingerprint: fingerprint),
                        .init(reference: request.reference, scope: request.scope, sinkID: request.sinkID, sinkFingerprint: String(repeating: "b", count: 64))] {
            await denied { _ = try await f.session.fill(altered) }
        }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testSharedAuthorityIsRequiredEvenWithValidSecretConsent() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f)
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testDifferentApprovalOrMissingOrDifferentFenceCannotBind() async throws {
        for mode in ["app", "environment", "missingFence", "differentFence"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var other = f.approval
            if mode == "app" { other.app.bundleID = "other.App" }
            if mode == "environment" { other.environmentID = "other-environment" }
            let otherRegistry = try AutomationArtifactRegistry(root: f.root.appendingPathComponent("different-fence"))
            let authority = AutomationRunAuthority(approval: other, leases: f.leases,
                artifacts: mode == "missingFence" ? nil : mode == "differentFence" ? otherRegistry : f.artifacts)
            let session = AutomationSecretFillSession(approval: f.approval, lease: f.lease, leases: f.leases,
                authority: authority, artifacts: f.artifacts)
            await denied { _ = try await session.bind(self.sentinel, consent: .init(approval: f.approval, scope: f.scope,
                sinkID: "password-field", sinkFingerprint: self.fingerprint, expires: .now + .seconds(30), maximumUses: 1)) }
        }
    }
    private actor FinalLeaseGate {
        let gate: Gate
        var calls = 0
        init(_ gate: Gate) { self.gate = gate }
        func observe() async { calls += 1; if calls == 5 { await gate.hold() } }
    }
    func testRevocationOrExpiryDuringFinalLeaseCheckCannotReturnReceipt() async throws {
        for expire in [false, true] {
            let gate = Gate(), leaseGate = FinalLeaseGate(gate), clock = Clock(), probe = Probe()
            let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }),
                leaseObservation: { await leaseGate.observe() }, now: { clock.now() })
            defer { try? FileManager.default.removeItem(at: f.root) }
            let request = try await bind(f, expires: clock.now() + .seconds(30)); try await grant(request, fixture: f)
            let fill = Task { try await f.session.fill(request) }; await gate.wait()
            if expire { clock.advance() } else { await f.session.revoke() }
            await gate.resume()
            do { _ = try await fill.value; XCTFail() } catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .outcomeUnresolved) }
            let count = await probe.count(); XCTAssertEqual(count, 1)
        }
    }
    func testSecureSinkValidationRejectsWithoutResolution() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in throw AutomationContractError.invalidIdentity }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testLeaseChangedDuringSinkValidationPreventsDispatch() async throws {
        let gate = Gate(), probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in await gate.hold() }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let fill = Task { try await f.session.fill(request) }; await gate.wait()
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
        await gate.resume(); await denied { _ = try await fill.value }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testExpiryDuringSinkValidationPreventsDispatch() async throws {
        let gate = Gate(), probe = Probe(), clock = Clock()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in await gate.hold() }, submit: { value, _, _ in await probe.submit(value) }), now: { clock.now() })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f, expires: clock.now() + .seconds(30)); try await grant(request, fixture: f)
        let fill = Task { try await f.session.fill(request) }; await gate.wait(); clock.advance(); await gate.resume()
        await denied { _ = try await fill.value }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testRevocationWhileValidationIsSuspendedDrainsAndNeverDispatches() async throws {
        let gate = Gate(), probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in await gate.hold() }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let fill = Task { try await f.session.fill(request) }; await gate.wait()
        await f.session.revoke()
        let drain = Task { await f.session.revokeAndDrain() }
        await gate.resume(); await drain.value; await denied { _ = try await fill.value }
        let count = await probe.count(); XCTAssertEqual(count, 0)
    }
    func testUncertainAdapterFailureIsSanitizedNeverRetriedAndRetainsTaint() async throws {
        struct SecretError: Error { let text: String }
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value); throw SecretError(text: value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        do { _ = try await f.session.fill(request); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .outcomeUnresolved); XCTAssertFalse(String(describing: error).contains(sentinel)) }
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 1)
        let available = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(available)
    }
    func testCancellationDuringDispatchRetainsAndDrainsUncertainOwnership() async throws {
        let gate = Gate(), probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value); await gate.hold() }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let fill = Task { try await f.session.fill(request) }; await gate.wait(); fill.cancel()
        await f.session.revoke()
        let drain = Task { await f.session.revokeAndDrain() }
        await gate.resume(); await drain.value
        do { _ = try await fill.value; XCTFail() } catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .outcomeUnresolved) }
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 1)
        let available = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(available)
    }
    private actor ControllerProbe: AutomationControllerDecisionProvider {
        var calls = 0
        func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision {
            calls += 1; return .init(kind: "tap", node: "n1")
        }
        func count() -> Int { calls }
    }
    func testTaintedControllerRequestIsDeniedBeforeProviderDispatch() async throws {
        for tainted in [false, true] {
            let probe = ControllerProbe()
            let f = try await fixture(controller: probe)
            defer { try? FileManager.default.removeItem(at: f.root) }
            var segment = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "navigate",
                effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
            let goal = AutomationNavigationGoal(id: "setup", instruction: "Open form", endpoint: .init(.testId, "form"))
            segment.uiProgram = .init(operations: [.init(id: "setup", kind: .navigateGoal, goal: goal)])
            try await f.authority.approve(scope: f.scope, lease: f.lease, segment: segment, actions: [.activate], maximumControllerCalls: 2)
            var fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(f.scope)).object!
            fields["effect"] = .string("activate")
            fields["target"] = .object(["id": .string("device"), "platform": .string("ios"), "kind": .string("simulator"),
                "bundleId": .string("test.App"), "bundlePath": .null, "loginSession": .null])
            _ = await f.authority.review(method: "policy.reviewAction", params: .object(fields))
            if tainted { try await f.artifacts.restrictSecretEvidence(scope: f.scope) }
            let request = AutomationControllerRequest(goalId: "setup", revision: "1", nodes: [.init(id: "n1", role: "button", name: sentinel, text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false)],
                truncated: false, omittedNodes: 0, verbs: ["tap"], recentActions: [], remainingActions: 20, remainingMs: 120_000)
            fields.removeValue(forKey: "effect"); fields.removeValue(forKey: "target")
            fields["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
            let result = await f.authority.review(method: "controller.decide", params: .object(fields))
            if tainted { XCTAssertEqual(result, .object(["allowed": .bool(false), "reason": .string("actionShape")])) }
            else { XCTAssertEqual(result.object?["kind"], .string("tap")) }
            let calls = await probe.count(); XCTAssertEqual(calls, tainted ? 0 : 1)
        }
    }
    func testSharedFenceBlocksOtherAttemptAndSurvivesReload() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let secondRoot = f.root.appendingPathComponent("attemptB")
        let second = try AutomationArtifactRegistry(root: secondRoot, secretEvidenceRoot: f.root)
        var scope = f.scope; scope.attemptId = "attemptB"
        let artifact = try await second.store(data: Data("before".utf8), name: "raw.txt", scope: scope)
        _ = try await second.resolve(handle: artifact.handle, scope: scope)
        try await f.artifacts.restrictSecretEvidence(scope: f.scope)
        await denied { _ = try await second.resolve(handle: artifact.handle, scope: scope) }
        await denied { _ = try await second.store(data: Data(self.sentinel.utf8), name: "derived.txt", scope: scope) }
        let reloaded = try AutomationArtifactRegistry(root: secondRoot, secretEvidenceRoot: f.root)
        let available = await reloaded.canExposeEvidence(scope: scope); XCTAssertFalse(available)
    }
    func testEvidenceExposureAndSecretAdmissionExcludeEachOther() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let exposure = try await f.artifacts.reserveModelEvidence(scope: f.scope)
        await denied { _ = try await f.session.fill(request) }
        let before = await probe.count(); XCTAssertEqual(before, 0)
        exposure.release()
        _ = try await f.session.fill(request)
        await denied { _ = try await f.artifacts.reserveModelEvidence(scope: f.scope) }
        let after = await probe.count(); XCTAssertEqual(after, 1)
    }
    func testFailedTaintPersistencePreventsSecretDispatch() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let marker = f.root.appendingPathComponent("secret-evidence-" + AutomationArtifactRegistry.digest(Data(f.scope.runId.utf8)) + ".json")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        await denied { _ = try await f.session.fill(request) }
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let available = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(available)
    }
    func testTaintDeniesOldNewDerivedAndCrossSegmentArtifactsAcrossRegistries() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("raw artifact".utf8).write(to: f.root.appendingPathComponent("capture.json"))
        let artifact = try await f.artifacts.register(relativePath: "capture.json", scope: f.scope)
        let other = try AutomationArtifactRegistry(root: f.root)
        try await f.artifacts.restrictSecretEvidence(scope: f.scope)
        await denied { _ = try await other.resolve(handle: artifact.handle, scope: f.scope) }
        await denied { _ = try await other.store(data: Data(self.sentinel.utf8), name: "derived-secret.txt", scope: f.scope) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("derived-secret.txt").path))
        var later = f.scope; later.segmentId = "derived"
        await denied { _ = try await other.register(relativePath: "capture.json", scope: later) }
        let reloaded = try AutomationArtifactRegistry(root: f.root)
        let available = await reloaded.canExposeEvidence(scope: later); XCTAssertFalse(available)
        later.runId = "unrelated"
        _ = try await reloaded.register(relativePath: "capture.json", scope: later)
    }
    private func secretProgram(_ scope: AutomationScope, phase: AutomationSegment.Phase = .setup,
                               operations: [AutomationSecretFillProgram.Operation] = [.init(id: "fill-password", binding: "credential")]) throws -> AutomationSecretFillProgram {
        try .init(scope: scope, phase: phase, operationID: "secret-program", operations: operations)
    }
    private func secretFrame(_ request: AutomationSecretFillRequest) throws -> AutomationJSON {
        .object(["scope": try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request.scope)),
                 "operationId": .string("fill-password"), "binding": .string("credential"),
                 "referenceID": .string(request.reference.id.uuidString)])
    }
    func testOpaqueProgramMappingDispatchesOnceAndNeverSerializesCredential() async throws {
        let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password"); try await grant(request, fixture: f)
        let payload = try await bindings.payload(), frame = try secretFrame(request)
        let receipt = try await bindings.handle(method: "secret.fillBinding", input: frame)
        XCTAssertEqual(receipt.object?["disposition"], .string("submittedUnconfirmed"))
        for value in [payload, frame, receipt] {
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(sentinel))
        }
        await denied { _ = try await bindings.handle(method: "secret.fillBinding", input: frame) }
        await denied { _ = try await bindings.payload() }
        let count = await probe.count(); XCTAssertEqual(count, 1)
        let exposed = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(exposed)
    }
    func testSecretBrokerRejectsChangedScopeOperationBindingReferenceAndExtraValueBeforeDispatch() async throws {
        let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password"); try await grant(request, fixture: f)
        let frame = try secretFrame(request), original = frame.object!
        var changedScope = f.scope; changedScope.attemptId = "foreign"
        let foreign = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(changedScope))
        for (key, value) in [("scope", foreign), ("operationId", .string("other")), ("binding", .string("other")),
                             ("referenceID", .string(UUID().uuidString)), ("value", .string(sentinel))] {
            var fields = original; fields[key] = value
            await denied { _ = try await bindings.handle(method: "secret.fillBinding", input: .object(fields)) }
        }
        await denied { _ = try await bindings.handle(method: "fill", input: frame) }
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let exposed = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertTrue(exposed)
        _ = try await bindings.handle(method: "secret.fillBinding", input: frame)
    }
    func testSecretRegistrationRequiresExactLiveSessionEntryAndUniqueOperationAndReference() async throws {
        let f = try await fixture(), other = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: other.root) }
        let request = try await bind(f), foreign = try await bind(other)
        let program = try secretProgram(f.scope, operations: [.init(id: "fill-password", binding: "credential"), .init(id: "second", binding: "second")])
        let bindings = AutomationSecretFillBindings(program: program, session: f.session)
        await denied { try await bindings.register(foreign, operationID: "fill-password") }
        await denied { try await bindings.register(request, operationID: "unknown") }
        try await bindings.register(request, operationID: "fill-password")
        await denied { try await bindings.register(request, operationID: "fill-password") }
        await denied { try await bindings.register(request, operationID: "second") }
        await denied { _ = try await bindings.payload() }
        await denied { _ = try await bindings.handle(method: "secret.fillBinding", input: self.secretFrame(request)) }
        await bindings.revokeAndDrain()
        await denied { try await bindings.register(request, operationID: "second") }
    }
    func testSecretMappingRejectsObserverAndAmbiguousDeclarationsAndPublicOperationDecode() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try secretProgram(f.scope, phase: .observe))
        XCTAssertThrowsError(try secretProgram(f.scope, operations: []))
        XCTAssertThrowsError(try secretProgram(f.scope, operations: [.init(id: "same", binding: "a"), .init(id: "same", binding: "b")]))
        XCTAssertThrowsError(try secretProgram(f.scope, operations: [.init(id: "a", binding: "same"), .init(id: "b", binding: "same")]))
        let operation = AutomationSecretFillProgram.Operation(id: "opaque", binding: "credential")
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationUIProgram.Operation.self, from: JSONEncoder().encode(operation)))
    }
    func testRevocationAcrossSecretRegistrationLeaseReadCannotPublishHandle() async throws {
        let gate = Gate(), f = try await fixture(leaseObservation: { await gate.hold() })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        let registration = Task { try await bindings.register(request, operationID: "fill-password") }
        await gate.wait(); await bindings.revoke(); await gate.resume()
        await denied { try await registration.value }
        await denied { _ = try await bindings.payload() }
    }
    func testSecretBrokerSanitizesAdapterErrorAndConsumesMapping() async throws {
        struct CredentialError: Error { let value: String }
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in throw CredentialError(value: value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password"); try await grant(request, fixture: f)
        do { _ = try await bindings.handle(method: "secret.fillBinding", input: secretFrame(request)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .outcomeUnresolved); XCTAssertFalse(String(describing: error).contains(sentinel)) }
        await denied { _ = try await bindings.handle(method: "secret.fillBinding", input: self.secretFrame(request)) }
    }
    func testSecretBrokerRevokeDrainsActualUncooperativeSubmissionBeforeReturning() async throws {
        actor Completion { var finished = false; func mark() { finished = true } }
        let gate = Gate(), completion = Completion()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { _, _, _ in await gate.hold() }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password"); try await grant(request, fixture: f)
        let frame = try secretFrame(request), dispatch = Task { try await bindings.handle(method: "secret.fillBinding", input: frame) }
        await gate.wait()
        let drain = Task { await bindings.revokeAndDrain(); await completion.mark() }
        for _ in 0..<20 { await Task.yield() }
        let finished = await completion.finished; XCTAssertFalse(finished)
        await gate.resume(); await drain.value
        await denied { _ = try await dispatch.value }
        let finallyFinished = await completion.finished; XCTAssertTrue(finallyFinished)
        await denied { _ = try await bindings.handle(method: "secret.fillBinding", input: frame) }
    }
    func testSecretMappingDrainWaitsForSuspendedRegistrationValidation() async throws {
        actor Completion { var finished = false; func mark() { finished = true } }
        let gate = Gate(), completion = Completion(), f = try await fixture(leaseObservation: { await gate.hold() })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        let registration = Task { try await bindings.register(request, operationID: "fill-password") }
        await gate.wait()
        let drain = Task { await bindings.revokeAndDrain(); await completion.mark() }
        for _ in 0..<20 { await Task.yield() }
        let finished = await completion.finished; XCTAssertFalse(finished)
        await gate.resume(); await drain.value
        await denied { try await registration.value }
        let finallyFinished = await completion.finished; XCTAssertTrue(finallyFinished)
        await denied { _ = try await bindings.payload() }
    }

    #if os(macOS) || os(Linux)
    func testActualOpaqueNodeWorkerUsesNativeRPCWithSpecialKeysWithoutReceivingCredential() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_NODE"],
              let entryPath = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_ENTRY"] else {
            throw XCTSkip("Requires compiled opaque source worker and explicit owned Node test path")
        }
        let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), second = try await bind(f)
        let bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope,
            operations: [.init(id: "__proto__", binding: "2"), .init(id: "second", binding: "10")]), session: f.session)
        try await bindings.register(request, operationID: "__proto__"); try await bindings.register(second, operationID: "second")
        try await grant(request, fixture: f, additional: [second])
        let payload = try await bindings.payload()
        let state = f.root.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let process = try AutomationSidecarProcess(configuration: .init(node: AutomationPath.canonical(URL(fileURLWithPath: nodePath)),
            entry: AutomationPath.canonical(URL(fileURLWithPath: entryPath)), stateDirectory: AutomationPath.canonical(state)),
            reverse: { method, input in try await bindings.handle(method: method, input: input) })
        do {
            try await process.start()
            let result = try await process.rpc.request(.runSegment, params: payload, timeout: .seconds(10))
            XCTAssertEqual(result.object?["complete"], .bool(true))
            XCTAssertEqual(result.object?["outputs"]?.object?["__proto__"]?.object?["disposition"], .string("submittedUnconfirmed"))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(sentinel))
            _ = try await process.rpc.request(.shutdown, params: .object([:]), timeout: .seconds(5))
            let stopped = await process.stop(); XCTAssertTrue(stopped)
            await bindings.revokeAndDrain()
            let logs = await process.diagnosticsSummary(); XCTAssertFalse(logs.contains(sentinel))
            let count = await probe.count(); XCTAssertEqual(count, 2)
            XCTAssertEqual(result.object?["outputs"]?.object?.count, 2)
            let exposed = await f.artifacts.canExposeEvidence(scope: f.scope); XCTAssertFalse(exposed)
        } catch {
            _ = await process.stop(); await bindings.revokeAndDrain(); throw error
        }
    }
    #endif

    func testNativeOpaqueExecutorUsesAllDeclaredHandlesOnceAndNeverExportsCredential() async throws {
        let probe = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await bind(f), second = try await bind(f)
        try await grant(first, fixture: f, additional: [second])
        let program = try secretProgram(f.scope, operations: [.init(id: "__proto__", binding: "2"), .init(id: "second", binding: "10")])
        let bindings = AutomationSecretFillBindings(program: program, session: f.session)
        try await bindings.register(first, operationID: "__proto__"); try await bindings.register(second, operationID: "second")
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {})
        let result = try await executor.run()
        XCTAssertEqual(result.object?["complete"], .bool(true)); XCTAssertEqual(result.object?["outputs"]?.object?.count, 2)
        XCTAssertEqual(result.object?["outputs"]?.object?["__proto__"]?.object?["disposition"], .string("submittedUnconfirmed"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(sentinel))
        await denied { _ = try await executor.run() }; await executor.closeAndDrain()
        let count = await probe.count(); XCTAssertEqual(count, 2)
    }
    func testNativeExecutorRejectsWrongProgramAndIncompleteMappingBeforeInput() async throws {
        for incomplete in [false, true] {
            let probe = Probe()
            let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
            defer { try? FileManager.default.removeItem(at: f.root) }
            let request = try await bind(f); try await grant(request, fixture: f)
            let declared = try secretProgram(f.scope)
            let bindings = AutomationSecretFillBindings(program: declared, session: f.session)
            if !incomplete { try await bindings.register(request, operationID: "fill-password") }
            let program = incomplete ? declared : try AutomationSecretFillProgram(scope: f.scope, phase: .setup, operationID: "foreign", operations: declared.operations)
            let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {})
            await denied { _ = try await executor.run() }
            let count = await probe.count(); XCTAssertEqual(count, 0)
            await executor.closeAndDrain()
        }
    }
    func testNativeExecutorStopDrainsUncooperativeSubmissionAndRejectsLateResult() async throws {
        let gate = Gate(), finished = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { _, _, _ in await gate.hold() }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {})
        let pending = Task { try await executor.run() }; await gate.wait()
        let stop = Task { await executor.closeAndDrain(); await finished.submit("done") }
        for _ in 0..<20 { await Task.yield() }
        let early = await finished.count(); XCTAssertEqual(early, 0)
        await gate.resume(); await stop.value
        await denied { _ = try await pending.value }
        let count = await finished.count(); XCTAssertEqual(count, 1)
    }
    func testNativeExecutorRetainsOwnerCleanupAndReturnsNoSuccessAfterStop() async throws {
        let gate = Gate(), drained = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { _, _, _ in }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: { await gate.hold() })
        let pending = Task { try await executor.run() }; await gate.wait()
        let stop = Task { await executor.closeAndDrain(); await drained.submit("done") }
        for _ in 0..<20 { await Task.yield() }
        let early = await drained.count(); XCTAssertEqual(early, 0)
        await gate.resume(); await stop.value
        await denied { _ = try await pending.value }
    }

    func testOpaqueTransportMustCorrelateActualNativeCompletion() async throws {
        for fabricated in [false, true] {
            let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
            defer { try? FileManager.default.removeItem(at: f.root) }
            let request = try await bind(f); try await grant(request, fixture: f)
            let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
            try await bindings.register(request, operationID: "fill-password")
            let transport = AutomationSecretProgramTransport(run: { payload, deadline, handler in
                XCTAssertGreaterThan(deadline, ContinuousClock.now)
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(payload), as: UTF8.self).contains("SYNTHETIC-CREDENTIAL-DO-NOT-EXPORT"))
                if !fabricated { _ = try await handler("secret.fillBinding", self.secretFrame(request)) }
                return .object(["schemaVersion": .number(1), "scope": payload.object!["scope"]!, "operationId": .string(program.operationID),
                    "complete": .bool(true), "outputs": .object(["fill-password": .object(["disposition": .string("submittedUnconfirmed")])])])
            }, closeAndDrain: { true })
            let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {}, transport: transport)
            if fabricated { await denied { _ = try await executor.run() } }
            else { let result = try await executor.run(); XCTAssertEqual(result.object?["complete"], .bool(true)) }
            let count = await probe.count(); XCTAssertEqual(count, fabricated ? 0 : 1)
            await executor.closeAndDrain()
        }
    }
    func testOpaqueTransportCannotPublishSuccessWithoutChildDrain() async throws {
        let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let transport = AutomationSecretProgramTransport(run: { payload, _, handler in
            _ = try await handler("secret.fillBinding", self.secretFrame(request))
            return .object(["schemaVersion": .number(1), "scope": payload.object!["scope"]!, "operationId": .string(program.operationID),
                "complete": .bool(true), "outputs": .object(["fill-password": .object(["disposition": .string("submittedUnconfirmed")])])])
        }, closeAndDrain: { false })
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {}, transport: transport)
        await denied { _ = try await executor.run() }; await executor.closeAndDrain()
        let count = await probe.count(); XCTAssertEqual(count, 1)
    }
    func testOpaqueTransportStopRetainsNativeCallbackAndOwnerDrain() async throws {
        let gate = Gate(), drained = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { _, _, _ in await gate.hold() }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let transport = AutomationSecretProgramTransport(run: { _, _, handler in
            _ = try await handler("secret.fillBinding", self.secretFrame(request)); throw AutomationSecretFillSession.Failure.outcomeUnresolved
        }, closeAndDrain: { await drained.submit("worker"); return true })
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: { await drained.submit("owner") }, transport: transport)
        let pending = Task { try await executor.run() }; await gate.wait()
        let stop = Task { await executor.closeAndDrain() }
        for _ in 0..<20 { await Task.yield() }
        let early = await drained.count(); XCTAssertEqual(early, 0)
        await gate.resume(); await stop.value; await denied { _ = try await pending.value }
        let count = await drained.count(); XCTAssertEqual(count, 2)
    }

    #if os(macOS)
    private func ownedTransport(_ f: Fixture, entryKey: String = "INTENTS_SECRET_PROGRAM_TEST_ENTRY") async throws -> AutomationMacSecretProgramTransport {
        guard let node = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_NODE"],
              let entry = ProcessInfo.processInfo.environment[entryKey] else { throw XCTSkip("Requires explicit owned secret-only source fixture") }
        return try AutomationMacSecretProgramTransport(configuration: .init(node: AutomationPath.canonical(URL(fileURLWithPath: node)),
            entry: AutomationPath.canonical(URL(fileURLWithPath: entry)), stateDirectory: AutomationPath.canonical(f.root).appendingPathComponent("secret-transport"), retainDiagnostics: false),
            scope: f.scope, lease: f.lease, leases: f.leases, revalidate: {})
    }
    func testSecretProcessDiagnosticDiscardDrainsWithoutRetainingBytes() async throws {
        guard let node = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_NODE"],
              let entry = ProcessInfo.processInfo.environment["INTENTS_SECRET_DIAGNOSTIC_TEST_ENTRY"] else { throw XCTSkip("Requires explicit diagnostic discard fixture") }
        for retain in [true, false] {
            let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let child = try AutomationSidecarProcess(configuration: .init(node: AutomationPath.canonical(URL(fileURLWithPath: node)),
                entry: AutomationPath.canonical(URL(fileURLWithPath: entry)), stateDirectory: root, retainDiagnostics: retain), reverse: { _, _ in throw AutomationSecretFillSession.Failure.denied })
            try await child.start()
            _ = try await child.rpc.request(.hello, params: .object([:]))
            let stopped = await child.stop(); XCTAssertTrue(stopped)
            let summary = await child.diagnosticsSummary()
            XCTAssertEqual(summary.contains("SYNTHETIC-SECRET-WORKER-DIAGNOSTIC"), retain)
        }
    }
    func testSecretTransportStopJoinsSuspendedStartupBeforeReportingAbsence() async throws {
        guard let node = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_NODE"],
              let entry = ProcessInfo.processInfo.environment["INTENTS_SECRET_PROGRAM_TEST_ENTRY"] else { throw XCTSkip("Requires owned secret entry") }
        let gate = Gate(), done = Probe(), f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f), program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let transport = try AutomationMacSecretProgramTransport(configuration: .init(node: AutomationPath.canonical(URL(fileURLWithPath: node)),
            entry: AutomationPath.canonical(URL(fileURLWithPath: entry)), stateDirectory: AutomationPath.canonical(f.root).appendingPathComponent("suspended-worker"), retainDiagnostics: false),
            scope: f.scope, lease: f.lease, leases: f.leases, revalidate: {}, beforeStart: { await gate.hold() })
        let capability = await transport.capability(), payload = try await bindings.payload()
        let pending = Task { try await capability.run(payload, .now + .seconds(30), .init(handle: { _, _ in XCTFail("Callback after startup Stop"); throw AutomationSecretFillSession.Failure.denied })) }
        await gate.wait()
        let stop = Task { let drained = await transport.closeAndDrain(); XCTAssertTrue(drained); await done.submit("joined") }
        for _ in 0..<20 { await Task.yield() }
        let early = await done.count(); XCTAssertEqual(early, 0)
        await gate.resume(); await stop.value; await denied { _ = try await pending.value }
        let record = try await f.leases.currentRecord(f.lease); XCTAssertTrue(record.runners.isEmpty)
        let again = await transport.closeAndDrain(); XCTAssertTrue(again)
        await bindings.revokeAndDrain(); try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testOwnedSecretProcessDeadlineCoversSilentHandshake() async throws {
        let probe = Probe(), f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { value, _, _ in await probe.submit(value) }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try AutomationSecretFillProgram(scope: f.scope, phase: .setup, operationID: "deadline", operations: [.init(id: "fill-password", binding: "credential")], timeoutMilliseconds: 100)
        let bindings = AutomationSecretFillBindings(program: program, session: f.session); try await bindings.register(request, operationID: "fill-password")
        let transport = try await ownedTransport(f, entryKey: "INTENTS_SECRET_SILENT_TEST_ENTRY")
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {}, transport: await transport.capability())
        let start = ContinuousClock.now
        await denied { _ = try await executor.run() }; await executor.closeAndDrain()
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let record = try await f.leases.currentRecord(f.lease); XCTAssertEqual(record.runners.count, 1)
        XCTAssertNil(record.lastDispatch)
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testActualOwnedSecretProcessStopJoinsUncooperativeNativeCallback() async throws {
        let gate = Gate(), done = Probe()
        let f = try await fixture(adapter: .init(validateSink: { _, _ in }, submit: { _, _, _ in await gate.hold() }))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await bind(f); try await grant(request, fixture: f)
        let program = try secretProgram(f.scope), bindings = AutomationSecretFillBindings(program: try secretProgram(f.scope), session: f.session)
        try await bindings.register(request, operationID: "fill-password")
        let transport = try await ownedTransport(f)
        let executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: {}, transport: await transport.capability())
        let pending = Task { try await executor.run() }; await gate.wait()
        let active = try await f.leases.currentRecord(f.lease); XCTAssertEqual(active.runners.count, 1); XCTAssertEqual(active.lastDispatch?.operationID, program.operationID)
        let stop = Task { await executor.closeAndDrain(); await done.submit("drained") }
        for _ in 0..<20 { await Task.yield() }
        let early = await done.count(); XCTAssertEqual(early, 0)
        let held = await f.leases.isCurrent(f.lease); XCTAssertTrue(held)
        await gate.resume(); await stop.value; await denied { _ = try await pending.value }
        let count = await done.count(); XCTAssertEqual(count, 1)
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    #endif

}
