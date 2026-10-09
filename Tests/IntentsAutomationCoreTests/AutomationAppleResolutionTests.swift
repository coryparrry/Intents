#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSegmentResolutionAuthorityTests: XCTestCase {
    func testResolvedAuthorityBindsExactBytesPlanAndAttempt() throws {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        var segment = AutomationSegment(id: "subject", kind: .systemQuery, phase: .subject, operation: "Find", effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        segment.hostProgram = .init(operations: [.init(id: "find", kind: .query, typeID: "Entity", attemptQueryPrefix: "e\u{301}")])
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "test", execution: segment)
        let resolved = try AutomationInputResolver.resolveForExecution(segment: segment, receipts: [], plan: plan, runID: "run", attemptID: "attempt")
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1)
        XCTAssertTrue(try resolved.authority.matches(plan: plan, segment: resolved.segment, scope: scope))
        let normalized = resolved.segment.hostProgram?.operations[0].queryText?.precomposedStringWithCanonicalMapping
        var changed = resolved.segment; changed.hostProgram?.operations[0].queryText = normalized
        XCTAssertEqual(changed, resolved.segment)
        XCTAssertFalse(try resolved.authority.matches(plan: plan, segment: changed, scope: scope))
        var wrong = scope; wrong.attemptId = "foreign"
        XCTAssertFalse(try resolved.authority.matches(plan: plan, segment: resolved.segment, scope: wrong))
        var other = plan; other.environmentID = "foreign"
        XCTAssertFalse(try resolved.authority.matches(plan: other, segment: resolved.segment, scope: scope))
        var detached = segment; detached.hostProgram?.operations[0].attemptQueryPrefix = "\u{e9}"
        XCTAssertThrowsError(try AutomationInputResolver.resolveForExecution(segment: detached, receipts: [], plan: plan, runID: "run", attemptID: "attempt"))
    }
}

/// Executes the actual coordinator and Apple driver actors; only Xcode/attachment commands are synthetic.
actor AutomationResolutionCommands {
    let host: AutomationPreparedAppleHost
    var payloads: [[String: AutomationJSON]] = []
    init(host: AutomationPreparedAppleHost) { self.host = host }
    func run(_ args: [String], root: URL, timeout: Duration) throws -> AutomationOwnedCommand.Result {
        if args[0] == "xcodebuild" {
            let file = URL(fileURLWithPath: args[try XCTUnwrap(args.firstIndex(of: "-xctestrun")) + 1])
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            let entry = try XCTUnwrap(plist[host.testTarget] as? [String: Any])
            let env = try XCTUnwrap(entry["EnvironmentVariables"] as? [String: String])
            let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(env["INTENTS_AUTOMATION_HOST_PLAN_B64"])))
            payloads.append(try XCTUnwrap(JSONDecoder().decode(AutomationJSON.self, from: payload).object))
        } else {
            let payload = try XCTUnwrap(payloads.last)
            guard case .array(let operations) = payload["operations"] else { throw AutomationContractError.invalidIdentity }
            let results = try operations.map { operation -> AutomationJSON in
                let op = try XCTUnwrap(operation.object)
                let value: AutomationJSON
                if op["kind"] == .string("query") { value = .object(["kind": .string("array"), "items": .array([])]) }
                else if op["resultCodec"] == .string("text") { value = .object(["kind": .string("text"), "value": .string("observed-e\u{301}")]) }
                else { value = .object(["kind": .string("noValue")]) }
                return .object(["operationID": try XCTUnwrap(op["id"]), "dispatched": .bool(true), "value": value])
            }
            var receipt = payload.filter { ["runID", "attemptID", "segmentID", "leaseGeneration", "bundleID", "productDigest", "productDigestVersion"].contains($0.key) }
            receipt["schemaVersion"] = .number(2); receipt["complete"] = .bool(true); receipt["operations"] = .array(results)
            let executable = host.hostBundlePath + (host.target.kind == .nativeMac ? "/Contents/MacOS/" : "/") + "OwnedHost-Runner"
            receipt["runner"] = .object(["pid": .number(Double(Int32.max)), "startIdentity": .string("100:0"), "executablePath": .string(executable)])
            let output = URL(fileURLWithPath: args[try XCTUnwrap(args.firstIndex(of: "--output-path")) + 1])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONEncoder().encode(AutomationJSON.object(receipt)).write(to: output.appendingPathComponent("receipt.json"))
        }
        return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
    }
    func stop() -> Bool { true }
}

private func boundPlan(_ original: AutomationCase, query: Bool) -> AutomationCase {
    var plan = original
    if query {
        var fixture = AutomationSegment(id: "fixture", kind: .ui, phase: .setup, operation: "Create", effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        fixture.uiProgram = .init(operations: [.init(id: "name", kind: .fillBinding, locator: .init(.label, "Name"), binding: "name")])
        fixture.attemptTextBindings = ["name": "fixture"]
        plan.setup = [fixture]
        plan.execution.kind = .systemQuery
        plan.execution.hostProgram = .init(operations: [.init(id: "query", kind: .query, typeID: "HostEntity", attemptQueryPrefix: "fixture")])
    } else {
        var producer = plan.execution; producer.id = "producer"; producer.phase = .setup
        producer.hostProgram?.operations[0].resultCodec = "text"
        plan.setup = [producer]
        plan.execution.inputBindings = [.init(producerSegmentID: "producer", outputID: "probe", destination: .hostParameter, operationID: "probe", name: "input")]
    }
    return AutomationCodecRequirements.applying(to: plan,
        catalog: .init(app: plan.app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []))
}

private let resolutionCodecs = CapabilityProfile(records: ["apple.codec.text": .init(state: .available,
    reason: "Synthetic text result/binding fixture", probeVersion: "test", evidence: [])])

private actor AutomationResolutionUIFixtureDriver: AutomationRouteDriver {
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) throws {
        guard lease.control == .ui, segment.uiProgram?.bindings["name"] == (try AutomationAttemptText.value(prefix: "fixture", attemptID: scope.attemptId)) else {
            throw AutomationContractError.conflictingOperation
        }
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true, observations: [])
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof {
        .init(commandsDrained: true, runnerTerminated: true)
    }
}

private func checkResolution(report: AutomationAttemptReport, commands: AutomationResolutionCommands, query: Bool) async throws {
    XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted, "\(report.result)")
    let payloads = await commands.payloads
    XCTAssertEqual(payloads.count, query ? 1 : 2)
    guard case .array(let operations) = try XCTUnwrap(payloads.last?["operations"]) else { return XCTFail("No operations") }
    let op = try XCTUnwrap(operations.first?.object)
    if query { XCTAssertEqual(op["queryText"], .string(try AutomationAttemptText.value(prefix: "fixture", attemptID: "attempt"))) }
    else {
        let input = try XCTUnwrap(op["parameters"]?.object?["input"]?.object?["value"])
        guard case .string(let text) = input else { return XCTFail("Missing bound text") }
        XCTAssertEqual(Array(text.utf16), Array("observed-e\u{301}".utf16))
    }
}

extension AutomationAppleRouteDriverTests {
    func testUnresolvedBoundTemplateCannotAcquireWithoutProducerAuthority() async throws {
        let h = try await fixture(), plan = boundPlan(h.plan, query: false)
        var approval = h.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = try driver(h, approval: approval)
        do { try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease); XCTFail("Unresolved bound template acquired without producer evidence") }
        catch let error as AutomationContractError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected rejection: \(error)") }
        }
        let calls = await h.release.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testCoordinatorPassesBoundInputsAndAttemptQueriesToRealSimulatorDriver() async throws {
        for query in [false, true] {
            let h = try await fixture(), plan = boundPlan(h.plan, query: query), commands = AutomationResolutionCommands(host: h.host)
            var approval = h.approval; approval.effects.formUnion([.navigate, .fixtureWrite]); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            let leases = AutomationDeviceLeaseManager()
            let driver = try AutomationAppleRouteDriver(prepared: h.host, approval: approval, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                stateDirectory: h.root.appendingPathComponent("integration"), leases: leases, artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("integration-artifacts")),
                subjectVerifier: Subject(app: h.host.app, target: h.host.target), releaseVerifier: h.release, capabilities: resolutionCodecs,
                commands: .init(run: { try await commands.run($0, root: $1, timeout: $2) }, stop: { await commands.stop() }))
            let coordinator = AutomationCoordinator(leases: leases, journal: try AutomationJournal(url: h.root.appendingPathComponent("integration-journal.json")))
            let report = try await coordinator.run(plan: plan, approval: approval, capabilities: resolutionCodecs, attemptID: "attempt", driver: AutomationMixedRouteDriver(ui: AutomationResolutionUIFixtureDriver(), apple: driver))
            try await checkResolution(report: report, commands: commands, query: query)
        }
    }
}

extension AutomationPrivateMacAppleRouteDriverTests {
    func testUnresolvedBoundTemplateCannotAcquireWithoutProducerAuthority() async throws {
        let h = try await fixture(), plan = boundPlan(h.plan, query: false)
        var approval = h.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = try driver(h, approval: approval)
        do { try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease); XCTFail("Unresolved bound template acquired without producer evidence") }
        catch let error as AutomationContractError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected rejection: \(error)") }
        }
        let calls = await h.release.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testCoordinatorPassesBoundInputsAndAttemptQueriesThroughMixedMacRoute() async throws {
        for query in [false, true] {
            let h = try await fixture(), plan = boundPlan(h.plan, query: query), commands = AutomationResolutionCommands(host: h.host)
            var approval = h.approval; approval.effects.formUnion([.navigate, .fixtureWrite]); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            let leases = AutomationDeviceLeaseManager()
            let driver = try AutomationPrivateMacAppleRouteDriver(prepared: h.host, approval: approval, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                stateDirectory: h.root.appendingPathComponent("integration"), leases: leases, artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("integration-artifacts")),
                subjectVerifier: Subject(app: h.host.app, target: h.host.target), releaseVerifier: h.release, capabilities: resolutionCodecs, validateTarget: { _ in },
                commands: .init(run: { try await commands.run($0, root: $1, timeout: $2) }, stop: { await commands.stop() }))
            let coordinator = AutomationCoordinator(leases: leases, journal: try AutomationJournal(url: h.root.appendingPathComponent("integration-journal.json")))
            let report = try await coordinator.run(plan: plan, approval: approval, capabilities: resolutionCodecs, attemptID: "attempt", driver: AutomationMixedRouteDriver(ui: AutomationResolutionUIFixtureDriver(), apple: driver))
            try await checkResolution(report: report, commands: commands, query: query)
        }
    }
}
#endif
