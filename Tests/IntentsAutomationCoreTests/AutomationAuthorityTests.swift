import XCTest
@testable import IntentsAutomationCore

final class AutomationAuthorityTests: XCTestCase, @unchecked Sendable {
    func testObserveOnlyAndNoActivationCannotGrantFilling() async throws {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios"), target = TargetIdentity(id: "device", kind: .simulator)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.observe], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let authority = AutomationRunAuthority(approval: approval, leases: leases)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        do { try await authority.approve(scope: scope, lease: lease, segment: .init(id: "setup", kind: .ui, phase: .setup, operation: "fill"), actions: [.activate, .fill("mutation")]); XCTFail("Observe-only cannot mutate") }
        catch {}
    }
    func testMacActivationChecksChosenCopySessionAndFrozenActionOrder() async throws {
        var app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "macos"); app.canonicalBundlePath = "/Applications/Chosen.app"
        let target = TargetIdentity(id: "mac", kind: .nativeMac, loginSession: "login")
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.navigate, .fixtureWrite], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let authority = AutomationRunAuthority(approval: approval, leases: leases)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        try await authority.approve(scope: scope, lease: lease, segment: .init(id: "setup", kind: .ui, phase: .setup, operation: "fill", effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments), actions: [.activate, .fill("approved")])
        var fields: [String: AutomationJSON] = ["protocolVersion": .number(1), "runId": .string("run"), "attemptId": .string("attempt"), "segmentId": .string("setup"), "leaseGeneration": .number(Double(lease.generation)), "effect": .string("activate")]
        var selection: [String: AutomationJSON] = ["id": .string("mac"), "platform": .string("macos"), "kind": .string("nativeMac"), "bundleId": .string("example.App"), "bundlePath": .string("/Applications/Other.app"), "loginSession": .string("login")]
        fields["target"] = .object(selection)
        let wrongCopy = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(wrongCopy, .object(["allowed": .bool(false), "reason": .string("actionShape")]))
        selection["bundlePath"] = .string("/Applications/Chosen.app"); selection["loginSession"] = .string("other")
        fields["target"] = .object(selection)
        let wrongSession = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(wrongSession, .object(["allowed": .bool(false), "reason": .string("actionShape")]))
        selection["loginSession"] = .string("login"); fields["target"] = .object(selection)
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(allowed, .object(["allowed": .bool(true)]))
        fields.removeValue(forKey: "target"); fields.removeValue(forKey: "effect")
        fields["action"] = .object(["kind": .string("fill"), "value": .string("different"), "sensitive": .bool(false)])
        let changedBinding = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(changedBinding, .object(["allowed": .bool(false), "reason": .string("actionMismatch")]))
        fields["action"] = .object(["kind": .string("fill"), "value": .string("approved"), "sensitive": .bool(false)])
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        let stale = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(stale, .object(["allowed": .bool(false), "reason": .string("scopeLease")]))
    }
    func testPublicReplacementRejectsCanonicalEquivalentButDifferentCodeUnits() async throws {
        var app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "macos"); app.canonicalBundlePath = "/Applications/Chosen.app"
        let target = TargetIdentity(id: "mac", kind: .nativeMac, loginSession: "login")
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.navigate, .fixtureWrite], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let authority = AutomationRunAuthority(approval: approval, leases: leases)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        try await authority.approve(scope: scope, lease: lease, segment: .init(id: "setup", kind: .ui, phase: .setup, operation: "fill", effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments), actions: [.activate, .fill("e\u{0301}🙂")])
        var fields: [String: AutomationJSON] = ["protocolVersion": .number(1), "runId": .string("run"), "attemptId": .string("attempt"), "segmentId": .string("setup"), "leaseGeneration": .number(Double(lease.generation)), "effect": .string("activate")]
        fields["target"] = .object(["id": .string("mac"), "platform": .string("macos"), "kind": .string("nativeMac"), "bundleId": .string("example.App"), "bundlePath": .string("/Applications/Chosen.app"), "loginSession": .string("login")])
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(allowed, .object(["allowed": .bool(true)]))
        fields.removeValue(forKey: "target"); fields.removeValue(forKey: "effect")
        fields["action"] = .object(["kind": .string("fill"), "value": .string("é🙂"), "sensitive": .bool(false)])
        let changedBinding = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(changedBinding, .object(["allowed": .bool(false), "reason": .string("actionMismatch")]))
        fields["action"] = .object(["kind": .string("fill"), "value": .string("e\u{0301}🙂"), "sensitive": .bool(false)])
        let exact = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(exact, .object(["allowed": .bool(true)]))
        let replay = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(replay, .object(["allowed": .bool(false), "reason": .string("scopeEnvelope")]))
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        let stale = await authority.review(method: "policy.reviewAction", params: .object(fields)); XCTAssertEqual(stale, .object(["allowed": .bool(false), "reason": .string("scopeEnvelope")]))
    }
    func testArtifactRegistryRejectsTraversalForeignScopeSymlinksAndChangedBytes() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try AutomationArtifactRegistry(root: root)
        let file = root.appendingPathComponent("receipt.json"); try Data("{}".utf8).write(to: file)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 1)
        let artifact = try await registry.register(relativePath: "receipt.json", scope: scope)
        let resolved = try await registry.resolve(handle: artifact.handle, scope: scope); XCTAssertEqual(resolved, try AutomationPath.canonical(file))
        let foreign = AutomationScope(runID: "other", attemptID: "attempt", segmentID: "observe", leaseGeneration: 1)
        do { _ = try await registry.resolve(handle: artifact.handle, scope: foreign); XCTFail() } catch {}
        do { _ = try await registry.register(relativePath: "../receipt.json", scope: scope); XCTFail() } catch {}
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.json"), withDestinationURL: file)
        do { _ = try await registry.register(relativePath: "alias.json", scope: scope); XCTFail() } catch {}
        try Data("changed".utf8).write(to: file)
        do { _ = try await registry.resolve(handle: artifact.handle, scope: scope); XCTFail() } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
    }
}
