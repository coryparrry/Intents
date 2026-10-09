#if os(macOS)
import ApplicationServices
import AppKit
import XCTest
@testable import IntentsAutomationCore

private enum Fixture {
    static let pid: pid_t = 4242, appElement = 100, field = 1
}

@MainActor final class AutomationMacSecureFillTests: XCTestCase {
    private typealias Fill = AutomationMacSecureFill
    private let sentinel = "SYNTHETIC-SECURE-FILL-VALUE"
    private struct Node {
        var pid: pid_t? = Fixture.pid
        var role: Fill.AttributeValue? = .string(kAXGroupRole)
        var subrole: Fill.AttributeValue?
        var enabled: Fill.AttributeValue?
        var settable: Bool?
        var parent: Int?
    }
    private struct State {
        var nodes: [Int: Node] = [
            Fixture.field: Node(role: .string(kAXTextFieldRole), subrole: .string(kAXSecureTextFieldSubrole), enabled: .bool(true), settable: true, parent: 2),
            2: Node(role: .string(kAXWindowRole), parent: 3),
            3: Node(role: .string(kAXApplicationRole)),
        ]
        var hit: Int? = Fixture.field
        var targetValid = true, trusted = true, writeSucceeds = true
        var frontmost: pid_t? = Fixture.pid
        var inspected: AutomationProcessIdentity? = .init(pid: Fixture.pid, startIdentity: "synthetic-start")
        var presence: [AutomationProcessIdentity.Presence] = []
        var application: Fill.Application? = .init(bundleID: "test.Secure", canonicalBundlePath: "/synthetic/Secure.app", isTerminated: false)
        var digest = String(repeating: "a", count: 64)
        var uniques: Fill.SigningUniques? = .init(disk: Data([0xab, 0x01]), running: Data([0xab, 0x01]))
        var owner: Fill.ProcessOwner? = .init(uid: 501, ruid: 501)
        var uid: uid_t = 501
        var timeoutFailures: Set<Int> = []
        var nativeCalls = 0
        var positions: [Float] = []
        var written: [String] = []
        var writtenElements: [Int] = []
        var ownerChecks = 0
        var onOwnerCheck: (@Sendable (Int) -> Void)?
    }
    private final class Native: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()
        func set(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
        func get<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
        func call<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { state.nativeCalls += 1; return try body(&state) } }
        var platform: Fill.Platform<Int> {
            .init(
                validateTarget: { _ in
                    guard self.call({ $0.targetValid }) else { throw AutomationContractError.conflictingOperation }
                },
                isAccessibilityTrusted: { self.call { $0.trusted } },
                frontmostPID: { self.call { $0.frontmost } },
                inspect: { pid in self.call { $0.inspected?.pid == pid ? $0.inspected : nil } },
                presence: { _ in self.call { $0.presence.isEmpty ? .matching : $0.presence.removeFirst() } },
                application: { pid in self.call { pid == Fixture.pid ? $0.application : nil } },
                productDigest: { url in
                    try self.call { state in
                        guard url.path == "/synthetic/Secure.app" else { throw AutomationContractError.invalidIdentity }
                        return state.digest
                    }
                },
                signingUniques: { url, pid in
                    self.call { url.path == "/synthetic/Secure.app" && pid == Fixture.pid ? $0.uniques : nil }
                },
                processOwner: { pid in
                    self.call { state in
                        state.ownerChecks += 1
                        state.onOwnerCheck?(state.ownerChecks)
                        return pid == Fixture.pid ? state.owner : nil
                    }
                },
                currentUID: { self.call { $0.uid } },
                accessibility: .init(
                    application: { pid in self.call { _ in pid == Fixture.pid ? Fixture.appElement : -1 } },
                    setTimeout: { element in self.call { !$0.timeoutFailures.contains(element) } },
                    element: { app, x, y in
                        self.call { state in
                            state.positions += [x, y]
                            return app == Fixture.appElement ? state.hit : nil
                        }
                    },
                    pid: { element in self.call { $0.nodes[element]?.pid } },
                    attribute: { element, name in
                        self.call { state in
                            guard let node = state.nodes[element] else { return nil }
                            switch name {
                            case kAXRoleAttribute: return node.role
                            case kAXSubroleAttribute: return node.subrole
                            case kAXEnabledAttribute: return node.enabled
                            default: return nil
                            }
                        }
                    },
                    parent: { element in self.call { $0.nodes[element]?.parent } },
                    isValueSettable: { element in self.call { $0.nodes[element]?.settable } },
                    setValue: { element, value in
                        self.call { state in
                            guard state.writeSucceeds else { return false }
                            state.writtenElements.append(element); state.written.append(value); return true
                        }
                    },
                    same: { $0 == $1 }))
        }
    }

    private func approval(codeDirectoryIdentity: String? = nil, bundlePath: String? = "/synthetic/Secure.app") -> RunApproval {
        var app = AppIdentity(logicalID: "app", bundleID: "test.Secure", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2; app.canonicalBundlePath = bundlePath; app.codeDirectoryIdentity = codeDirectoryIdentity
        return .init(runID: "secure-run", app: app, target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session"),
            environmentID: "synthetic", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true,
            approvedCaseDigest: String(repeating: "b", count: 64))
    }
    private func makeFence(_ approval: RunApproval, runID: String? = nil, generation: Int = 1,
                       control: AutomationDeviceLeaseManager.Lease.Control = .ui) -> AutomationNativeInputLeaseFence {
        .init(lease: .init(runID: runID ?? approval.runID, target: approval.target, generation: generation, control: control), persisted: nil)
    }
    private func makeContext(_ native: Native, approval: RunApproval? = nil, fence: AutomationNativeInputLeaseFence? = nil) -> Fill.Context<Int> {
        let approved = approval ?? self.approval()
        return .init(approval: approved, process: .init(pid: Fixture.pid, startIdentity: "synthetic-start"),
                     leaseFence: fence ?? self.makeFence(approved), x: 120.5, y: 64, platform: native.platform)
    }
    private func makeScope(generation: Int = 1) -> AutomationScope {
        .init(runID: "secure-run", attemptID: "attempt", segmentID: "setup", leaseGeneration: generation)
    }
    private func withDeadline<T>(_ body: () throws -> T) throws -> T {
        try AutomationNativeSecretDeadline.$value.withValue(ContinuousClock.now.advanced(by: .seconds(5))) { try body() }
    }
    private func assertDenied(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do { try withDeadline(body); XCTFail("Expected refusal: \(message)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied, message, file: file, line: line) }
    }
    private func assertCaptureDenied(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                     _ body: () async throws -> AutomationMacSecureSink<Int>) async {
        do { _ = try await body(); XCTFail("Expected capture refusal: \(message)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied, message, file: file, line: line) }
    }
    private func chain(_ native: Native, applicationDepth: Int) {
        native.set { state in
            var nodes = [Fixture.field: Node(role: .string(kAXTextFieldRole), subrole: .string(kAXSecureTextFieldSubrole),
                                          enabled: .bool(true), settable: true, parent: 1_001)]
            for depth in 1..<applicationDepth { nodes[1_000 + depth] = Node(parent: 1_000 + depth + 1) }
            nodes[1_000 + applicationDepth] = Node(role: .string(kAXApplicationRole))
            state.nodes = nodes
        }
    }

    func testVerifiedSecureFieldResolvesAtCoordinatesAndReceivesExactlyTheValue() throws {
        let native = Native(), context = makeContext(native)
        let element = try withDeadline { try context.resolve() }
        XCTAssertEqual(element, Fixture.field)
        XCTAssertEqual(native.get { $0.positions }, [120.5, 64])
        try withDeadline { try context.verifyField(element); try context.replace(element, value: sentinel) }
        XCTAssertEqual(native.get { $0.written }, [sentinel])
        XCTAssertEqual(native.get { $0.writtenElements }, [Fixture.field])
    }

    func testNonSecureDisabledUnsettableOrForeignFieldsAreDenied() {
        let mutations: [(String, (inout Node) -> Void)] = [
            ("plain text field", { $0.subrole = .string("AXSearchField") }),
            ("missing subrole", { $0.subrole = nil }),
            ("non-string subrole", { $0.subrole = .other }),
            ("non-text role", { $0.role = .string(kAXStaticTextRole) }),
            ("missing role", { $0.role = nil }),
            ("disabled", { $0.enabled = .bool(false) }),
            ("non-boolean enabled", { $0.enabled = .other }),
            ("missing enabled", { $0.enabled = nil }),
            ("value not settable", { $0.settable = false }),
            ("settable query failed", { $0.settable = nil }),
            ("foreign pid", { $0.pid = Fixture.pid + 1 }),
            ("pid query failed", { $0.pid = nil }),
        ]
        for (name, mutate) in mutations {
            let native = Native(); native.set { mutate(&$0.nodes[Fixture.field]!) }
            let context = makeContext(native)
            assertDenied(name) { try context.verifyField(Fixture.field) }
            assertDenied(name) { try context.replace(Fixture.field, value: self.sentinel) }
            XCTAssertTrue(native.get { $0.written.isEmpty }, name)
        }
    }

    func testAncestorChainMustStayInOwningProcessAndReachApplication() {
        let mutations: [(String, (inout State) -> Void)] = [
            ("foreign ancestor", { $0.nodes[2]!.pid = Fixture.pid + 1 }),
            ("ancestor pid query failed", { $0.nodes[2]!.pid = nil }),
            ("ancestor role query failed", { $0.nodes[2]!.role = nil }),
            ("missing parent", { $0.nodes[2]!.parent = nil }),
            ("ancestor timeout failed", { $0.timeoutFailures = [2] }),
            ("foreign application root", { $0.nodes[3]!.pid = Fixture.pid + 1 }),
        ]
        for (name, mutate) in mutations {
            let native = Native(); native.set(mutate)
            let context = makeContext(native)
            assertDenied(name) { try context.verifyField(Fixture.field) }
        }
    }

    func testParentWalkAcceptsThirtyTwoLevelsAndDeniesDeeperTrees() throws {
        let accepted = Native(); chain(accepted, applicationDepth: 31)
        let acceptedContext = makeContext(accepted)
        try withDeadline { try acceptedContext.verifyField(Fixture.field) }
        let denied = Native(); chain(denied, applicationDepth: 32)
        let deniedContext = makeContext(denied)
        assertDenied("application root beyond 32 levels") { try deniedContext.verifyField(Fixture.field) }
    }

    func testFrontmostApplicationIdentityRegressionsAreDenied() {
        let mutations: [(String, (inout State) -> Void)] = [
            ("accessibility not trusted", { $0.trusted = false }),
            ("process replaced", { $0.presence = [.replaced] }),
            ("process absent", { $0.presence = [.absent] }),
            ("process replaced during digest", { $0.presence = [.matching, .replaced] }),
            ("no running application", { $0.application = nil }),
            ("terminated application", { $0.application = .init(bundleID: "test.Secure", canonicalBundlePath: "/synthetic/Secure.app", isTerminated: true) }),
            ("foreign bundle identifier", { $0.application = .init(bundleID: "test.Other", canonicalBundlePath: "/synthetic/Secure.app", isTerminated: false) }),
            ("foreign bundle path", { $0.application = .init(bundleID: "test.Secure", canonicalBundlePath: "/synthetic/Other.app", isTerminated: false) }),
            ("not frontmost", { $0.frontmost = Fixture.pid + 1 }),
            ("no frontmost application", { $0.frontmost = nil }),
            ("product digest changed", { $0.digest = String(repeating: "c", count: 64) }),
            ("foreign effective owner", { $0.owner = .init(uid: 0, ruid: 501) }),
            ("foreign real owner", { $0.owner = .init(uid: 501, ruid: 0) }),
            ("owner query failed", { $0.owner = nil }),
            ("different current user", { $0.uid = 502 }),
        ]
        for (name, mutate) in mutations {
            let verifying = Native(), resolving = Native()
            verifying.set(mutate); resolving.set(mutate)
            let verifyContext = makeContext(verifying), resolveContext = makeContext(resolving)
            assertDenied(name) { try verifyContext.verify() }
            assertDenied(name) { _ = try resolveContext.resolve() }
            XCTAssertTrue(resolving.get { $0.positions.isEmpty }, name)
        }
        let changedTarget = Native(); changedTarget.set { $0.targetValid = false }
        let changedVerify = makeContext(changedTarget), changedResolve = makeContext(changedTarget)
        XCTAssertThrowsError(try withDeadline { try changedVerify.verify() }) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
        XCTAssertThrowsError(try withDeadline { _ = try changedResolve.resolve() }) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
        XCTAssertTrue(changedTarget.get { $0.positions.isEmpty })
        let missingPath = Native(), missingPathContext = makeContext(missingPath, approval: approval(bundlePath: nil))
        missingPath.set { $0.application = .init(bundleID: "test.Secure", canonicalBundlePath: nil, isTerminated: false) }
        assertDenied("approval without a canonical bundle path") { try missingPathContext.verify() }
    }

    func testCodeSigningIdentityRegressionsAreDenied() throws {
        let mutations: [(String, String?, (inout State) -> Void)] = [
            ("signature validation failed", nil, { $0.uniques = nil }),
            ("running code differs from disk", nil, { $0.uniques = .init(disk: Data([0xab, 0x01]), running: Data([0xab, 0x02])) }),
            ("empty code directory", nil, { $0.uniques = .init(disk: Data(), running: Data()) }),
            ("approved code directory differs", "ab02", { _ in }),
            ("approved code directory case differs", "AB01", { _ in }),
        ]
        for (name, identity, mutate) in mutations {
            let native = Native(); native.set(mutate)
            let context = makeContext(native, approval: approval(codeDirectoryIdentity: identity))
            assertDenied(name) { try context.verify() }
        }
        let pinned = makeContext(Native(), approval: approval(codeDirectoryIdentity: "ab01"))
        try withDeadline { try pinned.verify() }
    }

    func testLeaseLossOrMissingDeadlineDeniesBeforeNativeAccess() {
        let approved = approval(), lost = makeFence(approved), native = Native()
        lost.invalidate()
        let lostContext = makeContext(native, approval: approved, fence: lost)
        assertDenied("lease fence invalidated") { try lostContext.verify() }
        XCTAssertEqual(native.get { $0.nativeCalls }, 1, "Only the GUI target check precedes the lease fence")

        let unbounded = Native(), unboundedContext = makeContext(unbounded)
        do { try unboundedContext.verify(); XCTFail("Verification ran without a native deadline") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
        XCTAssertEqual(unbounded.get { $0.nativeCalls }, 0)
    }

    func testAlreadyExpiredDeadlineDeniesBeforeNativeAccessOrWrite() throws {
        let native = Native(), context = makeContext(native)
        let expired = ContinuousClock.now.advanced(by: .seconds(-1))
        try AutomationNativeSecretDeadline.$value.withValue(expired) {
            XCTAssertThrowsError(try context.verify()) {
                XCTAssertEqual($0 as? AutomationSecretFillSession.Failure, .denied)
            }
            XCTAssertThrowsError(try context.resolve()) {
                XCTAssertEqual($0 as? AutomationSecretFillSession.Failure, .denied)
            }
            XCTAssertThrowsError(try context.replace(Fixture.field, value: sentinel)) {
                XCTAssertEqual($0 as? AutomationSecretFillSession.Failure, .denied)
            }
        }
        XCTAssertEqual(native.get { $0.nativeCalls }, 0)
        XCTAssertTrue(native.get { $0.written.isEmpty })
    }

    func testResolveDeniesMissingElementOrMessagingTimeoutFailure() {
        let mutations: [(String, (inout State) -> Void)] = [
            ("no element at position", { $0.hit = nil }),
            ("application timeout failed", { $0.timeoutFailures = [Fixture.appElement] }),
            ("element timeout failed", { $0.timeoutFailures = [Fixture.field] }),
        ]
        for (name, mutate) in mutations {
            let native = Native(); native.set(mutate)
            let context = makeContext(native)
            assertDenied(name) { _ = try context.resolve() }
        }
    }

    func testReplaceDeniesReResolvedReplacementElement() {
        let native = Native()
        native.set { state in
            state.nodes[5] = state.nodes[Fixture.field]
            state.hit = 5
        }
        let context = makeContext(native)
        assertDenied("replacement element at the same point") { try context.replace(Fixture.field, value: self.sentinel) }
        XCTAssertTrue(native.get { $0.written.isEmpty })
    }

    func testReplaceDeniesLeaseLossBeforeWrite() {
        let approved = approval(), fence = makeFence(approved), native = Native()
        let context = makeContext(native, approval: approved, fence: fence)
        fence.invalidate()
        assertDenied("lease lost") { try context.replace(Fixture.field, value: self.sentinel) }
        XCTAssertTrue(native.get { $0.written.isEmpty })
    }

    func testReplaceDeniesLeaseLossDuringFinalNativeValidationBeforeWrite() {
        let approved = approval(), fence = makeFence(approved), native = Native()
        let context = makeContext(native, approval: approved, fence: fence)
        native.set { state in
            state.onOwnerCheck = { check in
                // The fifth verification finishes the fresh field's ancestry check.
                // Its owner read is the last native call before the pre-write fence.
                if check == 5 { fence.invalidate() }
            }
        }
        XCTAssertTrue(fence.isCurrent)
        assertDenied("lease lost after final native validation") {
            try context.replace(Fixture.field, value: self.sentinel)
        }
        XCTAssertEqual(native.get { $0.ownerChecks }, 5, "Must reach the final native validation")
        XCTAssertEqual(native.get { $0.positions }, [120.5, 64], "Must re-resolve the retained field")
        XCTAssertFalse(fence.isCurrent)
        XCTAssertTrue(native.get { $0.written.isEmpty })
        XCTAssertTrue(native.get { $0.writtenElements.isEmpty })
    }

    func testFailedAXWriteReportsUnresolvedOutcome() {
        let native = Native(); native.set { $0.writeSucceeds = false }
        let context = makeContext(native)
        do { try withDeadline { try context.replace(Fixture.field, value: sentinel) }; XCTFail("Failed write reported success") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .outcomeUnresolved) }
    }

    func testCaptureRejectsInvalidCoordinatesForeignLeaseOrFrontmostProcessBeforeResolution() async {
        let approved = approval()
        for (x, y) in [(Double.nan, 0), (0, .nan), (.infinity, 0), (0, -.infinity), (1_000_000.5, 0), (0, -1_000_000.5)] {
            let native = Native()
            await assertCaptureDenied("coordinates \(x), \(y)") {
                try await Fill.capture(approval: approved, scope: makeScope(), leaseFence: makeFence(approved), x: x, y: y, platform: native.platform)
            }
            XCTAssertEqual(native.get { $0.nativeCalls }, 0)
        }
        let invalidated = makeFence(approved); invalidated.invalidate()
        let leases: [(String, AutomationNativeInputLeaseFence, AutomationScope)] = [
            ("lease generation mismatch", makeFence(approved), makeScope(generation: 2)),
            ("foreign run lease", makeFence(approved, runID: "other-run"), makeScope()),
            ("system control lease", makeFence(approved, control: .system), makeScope()),
            ("invalidated lease", invalidated, makeScope()),
        ]
        for (name, fence, scope) in leases {
            let native = Native()
            await assertCaptureDenied(name) {
                try await Fill.capture(approval: approved, scope: scope, leaseFence: fence, x: 1, y: 1, platform: native.platform)
            }
            XCTAssertEqual(native.get { $0.nativeCalls }, 0, name)
        }
        let processes: [(String, (inout State) -> Void)] = [
            ("no frontmost application", { $0.frontmost = nil }),
            ("frontmost process cannot be inspected", { $0.inspected = nil }),
        ]
        for (name, mutate) in processes {
            let native = Native(); native.set(mutate)
            await assertCaptureDenied(name) {
                try await Fill.capture(approval: approved, scope: makeScope(), leaseFence: makeFence(approved), x: 1, y: 1, platform: native.platform)
            }
            XCTAssertTrue(native.get { $0.positions.isEmpty }, name)
        }
        let insecure = Native(); insecure.set { $0.nodes[Fixture.field]!.subrole = .string("AXSearchField") }
        await assertCaptureDenied("non-secure field at capture") {
            try await Fill.capture(approval: approved, scope: makeScope(), leaseFence: makeFence(approved), x: 1, y: 1, platform: insecure.platform)
        }
    }

    func testCapturedFieldSubmitsOnceThroughRetainedSinkAndRefusesChangedField() async throws {
        let approved = approval(), native = Native()
        let owner = try await Fill.capture(approval: approved, scope: makeScope(), leaseFence: makeFence(approved),
                                           x: 1_000_000, y: -1_000_000, platform: native.platform)
        XCTAssertEqual(native.get { Array($0.positions.prefix(2)) }, [1_000_000, -1_000_000])
        try await owner.validateConsent(owner.review)
        let adapter = await owner.adapter()
        let request = AutomationSecretFillRequest(reference: .init(id: UUID()), scope: owner.review.scope,
                                                  sinkID: owner.review.sinkID, sinkFingerprint: owner.review.sinkFingerprint)
        try await adapter.submit(sentinel, request, approved)
        XCTAssertEqual(native.get { $0.written }, [sentinel])
        XCTAssertEqual(native.get { $0.writtenElements }, [Fixture.field])
        await owner.closeAndDrain()

        let changed = Native()
        let retained = try await Fill.capture(approval: approved, scope: makeScope(), leaseFence: makeFence(approved), x: 1, y: 1, platform: changed.platform)
        changed.set { $0.nodes[Fixture.field]!.enabled = .bool(false) }
        do { try await retained.validateConsent(retained.review); XCTFail("Disabled field kept consent") }
        catch { XCTAssertEqual(error as? AutomationSecretFillSession.Failure, .denied) }
        await retained.closeAndDrain()
    }

    func testLiveProcessAndSigningAdaptersRefuseUnverifiableCode() {
        let live = Fill.Platform<AXUIElement>.live
        XCTAssertEqual(live.processOwner(getpid()), Fill.ProcessOwner(uid: getuid(), ruid: getuid()))
        XCTAssertNil(live.processOwner(-1))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        XCTAssertNil(live.signingUniques(missing, getpid()))
    }

    func testLiveSigningAdapterMatchesOnlyTheRunningApprovedApplication() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_MAC_SECURE_FILL_LIVE_APP"] else {
            throw XCTSkip("Requires INTENTS_MAC_SECURE_FILL_LIVE_APP set to a running, signed application bundle")
        }
        let bundle = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let running = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == bundle
        })
        let live = Fill.Platform<AXUIElement>.live
        XCTAssertEqual(live.application(running.processIdentifier)?.canonicalBundlePath, bundle.path)
        let uniques = try XCTUnwrap(live.signingUniques(bundle, running.processIdentifier))
        XCTAssertFalse(uniques.disk.isEmpty); XCTAssertEqual(uniques.disk, uniques.running)
        if let foreign = live.signingUniques(bundle, getpid()) { XCTAssertNotEqual(foreign.disk, foreign.running) }
    }
}
#endif
