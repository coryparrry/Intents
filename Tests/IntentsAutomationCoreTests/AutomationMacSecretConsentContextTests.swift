#if os(macOS)
import ApplicationServices
import XCTest
@testable import IntentsAutomationCore

@MainActor final class AutomationMacSecretConsentContextTests: XCTestCase {
    private let sentinel = "SYNTHETIC-NATIVE-CONTEXT-CREDENTIAL"
    private final class Field: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func replace(_ value: String) { lock.withLock { values.append(value) } }
        func count() -> Int { lock.withLock { values.count } }
    }
    private actor Gate {
        var entered = false, finished = false
        var listeners: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; listeners.forEach { $0.resume() }; listeners.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
        func resume() { release?.resume(); release = nil }
        func finish() { finished = true }
        func drained() -> Bool { finished }
    }
    private final class SyntheticPresenter: AutomationSecretConsentPresenting {
        let model: AutomationSecretConsentModel, secret: String
        let gate: Gate?
        private(set) var presentations = 0
        init(model: AutomationSecretConsentModel, secret: String, gate: Gate?) { self.model = model; self.secret = secret; self.gate = gate }
        func present() async throws -> AutomationSecretFillRequest {
            presentations += 1
            if let gate { await gate.hold() }
            try await model.prepare(); return try await model.confirm(secret)
        }
        func cancelAndDrain() async { await model.cancelAndDrain() }
    }
    private struct Fixture {
        let approval: RunApproval
        let program: AutomationSecretFillProgram
        let lease: AutomationDeviceLeaseManager.Lease
        let leases: AutomationDeviceLeaseManager
        let authority: AutomationRunAuthority
        let artifacts: AutomationArtifactRegistry
        let owner: AutomationMacSecureSink<Int>
        let session: AutomationSecretFillSession
        let presenter: SyntheticPresenter
        let context: AutomationMacSecretConsentContext<Int>
        let field: Field
        let root: URL
    }
    private func fixture(gate: Gate? = nil, environment: String = "synthetic", ownedWorker: Bool = false, frozenWorker: Bool = false) async throws -> Fixture {
        var app = AppIdentity(logicalID: "app", bundleID: "test.Secret", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2; app.canonicalBundlePath = "/synthetic/Secret.app"
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session")
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: environment, effects: [.observe, .navigate, .fixtureWrite],
            maximumActions: 10, disposable: true, approvedCaseDigest: String(repeating: "b", count: 64))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let leases = frozenWorker ? try AutomationDeviceLeaseManager(storeURL: AutomationPath.canonical(root).appendingPathComponent("leases.json")) : AutomationDeviceLeaseManager()
        let field = Field()
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let fence = try await leases.nativeInputFence(for: lease)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let program = try AutomationSecretFillProgram(scope: scope, phase: .setup, operationID: "private-secret", operations: [.init(id: "__proto__", binding: "10")])
        let owner = try AutomationMacSecureSink<Int>(approval: approval, scope: scope, dependencies: .init(
            checkInputOwnership: { guard fence.isCurrent else { throw AutomationSecretFillSession.Failure.denied } },
            validateContext: {}, resolve: { 1 }, verify: { _ in }, same: { $0 == $1 }, replace: { _, value in field.replace(value) }))
        try await owner.open()
        let authority = AutomationRunAuthority(approval: approval, leases: leases, artifacts: artifacts)
        let session = AutomationSecretFillSession(approval: approval, lease: lease, leases: leases, authority: authority, artifacts: artifacts, adapter: await owner.adapter())
        let model = AutomationSecretConsentModel(review: owner.review, session: session, validateSink: { try await owner.validateConsent($0) })
        let presenter = SyntheticPresenter(model: model, secret: sentinel, gate: gate)
        var transport: AutomationSecretProgramTransport?
        if frozenWorker {
            guard let runtime = ProcessInfo.processInfo.environment["INTENTS_MAC_SECRET_RUNTIME"] else { throw XCTSkip("Requires explicitly selected frozen secret runtime") }
            let worker = try await AutomationMacSecretProgramTransport.owned(unitRoot: AutomationPath.canonical(URL(fileURLWithPath: runtime)),
                state: AutomationPath.canonical(root).appendingPathComponent("secret-worker"), scope: scope, lease: lease, leases: leases)
            transport = await worker.capability()
        } else if ownedWorker {
            guard let node = ProcessInfo.processInfo.environment["INTENTS_SECRET_TEST_NODE"],
                  let entry = ProcessInfo.processInfo.environment["INTENTS_SECRET_PROGRAM_TEST_ENTRY"] else { throw XCTSkip("Requires explicit secret-only owned source entry") }
            let worker = try AutomationMacSecretProgramTransport(configuration: .init(node: AutomationPath.canonical(URL(fileURLWithPath: node)),
                entry: AutomationPath.canonical(URL(fileURLWithPath: entry)), stateDirectory: AutomationPath.canonical(root).appendingPathComponent("secret-worker"), retainDiagnostics: false),
                scope: scope, lease: lease, leases: leases, revalidate: {})
            transport = await worker.capability()
        }
        let context = try AutomationMacSecretConsentContext(program: program, session: session, owner: owner, presenter: presenter, transport: transport)
        return .init(approval: approval, program: program, lease: lease, leases: leases, authority: authority, artifacts: artifacts,
            owner: owner, session: session, presenter: presenter, context: context, field: field, root: root)
    }
    private func grant(_ request: AutomationSecretFillRequest, fixture f: Fixture) async throws {
        let segment = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "secretFill", effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        try await f.authority.approve(scope: f.program.scope, lease: f.lease, segment: segment,
            actions: [.activate, .fillSecret(referenceID: request.reference.id.uuidString, sinkID: request.sinkID)])
        var fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(f.program.scope)).object!
        fields["effect"] = .string("activate")
        fields["target"] = .object(["id": .string(f.approval.target.id), "platform": .string("macos"), "kind": .string("nativeMac"),
            "bundleId": .string(f.approval.app.bundleID), "bundlePath": .string(f.approval.app.canonicalBundlePath!), "loginSession": .string(f.approval.target.loginSession!)])
        let result = await f.authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(result, .object(["allowed": .bool(true)]))
    }
    func testNativeConsentContextRegistersExecutesAndDrainsWithoutCredentialExport() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        do { _ = try await f.context.run(); XCTFail("Execution before consent") } catch {}
        let request = try await f.context.collectConsent(); try await grant(request, fixture: f)
        let exposed = await f.artifacts.canExposeEvidence(scope: f.program.scope); XCTAssertFalse(exposed)
        let result = try await f.context.run()
        XCTAssertEqual(result.object?["complete"], .bool(true)); XCTAssertEqual(f.field.count(), 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(sentinel))
        do { _ = try await f.context.run(); XCTFail("Replayed consumed consent") } catch {}
        await f.context.closeAndDrain()
        do { try await f.owner.validateConsent(f.owner.review); XCTFail("Owner remained live") } catch {}
    }
    func testActualOwnedSecretEntryFollowsConsentAndReleasesExactRecordedChild() async throws {
        let f = try await fixture(ownedWorker: true); defer { try? FileManager.default.removeItem(at: f.root) }
        do { _ = try await f.context.run(); XCTFail("Worker before consent") } catch {}
        let before = try await f.leases.currentRecord(f.lease); XCTAssertTrue(before.runners.isEmpty)
        let request = try await f.context.collectConsent(); try await grant(request, fixture: f)
        let result = try await f.context.run(); XCTAssertEqual(result.object?["complete"], .bool(true)); XCTAssertEqual(f.field.count(), 1)
        let record = try await f.leases.currentRecord(f.lease); XCTAssertEqual(record.runners.count, 1)
        XCTAssertEqual(record.runners.first?.role, .sidecar)
        let presence = record.runners.first!.process.presence()
        switch presence { case .absent, .replaced: break; case .matching, .unknown: XCTFail("Owned child not gone") }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(sentinel))
        await f.context.closeAndDrain()
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
        let current = await f.leases.isCurrent(f.lease); XCTAssertFalse(current)
    }
    func testFrozenOwnedSecretFactoryUsesDurableLeaseWithoutCredentialInJournal() async throws {
        let f = try await fixture(frozenWorker: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try await f.context.collectConsent(); try await grant(request, fixture: f)
        let result = try await f.context.run(); XCTAssertEqual(result.object?["complete"], .bool(true)); XCTAssertEqual(f.field.count(), 1)
        let record = try await f.leases.currentRecord(f.lease); XCTAssertEqual(record.runners.count, 1)
        XCTAssertEqual(record.lastDispatch?.operationID, f.program.operationID)
        let journal = try String(contentsOf: AutomationPath.canonical(f.root).appendingPathComponent("secret-worker/opaque-secret-journal.json"), encoding: .utf8)
        XCTAssertFalse(journal.contains(sentinel)); XCTAssertFalse(journal.contains(request.reference.id.uuidString))
        await f.context.closeAndDrain()
        try await f.leases.release(f.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testConsentAloneCannotDispatchWithoutRunAuthority() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.context.collectConsent()
        do { _ = try await f.context.run(); XCTFail("Unadmitted write") } catch {}
        XCTAssertEqual(f.field.count(), 0); await f.context.closeAndDrain()
    }
    func testStopDrainsUncooperativePresenterAndRejectsLateConsent() async throws {
        let gate = Gate(), finish = Gate()
        let f = try await fixture(gate: gate); defer { try? FileManager.default.removeItem(at: f.root) }
        let pending = Task { try await f.context.collectConsent() }; await gate.wait()
        let stop = Task { await f.context.closeAndDrain(); await finish.finish() }
        for _ in 0..<20 { await Task.yield() }
        let early = await finish.drained(); XCTAssertFalse(early)
        await gate.resume(); await stop.value
        do { _ = try await pending.value; XCTFail("Late consent published") } catch {}
        XCTAssertEqual(f.field.count(), 0)
    }
    func testCallerCancellationRetainsPresenterWorkUntilItFinishes() async throws {
        let gate = Gate(), finish = Gate()
        let f = try await fixture(gate: gate); defer { try? FileManager.default.removeItem(at: f.root) }
        let pending = Task { do { _ = try await f.context.collectConsent() } catch {}; await finish.finish() }
        await gate.wait(); pending.cancel()
        for _ in 0..<20 { await Task.yield() }
        let early = await finish.drained(); XCTAssertFalse(early)
        await gate.resume(); await pending.value; await f.context.closeAndDrain()
        XCTAssertEqual(f.field.count(), 0)
    }
    func testForeignSinkPresenterWithSameScopeCannotRegisterOrExecute() async throws {
        let a = try await fixture(), b = try await fixture()
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let context = try AutomationMacSecretConsentContext(program: a.program, session: a.session, owner: a.owner, presenter: b.presenter)
        do { _ = try await context.collectConsent(); XCTFail("Foreign sink consent registered") } catch {}
        do { _ = try await context.run(); XCTFail("Foreign sink executed") } catch {}
        XCTAssertEqual(a.field.count(), 0); XCTAssertEqual(b.field.count(), 0)
        await context.closeAndDrain(); await b.context.closeAndDrain()
    }
    func testForeignFullApprovalSessionCannotReachPresentation() async throws {
        let a = try await fixture(), b = try await fixture(environment: "foreign")
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let context = try AutomationMacSecretConsentContext(program: a.program, session: b.session, owner: a.owner, presenter: b.presenter)
        do { _ = try await context.collectConsent(); XCTFail("Foreign approval reached presenter") } catch {}
        XCTAssertEqual(b.presenter.presentations, 0)
        XCTAssertEqual(a.field.count(), 0); XCTAssertEqual(b.field.count(), 0)
        await context.closeAndDrain(); await b.context.closeAndDrain()
    }
    func testProductionFactoryRefusesEphemeralLeaseBeforeNativeAXOrPresentation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await AutomationMacSecretConsentContext<AXUIElement>.prepare(approval: f.approval, program: f.program,
                lease: f.lease, leases: f.leases, authority: f.authority, artifacts: f.artifacts, x: 0, y: 0)
            XCTFail("Ephemeral production admission")
        } catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
        XCTAssertEqual(f.field.count(), 0); await f.context.closeAndDrain()
    }
}
#endif
