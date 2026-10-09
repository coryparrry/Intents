#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPrivateMacAppleRouteDriverTests: XCTestCase, @unchecked Sendable {
    struct Subject: AutomationSubjectVerifier {
        let app: AppIdentity, target: TargetIdentity
        func verify(app: AppIdentity, target: TargetIdentity) async throws {
            guard self.app == app, self.target == target else { throw AutomationContractError.invalidIdentity }
        }
    }
    actor Release: AutomationDeviceReleaseVerifier {
        var calls: [String] = [], accepted = true
        var preparationFailure: AutomationContractError?
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) throws {
            calls.append("prepare:" + controllerBundleIDs.joined(separator: ","))
            if let preparationFailure { throw preparationFailure }
        }
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) -> Bool { calls.append("release:" + controllerBundleIDs.joined(separator: ",")); return accepted }
        func deny() { accepted = false }
        func failPreparation(_ error: AutomationContractError) { preparationFailure = error; accepted = false }
    }
    struct Harness: Sendable {
        let root: URL, host: AutomationPreparedAppleHost, plan: AutomationCase, approval: RunApproval
        let leases: AutomationDeviceLeaseManager, lease: AutomationDeviceLeaseManager.Lease, scope: AutomationScope
        let release: Release
    }
    func fixture() async throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp/private-mac-apple-" + UUID().uuidString)
        let host = root.appendingPathComponent("OwnedHost-Runner.app"), subject = root.appendingPathComponent("Subject.app")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (bundle, id, name) in [(host, "example.Host.xctrunner", "OwnedHost-Runner"), (subject, "example.Subject", "Subject")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleExecutable": name, "CFBundleSupportedPlatforms": ["MacOSX"]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Contents/MacOS/" + name))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents/PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "TestHostPath": "__TESTROOT__/OwnedHost-Runner.app",
                                  "TestBundlePath": "__TESTHOST__/Contents/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app", "IsUITestBundle": true]
        let testFile = root.appendingPathComponent("host.xctestrun"), data = try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry], format: .xml, options: 0)
        try data.write(to: testFile)
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: try AutomationProductDigest.compute(bundle: subject, version: 2))
        app.productDigestVersion = 2; app.canonicalBundlePath = subject.path
        let prepared = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: testFile.path, xctestrunDigest: AutomationArtifactRegistry.digest(data), subjectProductPath: subject.path,
            hostBundlePath: host.path, hostProductDigest: try AutomationProductDigest.compute(bundle: host, version: 2), hostBundleID: "example.Host.xctrunner", testTarget: "OwnedHost", hostProductDigestVersion: 2)
        var segment = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "probe", effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        segment.hostProgram = .init(operations: [.init(id: "probe", kind: .invoke, typeID: "HostProbeIntent", resultCodec: "noValue")])
        let plan = AutomationCase(id: "mac-apple", app: app, target: target, environmentID: "test", execution: segment)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.observe], maximumActions: 10, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        let leases = AutomationDeviceLeaseManager(); try await leases.reserveCampaign(runID: "run", target: target)
        let lease = try await leases.acquire(runID: "run", target: target, control: .system)
        return .init(root: root, host: prepared, plan: plan, approval: approval, leases: leases, lease: lease,
                     scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation), release: Release())
    }
    func driver(_ h: Harness, approval: RunApproval? = nil, host: AutomationPreparedAppleHost? = nil,
                validate: @escaping AutomationMacAssociatedHostReleaseVerifier.TargetValidator = { _ in },
                subject: (any AutomationSubjectVerifier)? = nil, capabilities: CapabilityProfile = .init(), commands: AutomationPrivateMacAppleRouteDriver.Commands? = nil) throws -> AutomationPrivateMacAppleRouteDriver {
        try .init(prepared: host ?? h.host, approval: approval ?? h.approval, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                  stateDirectory: h.root.appendingPathComponent("driver"), leases: h.leases, artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts")),
                  subjectVerifier: subject ?? Subject(app: h.host.app, target: h.host.target), releaseVerifier: h.release, capabilities: capabilities, validateTarget: validate, commands: commands)
    }
    func testAcquireFreezesOnlyTheReviewedProgramAndReleasesWithoutLaunching() async throws {
        let h = try await fixture(), driver = try driver(h)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let file = h.root.appendingPathComponent("driver/system-\(h.lease.generation)/host.xctestrun")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let target = try XCTUnwrap(plist["OwnedHost"] as? [String: Any]), environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(target["TestBundlePath"] as? String, h.host.hostBundlePath + "/Contents/PlugIns/OwnedHost.xctest")
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(environment["INTENTS_AUTOMATION_HOST_PLAN_B64"])))
        let value = try JSONDecoder().decode(AutomationJSON.self, from: payload)
        XCTAssertEqual(value.object?["productDigestVersion"], .number(2)); XCTAssertEqual(value.object?["segmentID"], .string("subject"))
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        XCTAssertTrue(proof.privatePayloadCleaned)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_HOST_PLAN_B64"))
        XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: URL(fileURLWithPath: h.host.xctestrunPath))), h.host.xctestrunDigest)
        let calls = await h.release.calls; XCTAssertEqual(calls, ["prepare:example.Host.xctrunner", "release:example.Host.xctrunner"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("driver/system-\(h.lease.generation)/result.xcresult").path))
    }
    func testChangedPrivatePayloadRetainsOwnershipAndCanOnlyCleanExactRestoredBytes() async throws {
        let h = try await fixture(), driver = try driver(h)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let file = h.root.appendingPathComponent("driver/system-\(h.lease.generation)/host.xctestrun")
        let frozen = try Data(contentsOf: file), changed = Data("unexpected replacement".utf8)
        try changed.write(to: file)
        let denied = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(denied.commandsDrained); XCTAssertTrue(denied.runnerTerminated); XCTAssertFalse(denied.privatePayloadCleaned)
        XCTAssertEqual(try Data(contentsOf: file), changed)
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Uncleaned owner discarded") } catch {}
        try frozen.write(to: file)
        let restored = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(restored.commandsDrained); XCTAssertTrue(restored.runnerTerminated); XCTAssertTrue(restored.privatePayloadCleaned)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_HOST_PLAN_B64"))
    }
    func testChangedReviewEffectsAndCaseCannotReachControllerPreparation() async throws {
        for mode in 0...2 {
            let h = try await fixture(); var approval = h.approval, plan = h.plan
            if mode == 0 { approval.approvedCaseDigest = nil }
            if mode == 1 { approval.effects = [] }
            if mode == 2 { plan.execution.hostProgram?.operations[0].typeID = "ForeignIntent" }
            let driver = try driver(h, approval: approval)
            do { try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease); XCTFail("Changed review admitted") } catch {}
            let calls = await h.release.calls; XCTAssertTrue(calls.isEmpty)
        }
    }
    func testWrongReleaseScopeCannotRevokeTheCurrentLease() async throws {
        let h = try await fixture(), driver = try driver(h); var wrong = h.scope; wrong.runId = "foreign"
        let proof = await driver.release(scope: wrong, lease: h.lease); XCTAssertFalse(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let released = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(released.runnerTerminated)
    }
    func testChangedHostAndStaleGUIFailBeforePreparation() async throws {
        let h = try await fixture(), driver = try driver(h)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: h.host.hostBundlePath).appendingPathComponent("Contents/MacOS/OwnedHost-Runner"))
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Changed host admitted") } catch {}
        let second = try await fixture()
        XCTAssertThrowsError(try self.driver(second, validate: { _ in throw AutomationContractError.conflictingOperation }))
        var ios = second.host; ios.app.platform = "ios"
        XCTAssertThrowsError(try self.driver(second, host: ios))
    }
    func testPublishedPayloadWithFailedAcquisitionCleansBeforeControlExists() async throws {
        let h = try await fixture()
        let commands = AutomationPrivateMacAppleRouteDriver.Commands(run: { _, _, _ in throw AutomationContractError.conflictingOperation }, stop: { true },
            afterPayloadWrite: { throw AutomationContractError.conflictingOperation })
        let driver = try driver(h, commands: commands)
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Fixture must fail after publication") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        let file = h.root.appendingPathComponent("driver/system-\(h.lease.generation)/host.xctestrun")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_HOST_PLAN_B64"))
        let pending = try await h.leases.currentRecord(h.lease); XCTAssertNotNil(pending.privatePayload)
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_HOST_PLAN_B64"))
        let clean = try await h.leases.currentRecord(h.lease); XCTAssertNil(clean.privatePayload)
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testIndependentReleaseDenialWithholdsTheSystemLease() async throws {
        let h = try await fixture(), driver = try driver(h)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); await h.release.deny()
        let file = h.root.appendingPathComponent("driver/system-\(h.lease.generation)/host.xctestrun"), before = try Data(contentsOf: file)
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertFalse(proof.runnerTerminated)
        XCTAssertFalse(proof.privatePayloadCleaned); XCTAssertEqual(try Data(contentsOf: file), before)
        let current = await h.leases.isCurrent(h.lease); XCTAssertTrue(current)
    }
}
#endif
