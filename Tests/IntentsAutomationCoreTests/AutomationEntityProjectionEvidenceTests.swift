#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityProjectionEvidenceTests: XCTestCase {
    private struct Fixture {
        var prepared: AutomationPreparedApplication
        var plan: AutomationCase
        var approval: RunApproval
        var report: AutomationAttemptReport
        var query: AutomationHostProgram.Operation { plan.execution.hostProgram!.operations[0] }
        func issue() throws -> AutomationEntityProjectionEvidence? {
            try .issue(report: report, plan: plan, approval: approval, prepared: prepared)
        }
    }
    private func fixture(completeContext: Bool = true) throws -> Fixture {
        let app = AppIdentity(logicalID: "synthetic", bundleID: "example.Synthetic", platform: "ios", productDigest: String(repeating: "a", count: 64))
        var target = TargetIdentity(id: "synthetic-sim", kind: .simulator)
        if completeContext { target.osBuild = "synthetic-os"; target.toolchain = "synthetic-toolchain" }
        let entity = ApplicationSurfaceCatalog.Entity(typeID: "Entity", title: "Entity", queryIdentifier: "Subject.EntityQuery",
            properties: ["title": "text", "ready": "bool", "sequence": "integer"], propertyTitles: [:])
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [entity])
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "/private/tmp/synthetic.xctestrun",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "/private/tmp/synthetic.app",
            hostBundlePath: "/private/tmp/synthetic-host.app", hostProductDigest: String(repeating: "c", count: 64),
            hostBundleID: "example.SyntheticHost", testTarget: "Host", hostProductDigestVersion: 1)
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "/private/tmp/synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "Host", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64)),
            host: host, catalog: catalog, buildLogPath: "synthetic", buildLogTruncated: false)
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "owned",
            effects: [.observe], maximumActions: 10, disposable: false)
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Synthetic", approval: approval)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let output = AutomationValue.array([.object(["entity": .entity(typeID: "Entity", value: "synthetic-record"),
            "properties": .object(["title": .text("Synthetic"), "ready": .bool(true), "sequence": .integer("9007199254740993")])])])
        let receipt = AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "attempt", segmentID: plan.execution.id, leaseGeneration: 1),
            app: app, target: target, segmentID: plan.execution.id, route: .systemQuery, dispatched: true, completed: true,
            artifact: "synthetic-owned-receipt", verifiedOutputs: ["records": output], environmentID: plan.environmentID)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true,
            observations: [], receipts: [receipt], runID: approval.runID)
        return .init(prepared: prepared, plan: plan, approval: approval,
            report: .init(attemptID: "attempt", result: result, receipts: [receipt], resourcesReleased: true))
    }
    func testTypedQueryIssuesOnlyExactPropertyProjectionRecords() throws {
        let f = try fixture(), proof = try XCTUnwrap(f.issue())
        XCTAssertEqual(proof.entityTypeID, "Entity"); XCTAssertEqual(proof.properties, f.query.properties)
        XCTAssertEqual(proof.recordCount, 1); XCTAssertEqual(proof.sourceAttemptID, "attempt"); XCTAssertEqual(proof.receiptDigest.count, 64)
        let capabilities = try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: f.query)
        XCTAssertEqual(Set(capabilities.records.keys), ["apple.entity.propertyProjection.Entity.title", "apple.entity.propertyProjection.Entity.ready", "apple.entity.propertyProjection.Entity.sequence"])
        XCTAssertTrue(capabilities.records.values.allSatisfy { $0.state == .unknown })
        XCTAssertFalse(capabilities.supports(["apple.codec.text"])); XCTAssertFalse(capabilities.supports(["apple.codec.bool"]))
        var query = f.query; query.properties = ["sequence": "integer"]
        XCTAssertEqual(try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: query).records.count, 1)
    }
    func testProjectionProofCannotAuthorizeIntentInputOrResultConversion() throws {
        let f = try fixture(), proof = try XCTUnwrap(f.issue())
        var capabilities = try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: f.query)
        capabilities.records["apple.intent.invoke"] = .init(state: .available, reason: "Synthetic route", probeVersion: "test", evidence: [])
        var plan = f.plan; plan.execution.kind = .systemIntent
        plan.execution.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", parameters: ["text": .text("Synthetic")], resultCodec: "bool")])
        plan.execution.requiredCapabilities = ["apple.intent.invoke", "apple.codec.text", "apple.codec.bool"]
        var approval = f.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
    }
    func testPlausibleButUnobservedPlatformLabelsCannotPromoteAvailability() throws {
        let f = try fixture(), proof = try XCTUnwrap(f.issue())
        XCTAssertNotNil(f.prepared.host.target.osBuild); XCTAssertNotNil(f.prepared.host.target.toolchain)
        let capabilities = try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: f.query)
        XCTAssertTrue(capabilities.records.values.allSatisfy { $0.state == .unknown })
    }
    func testIncompletePlatformContextRemainsUnknown() throws {
        let f = try fixture(completeContext: false), proof = try XCTUnwrap(f.issue())
        let capabilities = try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: f.query)
        XCTAssertTrue(capabilities.records.values.allSatisfy { $0.state == .unknown })
    }
    func testEmptyAndIdentityOnlyQueriesDoNotProvePropertyConversion() throws {
        var f = try fixture(); f.report.receipts[0].verifiedOutputs = ["records": .array([])]
        XCTAssertNil(try f.issue())
        f = try fixture(); f.plan.execution.hostProgram?.operations[0].properties = nil
        f.approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(f.plan)
        f.report.receipts[0].verifiedOutputs = ["records": .array([.object(["entity": .entity(typeID: "Entity", value: "synthetic-record"), "properties": .object([:])])])]
        XCTAssertNil(try f.issue())
    }
    func testIncompleteForeignMalformedAndCatalogChangedReceiptsNeverIssue() throws {
        for flag in 0..<16 {
            var f = try fixture()
            switch flag {
            case 0: f.report.resourcesReleased = false
            case 1: f.report.result.subjectCompleted = false
            case 2: f.report.result.subjectDispatchUncertain = true
            case 3: f.report.receipts[0].environmentID = nil
            case 4: f.report.receipts[0].scope.runId = "foreign"
            case 5: f.report.receipts[0].scope.attemptId = "foreign"
            case 6: f.report.receipts[0].app.bundleID = "example.Foreign"
            case 7: f.report.receipts[0].target.id = "foreign"
            case 8: f.report.receipts[0].verifiedOutputs = nil
            case 9: f.report.receipts[0].artifact = nil
            case 10: f.report.receipts[0].completed = false
            case 11: f.report.receipts.append(f.report.receipts[0])
            case 12: f.approval.approvedCaseDigest = nil
            case 13: f.prepared.catalog.entities?[0].properties["sequence"] = "text"
            case 14: f.prepared.host.hostProductDigest = "invalid"
            default: f.report.receipts[0].verifiedOutputs = ["records": .array([.object(["entity": .entity(typeID: "Entity", value: "id"),
                "properties": .object(["title": .text("Synthetic"), "ready": .bool(true), "sequence": .text("9007199254740993")])])])]
            }
            XCTAssertThrowsError(try f.issue(), "flag \(flag)")
        }
    }
    func testChangedContextAndUnobservedProjectionCannotReuseProof() throws {
        let f = try fixture(), proof = try XCTUnwrap(f.issue())
        for flag in 0..<7 {
            var prepared = f.prepared
            switch flag {
            case 0: prepared.host.app.productDigest = String(repeating: "f", count: 64)
            case 1: prepared.host.target.osBuild = "other"
            case 2: prepared.host.xctestrunDigest = String(repeating: "f", count: 64)
            case 3: prepared.host.hostProductDigest = String(repeating: "f", count: 64)
            case 4: prepared.generatedHost.templateDigest = String(repeating: "f", count: 64)
            case 5: prepared.source.directories.append("changed")
            default: prepared.catalog.entities?[0].title = "Changed"
            }
            XCTAssertThrowsError(try proof.capabilities(prepared: prepared, environmentID: "owned", query: f.query))
        }
        XCTAssertThrowsError(try proof.capabilities(prepared: f.prepared, environmentID: "foreign", query: f.query))
        var query = f.query; query.typeID = "Other"
        XCTAssertThrowsError(try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: query))
        query = f.query; query.properties = ["unobserved": "bool"]
        XCTAssertThrowsError(try proof.capabilities(prepared: f.prepared, environmentID: "owned", query: query))
    }
}
#endif
