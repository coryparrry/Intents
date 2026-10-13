#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacNativeHelperBridgeTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        var root: URL, marker: URL, bridge: AutomationMacNativeHelperBridge
        var scope: AutomationScope
        var request: AutomationJSON
    }
    private func fixture(mode: String = "valid", scrollImplemented: Bool = false, fillImplemented: Bool = false, authorization: @escaping AutomationMacNativeHelperBridge.Authorize = { _ in }, beforeAdmission: @escaping @Sendable () async -> Void = {}, revalidate: @escaping @Sendable () async throws -> Void = {}) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-native-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), ready = root.appendingPathComponent("ready"), marker = root.appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let script = root.appendingPathComponent("helper.py")
        let source = #"""
        import json, os, sys, time
        from pathlib import Path
        ready_path, mode, bundle_path, marker, *args = sys.argv[1:]
        nonce = os.environ['INTENTS_MAC_HELPER_OWNERSHIP_NONCE']
        while not Path(ready_path).exists():
            time.sleep(0.005)
        ready_text = Path(ready_path).read_text(encoding='utf-8')
        ready = json.loads(ready_text)
        if ready['nonce'] != nonce or ready['identity']['pid'] != os.getpid():
            sys.exit(2)
        if mode == 'delayed-ready':
            Path(ready_path + '.waiting').write_text('', encoding='utf-8')
            while not Path(ready_path + '.resume').exists():
                time.sleep(0.005)
        sys.stdout.write(ready_text)
        sys.stdout.flush()
        lines = sys.stdin.buffer.read().decode('utf-8').rstrip('\n').split('\n')
        ack = json.loads(lines[0])
        if ack['kind'] != 'ack' or ack['nonce'] != nonce or ack['identity']['pid'] != os.getpid():
            sys.exit(3)
        with Path(marker).open('a', encoding='utf-8') as output:
            output.write(args[0] + '\n')
        application_target = {'bundleId': 'example.Target', 'canonicalBundlePath': bundle_path, 'pid': 123, 'processStartIdentity': '100:0'}
        data = application_target
        if args[0] == 'snapshot':
            data = {'applicationTarget': application_target, 'nodes': [], 'surface': 'frontmost-app', 'backend': 'macos-helper', 'truncated': False}
        if args[0] == 'press':
            if mode == 'hang':
                time.sleep(60)
            x, y = float(args[args.index('--x') + 1]), float(args[args.index('--y') + 1])
            data = {'applicationTarget': application_target, 'x': x, 'y': y, 'disposition': 'submittedUnconfirmed', 'releaseSubmitted': mode != 'uncertain'}
        if args[0] == 'owned-scroll':
            x, y = float(args[args.index('--x') + 1]), float(args[args.index('--y') + 1])
            direction = 'up' if mode == 'uncertain-scroll' else args[args.index('--direction') + 1]
            data = {'applicationTarget': application_target, 'x': x, 'y': y, 'direction': direction, 'disposition': 'submittedUnconfirmed'}
        if args[0] == 'owned-fill':
            frame = json.loads(lines[1])
            if len(lines) != 2 or frame['kind'] != 'ordinaryFill' or frame['nonce'] != nonce or any(frame['applicationTarget'].get(key) != application_target[key] for key in ['pid', 'canonicalBundlePath', 'bundleId', 'processStartIdentity']):
                sys.exit(4)
            if any('private-sentinel' in value for value in args) or any('private-sentinel' in value for value in os.environ.values()):
                sys.exit(5)
            if frame['value'] != 'private-sentinel-e\u0301':
                sys.exit(6)
            data = {'applicationTarget': application_target, 'x': 999 if mode == 'uncertain-fill' else frame['x'], 'y': frame['y'], 'disposition': 'replacementVerified'}
        if mode == 'failed-acquire':
            sys.stdout.write(json.dumps({'ok': False, 'error': {'message': 'exact-path launch failed', 'details': {'reason': 'Selected instance unavailable'}}}))
            sys.stdout.flush()
            sys.exit(1)
        sys.stdout.write(json.dumps({'ok': True, 'data': data}))
        sys.stdout.flush()
        """#
        try Data(source.utf8).write(to: script)
        let python = try AutomationSyntheticPython.executable()
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json")), target = TargetIdentity(id: "fixture-mac", kind: .nativeMac, loginSession: "fixture-login")
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "segment", leaseGeneration: lease.generation)
        let bridge = try AutomationMacNativeHelperBridge(executable: python, prefix: [script.path, ready.path, mode, app.path, marker.path],
            directory: root, bundleID: "example.Target", bundlePath: app, scope: scope, lease: lease, leases: leases,
            authorize: { request in try? FileManager.default.removeItem(at: ready); try await authorization(request) }, didCapture: { identity, nonce in
                try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
            }, beforeCommandAdmission: beforeAdmission, revalidate: revalidate, scrollImplemented: scrollImplemented, fillImplemented: fillImplemented)
        addTeardownBlock { _ = await bridge.stop() }
        let request: AutomationJSON = .object(["requestId": .string(UUID().uuidString.lowercased()),
            "scope": try json(scope), "selection": .object(["bundleId": .string("example.Target"), "canonicalBundlePath": .string(app.path)]),
            "action": .object(["kind": .string("acquire")]), "timeoutMs": .number(5000)])
        return Fixture(root: root, marker: marker, bridge: bridge, scope: scope, request: request)
    }
    private func json<T: Encodable>(_ value: T) throws -> AutomationJSON {
        try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value))
    }
    private func execute(_ fixture: Fixture, request: AutomationJSON) async throws -> AutomationJSON {
        try await fixture.bridge.handle(method: "mac.helper.run", input: .object([
            "authentication": .string(await fixture.bridge.pipeCapability()), "request": request]))
    }
    private func call(_ fixture: Fixture, action: AutomationJSON) async throws -> AutomationJSON {
        var fields = try XCTUnwrap(fixture.request.object); fields["action"] = action
        return try await execute(fixture, request: .object(fields))
    }
    private func acquired(_ fixture: Fixture) async throws -> AutomationJSON {
        let reply = try await execute(fixture, request: fixture.request)
        XCTAssertEqual(reply.object?["startupAcknowledged"], .bool(true))
        XCTAssertEqual(reply.object?["directChildReaped"], .bool(true))
        XCTAssertEqual(reply.object?["pipesDrained"], .bool(true))
        XCTAssertEqual(reply.object?["callbacksDrained"], .bool(true))
        let stdout = try XCTUnwrap(reply.object?["stdout"]?.string)
        let envelope = try JSONDecoder().decode(AutomationJSON.self, from: Data(stdout.utf8))
        return try XCTUnwrap(envelope.object?["data"])
    }
    func testAuthenticationScopeAndUnsupportedActionCannotLaunchHelper() async throws {
        let fixture = try await fixture()
        do {
            _ = try await fixture.bridge.execute(.object(["authentication": .string("wrong"), "request": fixture.request]))
            XCTFail("Wrong authentication admitted")
        } catch {}
        for alteration in ["scope", "selection", "action", "extra"] {
            var fields = try XCTUnwrap(fixture.request.object)
            if alteration == "action" { fields[alteration] = .object(["kind": .string("audio")]) }
            else { fields[alteration] = .null }
            do { _ = try await execute(fixture, request: .object(fields)); XCTFail("Unscoped helper admitted") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        _ = try await acquired(fixture)
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\n")
    }
    func testActualSyntheticHelperRequestsCarryCapturedIdentityAndDrain() async throws {
        let fixture = try await fixture(), instance = try await acquired(fixture)
        for kind in ["snapshot", "press"] {
            var request = try XCTUnwrap(fixture.request.object), action: [String: AutomationJSON] = ["kind": .string(kind), "instance": instance]
            request["requestId"] = .string(UUID().uuidString.lowercased())
            if kind == "press" { action["x"] = .number(10); action["y"] = .number(20) }
            request["action"] = .object(action)
            let reply = try await execute(fixture, request: .object(request))
            XCTAssertEqual(reply.object?["startupAcknowledged"], .bool(true))
            guard case .number(let pid) = reply.object?["ownedIdentity"]?.object?["pid"] else { return XCTFail("No helper PID") }
            XCTAssertGreaterThan(pid, 0); XCTAssertNotEqual(pid, 123)
        }
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\nsnapshot\npress\n")
        let result = try await fixture.bridge.handle(method: "mac.helper.stop", input: .object([
            "authentication": .string(await fixture.bridge.pipeCapability()), "scope": try json(fixture.scope), "applicationTarget": instance]))
        XCTAssertEqual(result.object?["commandsDrained"], .bool(true))
        XCTAssertEqual(result.object?["ownedHelperReaped"], .bool(true))
    }
    private func scrollRequest(_ fixture: Fixture, instance: AutomationJSON, direction: String = "down") throws -> AutomationJSON {
        var request = try XCTUnwrap(fixture.request.object)
        request["requestId"] = .string(UUID().uuidString.lowercased())
        request["action"] = .object(["kind": .string("scroll"), "instance": instance, "x": .number(10), "y": .number(20), "direction": .string(direction)])
        return .object(request)
    }
    func testScrollRequiresExplicitSourceCapabilityAndStrictDirectionBeforeLaunch() async throws {
        let old = try await fixture(), oldInstance = try await acquired(old)
        do { _ = try await execute(old, request: scrollRequest(old, instance: oldInstance)); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: old.marker, encoding: .utf8), "app\n")
        let candidate = try await fixture(scrollImplemented: true), instance = try await acquired(candidate)
        do { _ = try await execute(candidate, request: scrollRequest(candidate, instance: instance, direction: "other")); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: candidate.marker, encoding: .utf8), "app\n")
    }
    func testSyntheticOwnedScrollCarriesExactReceiptAndDrainsWithoutConfirmationClaim() async throws {
        let candidate = try await fixture(scrollImplemented: true), instance = try await acquired(candidate)
        let result = try await execute(candidate, request: scrollRequest(candidate, instance: instance))
        let stdout = try XCTUnwrap(result.object?["stdout"]?.string)
        let receipt = try JSONDecoder().decode(AutomationJSON.self, from: Data(stdout.utf8)).object?["data"]
        XCTAssertEqual(receipt?.object?["applicationTarget"], instance)
        XCTAssertEqual(receipt?.object?["direction"], .string("down")); XCTAssertEqual(receipt?.object?["disposition"], .string("submittedUnconfirmed"))
        XCTAssertEqual(result.object?["directChildReaped"], .bool(true)); XCTAssertEqual(result.object?["pipesDrained"], .bool(true))
        XCTAssertEqual(try String(contentsOf: candidate.marker, encoding: .utf8), "app\nowned-scroll\n")
    }
    func testUncertainScrollReceiptPermanentlyPreventsAnotherHelperSubmission() async throws {
        let candidate = try await fixture(mode: "uncertain-scroll", scrollImplemented: true), instance = try await acquired(candidate)
        do { _ = try await execute(candidate, request: scrollRequest(candidate, instance: instance)); XCTFail() } catch {}
        do { _ = try await execute(candidate, request: scrollRequest(candidate, instance: instance)); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: candidate.marker, encoding: .utf8), "app\nowned-scroll\n")
    }
    func testUncertainPressOrTimeoutPermanentlyBlocksAnotherSubmission() async throws {
        for mode in ["uncertain", "hang"] {
            let fixture = try await fixture(mode: mode), instance = try await acquired(fixture)
            var request = try XCTUnwrap(fixture.request.object)
            request["requestId"] = .string(UUID().uuidString.lowercased())
            request["timeoutMs"] = .number(mode == "hang" ? 500 : 5000)
            request["action"] = .object(["kind": .string("press"), "instance": instance, "x": .number(10), "y": .number(20)])
            do { _ = try await execute(fixture, request: .object(request)); XCTFail("Uncertain submission accepted") } catch {}
            do { _ = try await execute(fixture, request: .object(request)); XCTFail("Repeated submission accepted") } catch {}
            XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\npress\n")
            let stopped = await fixture.bridge.stop()
            XCTAssertTrue(stopped)
        }
    }
    func testStopBeforeQueuedCommandAdmissionCannotLaunchOrAcknowledge() async throws {
        let gate = NativeBridgeAuthorizationGate()
        let fixture = try await fixture(beforeAdmission: { await gate.wait() })
        let operation = Task { try await self.execute(fixture, request: fixture.request) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        // Command actor has not received run yet. stopOwned completes with no child.
        let drained = await fixture.bridge.stop()
        XCTAssertFalse(drained) // bridge still owns the suspended request
        await gate.release()
        do { _ = try await operation.value; XCTFail("Stopped queued command admitted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        let stopped = await fixture.bridge.stop(); XCTAssertTrue(stopped)
    }
    private actor AdmissionIdentity {
        var valid = true
        func revoke() { valid = false }
        func validate() throws { guard valid else { throw AutomationContractError.conflictingOperation } }
    }
    func testContextChangeWhileHelperReadinessIsDelayedCannotReceiveAck() async throws {
        let identity = AdmissionIdentity()
        let fixture = try await fixture(mode: "delayed-ready", revalidate: { try await identity.validate() })
        let operation = Task { try await self.execute(fixture, request: fixture.request) }
        let waiting = fixture.root.appendingPathComponent("ready.waiting"), end = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: waiting.path), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.path))
        await identity.revoke(); try Data().write(to: fixture.root.appendingPathComponent("ready.resume"))
        do { _ = try await operation.value; XCTFail("Delayed invalid context acknowledged") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        let stopped = await fixture.bridge.stop(); XCTAssertTrue(stopped)
    }
    func testStopDuringFinalAcknowledgementValidationJoinsItsCallback() async throws {
        let gate = NativeBridgeAuthorizationGate()
        let fixture = try await fixture(revalidate: { await gate.wait() })
        let operation = Task { try await self.execute(fixture, request: fixture.request) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        let stopping = Task { await fixture.bridge.stop() }
        try await Task.sleep(for: .milliseconds(30)); await gate.release()
        do { _ = try await operation.value; XCTFail("Stopped final admission acknowledged") } catch {}
        let stopped = await stopping.value; XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }
    func testChangedSubjectOrSessionAfterChildCaptureCannotReceiveStartupAck() async throws {
        let fixture = try await fixture(revalidate: { throw AutomationContractError.conflictingOperation })
        do { _ = try await execute(fixture, request: fixture.request); XCTFail("Invalidated context acknowledged") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        let stopped = await fixture.bridge.stop(); XCTAssertTrue(stopped)
        do { _ = try await execute(fixture, request: fixture.request); XCTFail("Failed admission retried") } catch {}
    }
    func testStopDuringStartupAuthorizationNeverAcknowledgesHelper() async throws {
        let gate = NativeBridgeAuthorizationGate()
        let fixture = try await fixture(authorization: { _ in await gate.wait() })
        let operation = Task { try await self.execute(fixture, request: fixture.request) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        let stopping = Task { await fixture.bridge.stop() }
        // stop() marks the bridge disabled before awaiting the command's callback drain.
        try await Task.sleep(for: .milliseconds(30))
        await gate.release()
        do { _ = try await operation.value; XCTFail("Stopped startup accepted") } catch {}
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        do { _ = try await execute(fixture, request: fixture.request); XCTFail("Stopped bridge reused") } catch {}
    }
    func testMoreThanSixteenSequentialHelpersDoNotExhaustTheLease() async throws {
        let fixture = try await fixture(), instance = try await acquired(fixture)
        for _ in 0..<17 {
            var request = try XCTUnwrap(fixture.request.object)
            request["requestId"] = .string(UUID().uuidString.lowercased())
            request["action"] = .object(["kind": .string("snapshot"), "instance": instance])
            let reply = try await execute(fixture, request: .object(request))
            XCTAssertEqual(reply.object?["directChildReaped"], .bool(true))
        }
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8).split(separator: "\n").count, 18)
        let stopped = await fixture.bridge.stop(); XCTAssertTrue(stopped)
    }
    func testAvailableFillHelperRequiresItsExactVariantDigestWithoutLaunching() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_MAC_FILL_HELPER"] else { throw XCTSkip("Requires exact private fill helper artifact") }
        let helper = try AutomationPath.canonical(URL(fileURLWithPath: path))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("fill-helper-pin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let target = TargetIdentity(id: "fixture-mac", kind: .nativeMac, loginSession: "fixture-login")
        let lease = try await leases.acquire(runID: "fill-pin", target: target, control: .ui)
        let scope = AutomationScope(runID: "fill-pin", attemptID: "attempt", segmentID: "segment", leaseGeneration: lease.generation)
        do {
            _ = try await AutomationMacNativeHelperBridge(helper: helper, directory: root, bundleID: "example.Target", bundlePath: app,
                scope: scope, lease: lease, leases: leases, authorize: { _ in })
            XCTFail("Default variant accepted fill binary")
        } catch {}
        let bridge = try await AutomationMacNativeHelperBridge(helper: helper, directory: root, bundleID: "example.Target", bundlePath: app,
            scope: scope, lease: lease, leases: leases, authorize: { _ in }, sourceVariant: .boundedFillExperiment)
        let active = await bridge.isInFlight(); XCTAssertFalse(active)
        XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: helper)), AutomationMacNativeHelperBridge.privateFillHelperSHA256)
    }
    func testOrdinaryFillRequiresExplicitCapabilityAndDeliversLiteralOnlyThroughPrivateFrame() async throws {
        let tapOnly = try await fixture(), deniedInstance = try await acquired(tapOnly)
        let action: (AutomationJSON) -> AutomationJSON = { instance in .object(["kind": .string("ordinaryFill"), "instance": instance,
            "x": .number(2), "y": .number(3), "value": .string("private-sentinel-e\u{301}")]) }
        do { _ = try await call(tapOnly, action: action(deniedInstance)); XCTFail("Default fill admitted") } catch {}
        let candidate = try await fixture(fillImplemented: true), instance = try await acquired(candidate)
        let reply = try await call(candidate, action: action(instance))
        XCTAssertEqual(reply.object?["helperABI"], .string("startup-gate-v2-private-input"))
        let encoder = JSONEncoder(); let bytes = try encoder.encode(reply)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-sentinel"))
        let stdout = try XCTUnwrap(reply.object?["stdout"]?.string)
        let envelope = try JSONDecoder().decode(AutomationJSON.self, from: Data(stdout.utf8))
        XCTAssertEqual(envelope.object?["data"]?.object?["disposition"], .string("replacementVerified"))
    }
    func testOrdinaryFillValueBoundsRejectBeforeLaunchAndUncertainReceiptPermanentlyDisablesBridge() async throws {
        let candidate = try await fixture(fillImplemented: true), instance = try await acquired(candidate)
        for value in [String(repeating: "x", count: 16385), "x\0"] {
            do { _ = try await call(candidate, action: .object(["kind": .string("ordinaryFill"), "instance": instance,
                "x": .number(2), "y": .number(3), "value": .string(value)])); XCTFail("Invalid fill admitted") } catch {}
        }
        XCTAssertEqual(try String(contentsOf: candidate.marker, encoding: .utf8), "app\n")
        let uncertain = try await fixture(mode: "uncertain-fill", fillImplemented: true), current = try await acquired(uncertain)
        let action = AutomationJSON.object(["kind": .string("ordinaryFill"), "instance": current,
            "x": .number(2), "y": .number(3), "value": .string("private-sentinel-e\u{301}")])
        do { _ = try await call(uncertain, action: action); XCTFail("Wrong receipt admitted") } catch {}
        do { _ = try await call(uncertain, action: action); XCTFail("Uncertain fill retried") } catch {}
        XCTAssertEqual(try String(contentsOf: uncertain.marker, encoding: .utf8), "app\nowned-fill\n")
    }

}
private actor NativeBridgeAuthorizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
