#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Admission and state-latch coverage that never launches a helper or Node.
final class AutomationMacNativeHelperBridgeValidationTests: XCTestCase, @unchecked Sendable {
    private struct Fixture { var bridge: AutomationMacNativeHelperBridge; var request: AutomationJSON; var app: URL
        var leases: AutomationDeviceLeaseManager; var lease: AutomationDeviceLeaseManager.Lease }
    private func fixture(scrollImplemented: Bool = false, beforeAdmission: @escaping @Sendable () async -> Void = {}) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-native-bridge-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), executable = root.appendingPathComponent("never-launched")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Data("synthetic helper bytes; never executed".utf8).write(to: executable)
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let lease = try await leases.acquire(runID: "run", target: TargetIdentity(id: "fixture-mac", kind: .nativeMac, loginSession: "fixture-login"), control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "segment", leaseGeneration: lease.generation)
        let bridge = try AutomationMacNativeHelperBridge(executable: executable, prefix: [], directory: root, bundleID: "example.Target",
            bundlePath: app, scope: scope, lease: lease, leases: leases, authorize: { _ in XCTFail("Authorization reached") },
            didCapture: { _, _ in XCTFail("Helper launched") }, beforeCommandAdmission: beforeAdmission, scrollImplemented: scrollImplemented)
        addTeardownBlock { _ = await bridge.stop() }
        let request: AutomationJSON = .object(["requestId": .string(UUID().uuidString.lowercased()),
            "scope": try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope)),
            "selection": .object(["bundleId": .string("example.Target"), "canonicalBundlePath": .string(app.path)]),
            "action": .object(["kind": .string("acquire")]), "timeoutMs": .number(5000)])
        return .init(bridge: bridge, request: request, app: app, leases: leases, lease: lease)
    }
    private func run(_ f: Fixture, _ change: (inout [String: AutomationJSON]) -> Void = { _ in }) async throws -> AutomationJSON {
        var fields = f.request.object!; change(&fields)
        return try await f.bridge.execute(.object(["authentication": .string(await f.bridge.pipeCapability()), "request": .object(fields)]))
    }
    private func assertRejected(_ f: Fixture, _ label: String, _ change: (inout [String: AutomationJSON]) -> Void) async {
        do { _ = try await run(f, change); XCTFail("Admitted: " + label) } catch {}
    }
    private func assertNoRunner(_ f: Fixture) async throws {
        let record = try await f.leases.currentRecord(f.lease); XCTAssertTrue(record.runners.isEmpty)
        let active = await f.bridge.isInFlight(); XCTAssertFalse(active)
    }

    func testValidateInstanceRequiresExactSelectionAndCanonicalIdentity() throws {
        let selection: AutomationJSON = .object(["bundleId": .string("example.Target"), "canonicalBundlePath": .string("/Applications/Target.app")])
        let valid: [String: AutomationJSON] = ["bundleId": .string("example.Target"), "canonicalBundlePath": .string("/Applications/Target.app"),
                                               "pid": .number(123), "processStartIdentity": .string("100:0")]
        XCTAssertNoThrow(try AutomationMacNativeHelperBridge.validateInstance(.object(valid), selection: selection))
        let changes: [(String, AutomationJSON?)] = [("bundleId", .string("example.Other")), ("canonicalBundlePath", .string("/Applications/Other.app")),
            ("pid", .number(0)), ("pid", .number(1.5)), ("pid", .number(Double(Int32.max) + 1)), ("pid", .string("123")),
            ("processStartIdentity", .string("0:0")), ("processStartIdentity", .string("100:01")), ("processStartIdentity", .string("100:1234567")),
            ("processStartIdentity", .string("100")), ("processStartIdentity", nil), ("extra", .bool(true))]
        for (key, value) in changes {
            var changed = valid; changed[key] = value
            XCTAssertThrowsError(try AutomationMacNativeHelperBridge.validateInstance(.object(changed), selection: selection), key)
        }
        XCTAssertThrowsError(try AutomationMacNativeHelperBridge.validateInstance(.null, selection: selection))
    }
    func testMalformedRequestsAndUnadmittedActionsAreRejectedBeforeLaunch() async throws {
        let f = try await fixture()
        do { _ = try await f.bridge.execute(.object(["authentication": .string("wrong"), "request": f.request])); XCTFail("Wrong authentication") } catch {}
        for timeout in [0, 60_001, 1.5] { await assertRejected(f, "timeout \(timeout)") { $0["timeoutMs"] = .number(timeout) } }
        await assertRejected(f, "uppercase request ID") { $0["requestId"] = .string(UUID().uuidString.uppercased()) }
        await assertRejected(f, "non-UUID request ID") { $0["requestId"] = .string("request") }
        await assertRejected(f, "foreign selection") { $0["selection"] = .object(["bundleId": .string("example.Other"), "canonicalBundlePath": .string(f.app.path)]) }
        await assertRejected(f, "extra field") { $0["extra"] = .null }
        await assertRejected(f, "acquire with extra key") { $0["action"] = .object(["kind": .string("acquire"), "instance": .null]) }
        let instance: AutomationJSON = .object(["bundleId": .string("example.Target"), "canonicalBundlePath": .string(f.app.path),
                                                "pid": .number(123), "processStartIdentity": .string("100:0")])
        await assertRejected(f, "snapshot before acquire") { $0["action"] = .object(["kind": .string("snapshot"), "instance": instance]) }
        await assertRejected(f, "press before acquire") { $0["action"] = .object(["kind": .string("press"), "instance": instance, "x": .number(1), "y": .number(2)]) }
        await assertRejected(f, "unimplemented scroll") { $0["action"] = .object(["kind": .string("scroll"), "instance": instance, "x": .number(1), "y": .number(2), "direction": .string("up")]) }
        await assertRejected(f, "unsupported kind") { $0["action"] = .object(["kind": .string("audio")]) }
        try await assertNoRunner(f)
    }
    func testStopDisablesTheBridgeAndAuthenticatesCleanup() async throws {
        let f = try await fixture()
        let scope = f.request.object!["scope"]!
        do { _ = try await f.bridge.handle(method: "mac.helper.stop", input: .object(["authentication": .string("wrong"), "scope": scope, "applicationTarget": .null]))
            XCTFail("Unauthenticated stop") } catch {}
        let proof = try await f.bridge.handle(method: "mac.helper.stop", input: .object([
            "authentication": .string(await f.bridge.pipeCapability()), "scope": scope, "applicationTarget": .null]))
        XCTAssertEqual(proof.object?["commandsDrained"], .bool(true)); XCTAssertEqual(proof.object?["ownedHelperReaped"], .bool(true))
        await assertRejected(f, "acquire after stop") { _ in }
        try await assertNoRunner(f)
    }
    func testActiveRequestRefusesASecondCommandAndStopPreventsItsLaunch() async throws {
        let gate = BridgeAdmissionGate()
        let f = try await fixture(beforeAdmission: { await gate.wait() })
        let first = Task { try await self.run(f) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        let active = await f.bridge.isInFlight(); XCTAssertTrue(active)
        await assertRejected(f, "concurrent command") { $0["requestId"] = .string(UUID().uuidString.lowercased()) }
        let drained = await f.bridge.stop(); XCTAssertFalse(drained)
        await gate.release()
        do { _ = try await first.value; XCTFail("Stopped command admitted") } catch {}
        let stopped = await f.bridge.stop(); XCTAssertTrue(stopped)
        try await assertNoRunner(f)
    }
}

private actor BridgeAdmissionGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
#endif
