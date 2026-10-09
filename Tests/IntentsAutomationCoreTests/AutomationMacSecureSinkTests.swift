#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor final class AutomationMacSecureSinkTests: XCTestCase {
    private let sentinel = "SYNTHETIC-RETAINED-SECURE-FIELD"
    private final class NativeState: @unchecked Sendable {
        private let lock = NSLock()
        private var element = 1, secure = true, allowed = true, failWrite = false
        private var values: [String] = []
        private var block: (@Sendable () -> Void)?
        func resolve() -> Int { lock.withLock { element } }
        func replaceElement() { lock.withLock { element += 1 } }
        func changeRole() { lock.withLock { secure = false } }
        func changeContext() { lock.withLock { allowed = false } }
        func failSubmission() { lock.withLock { failWrite = true } }
        func context() throws {
            guard lock.withLock({ allowed }) else { throw AutomationSecretFillSession.Failure.denied }
        }
        func blockNextVerify(_ body: @escaping @Sendable () -> Void) { lock.withLock { block = body } }
        func verify(_ element: Int) throws {
            let wait = lock.withLock { let value = block; block = nil; return value }; wait?()
            guard lock.withLock({ secure && element > 0 }) else { throw AutomationSecretFillSession.Failure.denied }
        }
        func replace(_ element: Int, value: String) throws {
            try lock.withLock {
                guard element == self.element, secure, allowed else { throw AutomationSecretFillSession.Failure.denied }
                values.append(value)
                if failWrite { throw NSError(domain: value, code: 1) }
            }
        }
        func submitted() -> [String] { lock.withLock { values } }
    }
    private final class SyncGate: @unchecked Sendable {
        private let lock = NSLock(), release = DispatchSemaphore(value: 0)
        private var entered = false
        func hold() { lock.withLock { entered = true }; release.wait() }
        func wait() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !lock.withLock({ entered }) {
                guard ContinuousClock.now < deadline else { throw AutomationSecretFillSession.Failure.denied }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func resume() { release.signal() }
    }
    private actor Gate {
        var entered = false, finished = false, checks = 0
        var listeners: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; listeners.forEach { $0.resume() }; listeners.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
        func resume() { release?.resume(); release = nil }
        func checkAndHold(_ call: Int) async { checks += 1; if checks == call { await hold() } }
        func finish() { finished = true }
        func drained() -> Bool { finished }
    }
    private func approval() -> RunApproval {
        var app = AppIdentity(logicalID: "app", bundleID: "test.Secure", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2; app.canonicalBundlePath = "/synthetic/Secure.app"
        return .init(runID: "secure-run", app: app, target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session"),
            environmentID: "synthetic", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true,
            approvedCaseDigest: String(repeating: "b", count: 64))
    }
    private func owner(_ state: NativeState, scope: AutomationScope? = nil, timeout: Duration = .seconds(5),
                       context: (@Sendable () async throws -> Void)? = nil, ownership: (@Sendable () throws -> Void)? = nil) throws -> AutomationMacSecureSink<Int> {
        let check: @Sendable () async throws -> Void
        if let context { check = context } else { check = { try state.context() } }
        return try .init(approval: approval(), scope: scope ?? .init(runID: "secure-run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1),
            dependencies: .init(checkInputOwnership: ownership ?? { try state.context() }, validateContext: check, resolve: { state.resolve() }, verify: { try state.verify($0) },
                same: { $0 == $1 }, replace: { try state.replace($0, value: $1) }), timeout: timeout)
    }
    private func request(_ owner: AutomationMacSecureSink<Int>) -> AutomationSecretFillRequest {
        .init(reference: .init(id: UUID()), scope: owner.review.scope, sinkID: owner.review.sinkID, sinkFingerprint: owner.review.sinkFingerprint)
    }
    private func denied(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
    }
    func testRetainedSinkWorksOnlyOnceAndHasNoCredentialReadbackAPI() async throws {
        let state = NativeState(), sink = try owner(NativeState())
        // Independent native objects receive distinct consent fingerprints.
        let actual = try owner(state)
        XCTAssertNotEqual(actual.review.sinkFingerprint, sink.review.sinkFingerprint)
        try await actual.open(); try await actual.validateConsent(actual.review)
        let adapter = await actual.adapter(), request = request(actual)
        try await adapter.validateSink(request, approval())
        try await adapter.submit(sentinel, request, approval())
        XCTAssertEqual(state.submitted(), [sentinel])
        await denied { try await adapter.submit(self.sentinel, request, self.approval()) }
        await actual.closeAndDrain()
    }
    func testReplacementObjectAtSamePointCannotInheritConsent() async throws {
        let state = NativeState()
        let actual = try owner(state); try await actual.open()
        state.replaceElement()
        await denied { try await actual.validateConsent(actual.review) }
        let adapter = await actual.adapter()
        await denied { try await adapter.submit(self.sentinel, self.request(actual), self.approval()) }
        XCTAssertTrue(state.submitted().isEmpty)
    }
    func testChangedSecureRoleOrExactContextCannotSubmit() async throws {
        for changeRole in [true, false] {
            let state = NativeState()
            let actual = try owner(state); try await actual.open()
            if changeRole { state.changeRole() } else { state.changeContext() }
            let adapter = await actual.adapter()
            await denied { try await adapter.submit(self.sentinel, self.request(actual), self.approval()) }
            XCTAssertTrue(state.submitted().isEmpty)
        }
    }
    func testForeignScopeFingerprintAndApprovalDeniedBeforeInput() async throws {
        let state = NativeState()
        let actual = try owner(state); try await actual.open()
        let adapter = await actual.adapter(), original = request(actual)
        var scope = original.scope; scope.attemptId = "other"
        let altered = AutomationSecretFillRequest(reference: original.reference, scope: scope, sinkID: original.sinkID, sinkFingerprint: original.sinkFingerprint)
        await denied { try await adapter.submit(self.sentinel, altered, self.approval()) }
        let other = try owner(NativeState())
        await denied { try await adapter.submit(self.sentinel, self.request(other), self.approval()) }
        var approval = approval(); approval.environmentID = "other"
        await denied { try await adapter.submit(self.sentinel, original, approval) }
        XCTAssertTrue(state.submitted().isEmpty)
    }
    func testUncertainWriteSanitizesAndConsumesWithoutRetry() async throws {
        let state = NativeState(); let actual = try owner(state); try await actual.open()
        state.failSubmission(); let adapter = await actual.adapter(), request = request(actual)
        await denied { try await adapter.submit(self.sentinel, request, self.approval()) }
        await denied { try await adapter.submit(self.sentinel, request, self.approval()) }
        XCTAssertEqual(state.submitted(), [sentinel])
    }
    func testCloseDrainsHeldContextAndPreventsLatePin() async throws {
        let gate = Gate(); let actual = try owner(NativeState(), context: { await gate.hold() })
        let pending = Task { try await actual.open() }; await gate.wait()
        let close = Task { await actual.closeAndDrain(); await gate.finish() }
        for _ in 0..<20 { await Task.yield() }
        let early = await gate.drained(); XCTAssertFalse(early)
        await gate.resume(); await close.value
        do { try await pending.value; XCTFail("Closed owner pinned late field") } catch {}
        await denied { try await actual.validateConsent(actual.review) }
    }
    func testStopCancelsBlockedSynchronousValidationBeforeWrite() async throws {
        let state = NativeState(), gate = SyncGate(), drained = Gate()
        let actual = try owner(state); try await actual.open()
        let adapter = await actual.adapter(), request = request(actual)
        state.blockNextVerify { gate.hold() }
        let pending = Task { try await adapter.submit(self.sentinel, request, self.approval()) }
        try await gate.wait()
        let close = Task { await actual.closeAndDrain(); await drained.finish() }
        try await Task.sleep(for: .milliseconds(20))
        let early = await drained.drained(); XCTAssertFalse(early)
        gate.resume(); await close.value
        do { try await pending.value; XCTFail("Stop permitted late synchronous write") } catch {}
        XCTAssertTrue(state.submitted().isEmpty)
    }
    func testLeaseFenceRejectsReleaseDuringSynchronousValidation() async throws {
        let approved = approval(), leases = AutomationDeviceLeaseManager(), state = NativeState(), gate = SyncGate()
        let lease = try await leases.acquire(runID: approved.runID, target: approved.target, control: .ui)
        let fence = try await leases.nativeInputFence(for: lease)
        let actual = try owner(state, ownership: { guard fence.isCurrent else { throw AutomationSecretFillSession.Failure.denied } })
        try await actual.open(); let adapter = await actual.adapter(), request = request(actual)
        state.blockNextVerify { gate.hold() }
        let pending = Task { try await adapter.submit(self.sentinel, request, approved) }
        try await gate.wait()
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        gate.resume()
        do { try await pending.value; XCTFail("Released lease permitted synchronous write") } catch {}
        XCTAssertTrue(state.submitted().isEmpty); await actual.closeAndDrain()
    }
    func testExpiredOperationRetainsActualWorkAndRefusesLateSubmission() async throws {
        let gate = Gate(), state = NativeState()
        let actual = try owner(state, timeout: .milliseconds(10), context: { await gate.hold() })
        let pending = Task { try await actual.open() }; await gate.wait()
        try await Task.sleep(for: .milliseconds(30)); await gate.resume()
        do { try await pending.value; XCTFail("Expired metadata admitted") } catch {}
        XCTAssertTrue(state.submitted().isEmpty)
        await actual.closeAndDrain()
    }
    func testInheritedProgramDeadlineCannotExtendToNativeFiveSecondBudget() async throws {
        let gate = Gate(), state = NativeState()
        let actual = try owner(state, context: { await gate.checkAndHold(2) })
        try await actual.open(); let adapter = await actual.adapter(), request = request(actual)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(10))
        let pending = Task {
            try await AutomationNativeSecretDeadline.$value.withValue(deadline) {
                try await adapter.submit(self.sentinel, request, self.approval())
            }
        }
        await gate.wait(); try await Task.sleep(for: .milliseconds(30)); await gate.resume()
        do { try await pending.value; XCTFail("Native adapter extended inherited deadline") } catch {}
        XCTAssertTrue(state.submitted().isEmpty); await actual.closeAndDrain()
    }
    func testConsentAndRunAuthorityComposeWithRetainedNativeAdapter() async throws {
        try await exerciseComposition()
    }
    func testSessionCannotWriteAfterLeaseEndsDuringSubmitContext() async throws {
        try await exerciseComposition(releaseBeforeSubmit: true)
    }
    private func exerciseComposition(releaseBeforeSubmit: Bool = false) async throws {
        let approved = approval(), state = NativeState(), leases = AutomationDeviceLeaseManager(), gate = Gate()
        let lease = try await leases.acquire(runID: approved.runID, target: approved.target, control: .ui)
        let scope = AutomationScope(runID: approved.runID, attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let fence = try await leases.nativeInputFence(for: lease)
        let actual = try owner(state, scope: scope, context: { try state.context(); if releaseBeforeSubmit { await gate.checkAndHold(5) } }, ownership: { guard fence.isCurrent else { throw AutomationSecretFillSession.Failure.denied } }); try await actual.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try AutomationArtifactRegistry(root: root)
        let authority = AutomationRunAuthority(approval: approved, leases: leases, artifacts: artifacts)
        let session = AutomationSecretFillSession(approval: approved, lease: lease, leases: leases, authority: authority, artifacts: artifacts, adapter: await actual.adapter())
        let model = AutomationSecretConsentModel(review: actual.review, session: session, validateSink: { try await actual.validateConsent($0) })
        try await model.prepare(); let request = try await model.confirm(sentinel)
        let segment = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "secretFill", effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate, .fillSecret(referenceID: request.reference.id.uuidString, sinkID: request.sinkID)])
        var fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope)).object!
        fields["effect"] = .string("activate")
        fields["target"] = .object(["id": .string(approved.target.id), "platform": .string("macos"), "kind": .string("nativeMac"),
            "bundleId": .string(approved.app.bundleID), "bundlePath": .string(approved.app.canonicalBundlePath!), "loginSession": .string(approved.target.loginSession!)])
        let activation = await authority.review(method: "policy.reviewAction", params: .object(fields))
        XCTAssertEqual(activation, .object(["allowed": .bool(true)]))
        if releaseBeforeSubmit {
            let pending = Task { try await session.fill(request) }; await gate.wait()
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            await gate.resume()
            do { _ = try await pending.value; XCTFail("Session wrote after lease loss during submit") } catch {}
            XCTAssertTrue(state.submitted().isEmpty)
        } else {
            let receipt = try await session.fill(request)
            XCTAssertEqual(receipt.disposition, "submittedUnconfirmed"); XCTAssertEqual(state.submitted(), [sentinel])
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains(sentinel))
        }
        let exposed = await artifacts.canExposeEvidence(scope: scope); XCTAssertFalse(exposed)
        await model.cancelAndDrain(); await actual.closeAndDrain()
    }
}
#endif
