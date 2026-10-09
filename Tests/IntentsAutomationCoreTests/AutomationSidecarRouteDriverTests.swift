#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSidecarRouteDriverTests: XCTestCase, @unchecked Sendable {
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
    actor Subject: AutomationSubjectVerifier {
        var calls = 0
        var failAfter: Int?
        func verify(app: AppIdentity, target: TargetIdentity) throws {
            calls += 1
            if let failAfter, calls > failAfter { throw AutomationContractError.terminationUnverified }
        }
        func fail(after calls: Int) { failAfter = calls }
    }
    actor Release: AutomationDeviceReleaseVerifier {
        var released = true
        var prepared: (arrived: Gate, resume: Gate)?
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async {
            guard let prepared else { return }
            await prepared.arrived.release(); await prepared.resume.wait()
        }
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) -> Bool { released }
        func deny() { released = false }
        func hold(_ arrived: Gate, _ resume: Gate) { prepared = (arrived, resume) }
    }
    /// Behaviour of the fake sidecar child, fixed when the driver spawns it.
    struct Script: Sendable {
        var receipt: @Sendable ([String: AutomationJSON]) -> AutomationJSON = { Script.receipt($0) }
        var resourcesReleased = true
        var stops = true
        var acquire: (arrived: Gate, resume: Gate)?
        static func receipt(_ payload: [String: AutomationJSON], outputs: [String: AutomationJSON] = ["find": .object(["found": .bool(true)])]) -> AutomationJSON {
            .object(["schemaVersion": .number(1), "scope": payload["scope"] ?? .null, "operationId": payload["operationId"] ?? .null,
                     "complete": .bool(true), "outputs": .object(outputs)])
        }
    }
    actor Sidecar: AutomationSidecarRouteProcess {
        let rpc: AutomationRPC
        private let frames: AsyncStream<Data>
        private let script: Script
        private(set) var methods: [String] = []
        private(set) var params: [String: AutomationJSON] = [:]
        private(set) var stopCount = 0
        init(script: Script, reverse: @escaping AutomationRPC.ReverseHandler) {
            let (frames, sender) = AsyncStream<Data>.makeStream()
            self.frames = frames; self.script = script
            rpc = AutomationRPC(send: { sender.yield($0) }, reverse: reverse)
        }
        var processIdentity: AutomationProcessIdentity? { try? AutomationProcessIdentity.current() }
        func start() {
            let frames = frames
            Task { for await frame in frames { Task { await self.handle(frame) } } }
        }
        func handshake() -> AutomationJSON { .object(["protocolVersion": .number(1)]) }
        func stop() -> Bool { stopCount += 1; return script.stops }
        private func handle(_ frame: Data) async {
            guard let fields = try? JSONDecoder().decode(AutomationJSON.self, from: frame).object,
                  let id = fields["id"]?.string, let method = fields["method"]?.string else { return }
            methods.append(method); params[method] = fields["params"]
            let result: AutomationJSON
            switch method {
            case "ui.acquire":
                if let acquire = script.acquire { await acquire.arrived.release(); await acquire.resume.wait() }
                result = .object(["acquired": .bool(true)])
            case "ui.runSegment": result = script.receipt(fields["params"]?.object ?? [:])
            case "shutdown": result = .object(["resourcesReleased": .bool(script.resourcesReleased)])
            default: result = .null
            }
            let response = try! JSONEncoder().encode(AutomationJSON.object(["jsonrpc": .string("2.0"), "id": .string(id), "result": result]))
            try? await rpc.receive(response + Data([10]))
        }
    }
    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var spawned: [Sidecar] = []
        private(set) var configuredDirectories: [URL] = []
        var sidecars: [Sidecar] { lock.withLock { spawned } }
        var configured: [URL] { lock.withLock { configuredDirectories } }
        func launcher(_ script: Script) -> AutomationSidecarRouteLauncher {
            .init(configure: { [self] _, directory, _, _ in
                lock.withLock { configuredDirectories.append(directory) }
                return .init(node: URL(fileURLWithPath: "/usr/bin/true"), entry: directory.appendingPathComponent("main.js"), stateDirectory: directory)
            }, spawn: { [self] _, reverse in
                let sidecar = Sidecar(script: script, reverse: reverse)
                lock.withLock { spawned.append(sidecar) }
                return sidecar
            })
        }
    }
    struct Harness {
        let root: URL, plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope
        let leases: AutomationDeviceLeaseManager, lease: AutomationDeviceLeaseManager.Lease
        let subject: Subject, release: Release, launches: Launches, artifacts: URL
        let driver: AutomationSidecarRouteDriver
        var sidecar: Sidecar { get throws { try XCTUnwrap(launches.sidecars.first) } }
    }
    static let program = AutomationUIProgram(operations: [
        .init(id: "go", kind: .tap, locator: .init(.label, "Go")),
        .init(id: "find", kind: .locate, locator: .init(.testId, "result"))
    ], timeoutMilliseconds: 1_000)

    func fixture(_ script: Script = .init(), phase: AutomationSegment.Phase = .subject) async throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp/synthetic-sidecar-driver-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios")
        let target = TargetIdentity(id: "owned", kind: .simulator)
        var segment = AutomationSegment(id: "drive", kind: .ui, phase: phase, operation: "Drive", effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = Self.program
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "test", execution: segment)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.navigate, .observe], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(); try await leases.reserveCampaign(runID: "run", target: target)
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: segment.id, leaseGeneration: lease.generation)
        let subject = Subject(), release = Release(), launches = Launches(), artifacts = root.appendingPathComponent("artifacts")
        let driver = try AutomationSidecarRouteDriver(bundleURL: root, expectedTeamID: "3Z3955EFRE", stateDirectory: root.appendingPathComponent("driver"),
            approval: approval, leases: leases, artifacts: AutomationArtifactRegistry(root: artifacts), subjectVerifier: subject, releaseVerifier: release,
            launcher: launches.launcher(script))
        return .init(root: root, plan: plan, segment: segment, scope: scope, leases: leases, lease: lease, subject: subject,
                     release: release, launches: launches, artifacts: artifacts, driver: driver)
    }
    func acquire(_ h: Harness) async throws { try await h.driver.acquire(plan: h.plan, segment: h.segment, scope: h.scope, lease: h.lease) }
    func execute(_ h: Harness) async throws -> AutomationSegmentReceipt {
        try await h.driver.execute(plan: h.plan, segment: h.segment, scope: h.scope, lease: h.lease)
    }
    func release(_ h: Harness) async -> AutomationReleaseProof { await h.driver.release(scope: h.scope, lease: h.lease) }
    func assertThrows(_ expected: AutomationContractError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, expected, file: file, line: line) }
    }

    func testLifecycleAcquiresExecutesAndReleasesOwnedSidecar() async throws {
        let h = try await fixture()
        try await acquire(h)
        let sidecar = try h.sidecar
        XCTAssertEqual(h.launches.configured.map(\.lastPathComponent), ["control-\(h.lease.generation)"])
        let acquireParams = await sidecar.params["ui.acquire"]
        let acquired = try XCTUnwrap(acquireParams?.object)
        XCTAssertEqual(acquired["lifecycle"], .string("persistedStateAcrossSegments"))
        XCTAssertEqual(acquired["target"]?.object?["platform"], .string("ios"))
        XCTAssertEqual(acquired["target"]?.object?["bundleId"], .string("example.Subject"))
        let runners = try await h.leases.currentRecord(h.lease).runners
        XCTAssertEqual(runners.map(\.role), [.sidecar]); XCTAssertEqual(runners.map(\.executablePath), ["/usr/bin/true"])
        await assertThrows(.invalidPlan("No frozen UI program for this route")) { try await self.acquire(h) }

        let receipt = try await execute(h)
        XCTAssertTrue(receipt.dispatched); XCTAssertTrue(receipt.completed)
        XCTAssertEqual(receipt.scope, h.scope); XCTAssertEqual(receipt.route, .ui)
        XCTAssertEqual(receipt.verifiedOutputs, [:]); XCTAssertEqual(receipt.observations, [])
        XCTAssertNotNil(receipt.artifact)
        let runParams = await sidecar.params["ui.runSegment"]
        XCTAssertEqual(runParams?.object?["operationId"], .string("attempt:drive"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.artifacts.appendingPathComponent("ui-\(h.lease.generation).json").path))

        let proof = await release(h)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        let methods = await sidecar.methods, stops = await sidecar.stopCount
        XCTAssertEqual(methods, ["ui.acquire", "ui.runSegment", "shutdown"]); XCTAssertEqual(stops, 1)
        let capture = await h.driver.releasedSetupCapture(scope: h.scope)
        XCTAssertNil(capture)
        // Control is cleared: a repeated release has no sidecar to shut down and the revoked generation cannot be reused.
        let repeated = await release(h)
        XCTAssertTrue(repeated.commandsDrained); XCTAssertTrue(repeated.runnerTerminated)
        let repeatedStops = await sidecar.stopCount
        XCTAssertEqual(repeatedStops, 1)
        await assertThrows(.unknownLease) { _ = try await self.execute(h) }
        await assertThrows(.invalidPlan("No frozen UI program for this route")) { try await self.acquire(h) }
    }

    func testReleaseDuringAcquireThrowsUnknownLeaseWithoutSpawningSidecar() async throws {
        let h = try await fixture(), arrived = Gate(), resume = Gate()
        await h.release.hold(arrived, resume)
        let acquiring = Task { try await self.acquire(h) }
        await arrived.wait()
        let pending = await release(h)
        XCTAssertFalse(pending.commandsDrained); XCTAssertFalse(pending.runnerTerminated)
        await resume.release()
        await assertThrows(.unknownLease) { try await acquiring.value }
        XCTAssertTrue(h.launches.sidecars.isEmpty); XCTAssertTrue(h.launches.configured.isEmpty)
        await assertThrows(.unknownLease) { _ = try await self.execute(h) }
        let settled = await release(h)
        XCTAssertTrue(settled.commandsDrained); XCTAssertTrue(settled.runnerTerminated)
    }

    func testReleaseDuringSidecarAcquireThrowsUnknownLeaseAndStopsSidecar() async throws {
        let arrived = Gate(), resume = Gate()
        let h = try await fixture(.init(acquire: (arrived, resume)))
        let acquiring = Task { try await self.acquire(h) }
        await arrived.wait()
        let releasing = Task { await self.release(h) }
        let sidecar = try h.sidecar
        while await sidecar.stopCount == 0 { await Task.yield() }
        await resume.release()
        await assertThrows(.unknownLease) { try await acquiring.value }
        let proof = await releasing.value
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        let methods = await sidecar.methods
        XCTAssertEqual(methods, ["ui.acquire", "shutdown"])
        await assertThrows(.unknownLease) { _ = try await self.execute(h) }
    }

    func testExistingControlDirectoryIsAmbiguousDispatch() async throws {
        let h = try await fixture()
        try FileManager.default.createDirectory(at: h.root.appendingPathComponent("driver/control-\(h.lease.generation)"), withIntermediateDirectories: true)
        await assertThrows(.ambiguousDispatch) { try await self.acquire(h) }
        XCTAssertTrue(h.launches.configured.isEmpty); XCTAssertTrue(h.launches.sidecars.isEmpty)
        await assertThrows(.unknownLease) { _ = try await self.execute(h) }
    }

    func testAcquireRejectsMismatchedRouteBeforeSpawning() async throws {
        let h = try await fixture()
        var system = h.segment; system.kind = .systemIntent
        var unprogrammed = h.segment; unprogrammed.uiProgram = nil
        var activating = h.segment; activating.lifecycle = .noActivation
        let foreign = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "other", leaseGeneration: h.lease.generation)
        for (segment, scope) in [(system, h.scope), (unprogrammed, h.scope), (activating, h.scope), (h.segment, foreign)] {
            await assertThrows(.invalidPlan("No frozen UI program for this route")) {
                try await h.driver.acquire(plan: h.plan, segment: segment, scope: scope, lease: h.lease)
            }
        }
        XCTAssertTrue(h.launches.sidecars.isEmpty)
        await assertThrows(.unknownLease) { _ = try await self.execute(h) }
    }

    func testExecuteRejectsMalformedReceiptsAsAmbiguousDispatch() async throws {
        let foreignScope = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(
            AutomationScope(runID: "run", attemptID: "foreign", segmentID: "drive", leaseGeneration: 1)))
        let mutations: [(String, @Sendable (inout [String: AutomationJSON]) -> Void)] = [
            ("missing key", { $0["complete"] = nil }),
            ("extra key", { $0["diagnostic"] = .string("extra") }),
            ("schema", { $0["schemaVersion"] = .number(2) }),
            ("foreign scope", { [foreignScope] in $0["scope"] = foreignScope }),
            ("operation", { $0["operationId"] = .string("attempt:other") }),
            ("incomplete", { $0["complete"] = .bool(false) }),
            ("outputs", { $0["outputs"] = .array([]) })
        ]
        for (name, mutate) in mutations {
            let h = try await fixture(.init(receipt: { payload in
                var fields = Script.receipt(payload).object ?? [:]; mutate(&fields); return .object(fields)
            }))
            try await acquire(h)
            do { _ = try await execute(h); XCTFail(name) }
            catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch, name) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.artifacts.appendingPathComponent("ui-\(h.lease.generation).json").path), name)
            let proof = await release(h)
            XCTAssertTrue(proof.runnerTerminated, name)
        }
    }

    func testExecuteRejectsOutputsOutsideProgramScope() async throws {
        for outputs: [String: AutomationJSON] in [
            ["find": .object(["found": .bool(true)]), "extra": .object([:])],
            [:],
            ["go": .object([:])]
        ] {
            let h = try await fixture(.init(receipt: { Script.receipt($0, outputs: outputs) }))
            try await acquire(h)
            await assertThrows(.missingEvidence("UI output scope mismatch")) { _ = try await self.execute(h) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.artifacts.appendingPathComponent("ui-\(h.lease.generation).json").path))
        }
    }

    func testUnprovenShutdownRetainsControl() async throws {
        for script in [Script(resourcesReleased: false), Script(stops: false)] {
            let h = try await fixture(script)
            try await acquire(h)
            _ = try await execute(h)
            let proof = await release(h)
            XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
            // Control is retained, so a retry shuts the same sidecar down again.
            _ = await release(h)
            let sidecar = try h.sidecar
            let stops = await sidecar.stopCount, methods = await sidecar.methods
            XCTAssertEqual(stops, 2); XCTAssertEqual(methods.filter { $0 == "shutdown" }.count, 2)
        }
    }

    func testUnverifiedDeviceReleaseRetainsControl() async throws {
        let h = try await fixture()
        try await acquire(h)
        await h.release.deny()
        let proof = await release(h)
        XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        _ = await release(h)
        let stops = try await h.sidecar.stopCount
        XCTAssertEqual(stops, 2)
    }

    func testUnverifiedSubjectTerminationLatchesUnreleasedProof() async throws {
        let h = try await fixture()
        try await acquire(h)
        let verified = await h.subject.calls
        await h.subject.fail(after: verified)
        await assertThrows(.terminationUnverified) { _ = try await self.execute(h) }
        let methods = try await h.sidecar.methods
        XCTAssertEqual(methods, ["ui.acquire"])
        let proof = await release(h)
        XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        _ = await release(h)
        let stops = try await h.sidecar.stopCount
        XCTAssertEqual(stops, 2)
    }
}
#endif
