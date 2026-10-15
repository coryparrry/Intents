#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalInputAdapterTests: XCTestCase, @unchecked Sendable {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func expire() { lock.withLock { instant = instant.advanced(by: .seconds(1801)) } }
    }
    private func fixture() throws -> (AutomationPhysicalInputAdapterPlan, AutomationCase, RunApproval, CapabilityProfile) {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        var target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical); target.osBuild = "24B5028f"
        let action = ApplicationSurfaceCatalog.SystemAction(id: "SetStateIntent", typeName: "SetStateIntent", title: "Set task state",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity"), .init(name: "completed", family: "bool", optional: false)],
            parametersComplete: true, compiled: true, registered: true, executed: false, resultFamily: "noValue")
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false,
            gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "siri.recognizedText.api", "apple.intent.invoke"].map {
            ($0, CapabilityProfile.Record(state: .available, reason: "synthetic test", probeVersion: "test", evidence: []))
        }))
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "disposable-account-A", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let baseline = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title", recordName: "Approved task",
            stateProperty: "completed", initialState: false, expectedState: true, request: "Complete Approved task", approval: approval, capabilities: capabilities)
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "/synthetic/run.xctestrun", xctestrunDigest: String(repeating: "b", count: 64),
            subjectProductPath: "/synthetic/Subject.app", hostBundlePath: "/synthetic/Owned-Runner.app", hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Owned")
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "/synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "/synthetic", scheme: "Owned", targetID: "HOST", bundleID: host.hostBundleID, configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true),
            host: host, catalog: catalog, buildLogPath: "/synthetic/build.log", buildLogTruncated: false)
        let plan = try AutomationPhysicalInputAdapterPlan(prepared: prepared, baseline: baseline, actionID: action.id, entityID: "real-query-id", sdkBuild: "24A430", xcodeBuild: "27A266a", runnerExecutable: "Owned-Runner")
        let repeatable = try AutomationSiriRepeatableQualification.restoring(baseline, catalog: catalog, actionID: action.id, approval: approval, capabilities: capabilities)
        return (plan, repeatable, approval, capabilities)
    }
    private let scope = AutomationScope(runID: "run", attemptID: "probe", segmentID: "input-adapter", leaseGeneration: 3)
    private func receipt(_ plan: AutomationPhysicalInputAdapterPlan) throws -> [String: AutomationJSON] {
        var fields = try XCTUnwrap(try JSONDecoder().decode(AutomationJSON.self, from: plan.payload(scope: scope)).object)
        fields["runner"] = .object(["pid": .number(42), "startIdentity": .string("1:2"), "executablePath": .string("/private/var/containers/Bundle/Application/00000000-0000-0000-0000-000000000001/Owned-Runner.app/Owned-Runner")])
        fields["osBuild"] = .string("24B5028f"); fields["complete"] = .bool(true)
        fields["echoedEntityID"] = .string(plan.entityID); fields["echoedEntityType"] = .string(plan.entityType)
        fields["echoedBooleans"] = .array([.bool(false), .bool(true)])
        return fields
    }
    private func read(_ fields: [String: AutomationJSON], _ plan: AutomationPhysicalInputAdapterPlan) throws -> AutomationPhysicalInputAdapterObservation {
        try .read(JSONEncoder().encode(AutomationJSON.object(fields)), plan: plan, scope: scope)
    }
    func testExactReadOnlyReceiptBindsScopeTargetMembersLiveIDSDKAndOS() throws {
        let (plan, _, _, _) = try fixture()
        let original = try receipt(plan); XCTAssertEqual(try read(original, plan).osBuild, "24B5028f")
        for key in ["runID", "targetID", "environmentID", "entityMember", "boolMember", "entityType", "entityID", "sdkBuild", "xcodeBuild", "hostProductDigest", "osBuild", "echoedEntityID", "echoedEntityType"] {
            var fields = original; fields[key] = .string("foreign")
            XCTAssertThrowsError(try read(fields, plan), key)
        }
        var fields = original; fields["perform"] = .bool(true); XCTAssertThrowsError(try read(fields, plan))
        fields = original; fields["echoedBooleans"] = .array([.bool(false), .bool(false)]); XCTAssertThrowsError(try read(fields, plan))
        fields = original; fields["runner"] = .object(["pid": .number(42), "startIdentity": .string("1:2"), "executablePath": .string("/foreign")]); XCTAssertThrowsError(try read(fields, plan))
    }
    func testImportedCapabilitiesAndUnreleasedReadbackCannotAuthorizeReset() async throws {
        let (plan, repeatable, _, _) = try fixture()
        let registry = AutomationPhysicalInputAdapterAuthority()
        let observation = try read(receipt(plan), plan)
        var imported = CapabilityProfile()
        for key in ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"] {
            imported.records[key] = .init(state: .available, reason: "imported claim", probeVersion: "foreign", evidence: [observation.receiptDigest])
        }
        let restored = try JSONDecoder().decode(CapabilityProfile.self, from: JSONEncoder().encode(imported))
        let absent = await registry.applying(prepared: plan.prepared, plan: repeatable, capabilities: restored)
        XCTAssertFalse(absent.supports(["apple.codec.bool", "apple.codec.entity"]))
        do { try await registry.record(plan: plan, observation: observation, released: false); XCTFail("Unreleased readback") } catch {}
        var reset = repeatable.setup[1]; reset.hostProgram?.operations[0].parameters["task"] = .entity(typeID: "TaskEntity", value: plan.entityID)
        do { _ = try await registry.validateReset(host: plan.prepared.host, plan: repeatable, segment: reset); XCTFail("Imported data cannot mint authority") } catch {}
    }
    func testLiveAuthorityChecksActualResolvedEntityIDVetoScopeAndExpiry() async throws {
        let (plan, repeatable, _, _) = try fixture()
        let clock = Clock(), registry = AutomationPhysicalInputAdapterAuthority(now: { clock.now() })
        try await registry.record(plan: plan, observation: read(receipt(plan), plan), released: true)
        let available = await registry.applying(prepared: plan.prepared, plan: repeatable, capabilities: .init())
        XCTAssertTrue(available.supports(["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"]))
        var reset = repeatable.setup[1]; reset.hostProgram?.operations[0].parameters["task"] = .entity(typeID: "TaskEntity", value: plan.entityID)
        let os = try await registry.validateReset(host: plan.prepared.host, plan: repeatable, segment: reset); XCTAssertEqual(os, "24B5028f")
        reset.hostProgram?.operations[0].parameters["task"] = .entity(typeID: "TaskEntity", value: "replacement-with-same-name")
        do { _ = try await registry.validateReset(host: plan.prepared.host, plan: repeatable, segment: reset); XCTFail("Foreign live ID") } catch {}
        var foreign = repeatable; foreign.environmentID = "account-B"
        let scoped = await registry.applying(prepared: plan.prepared, plan: foreign, capabilities: available); XCTAssertFalse(scoped.supports(["apple.codec.entity"]))
        for state in [CapabilityProfile.State.unavailable, .consentRequired] {
            var veto = available; veto.records["apple.codec.bool"]?.state = state
            let checked = await registry.applying(prepared: plan.prepared, plan: repeatable, capabilities: veto)
            XCTAssertEqual(checked.records["apple.codec.bool"]?.state, state)
        }
        reset.hostProgram?.operations[0].parameters["task"] = .entity(typeID: "TaskEntity", value: plan.entityID)
        clock.expire()
        let expired = await registry.applying(prepared: plan.prepared, plan: repeatable, capabilities: available); XCTAssertFalse(expired.supports(["apple.codec.bool"]))
        do { _ = try await registry.validateReset(host: plan.prepared.host, plan: repeatable, segment: reset); XCTFail("Expired authority") } catch {}
    }
}
#endif
