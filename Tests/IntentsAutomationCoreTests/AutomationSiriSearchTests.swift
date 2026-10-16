import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriSearchTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (AutomationCase, RunApproval, CapabilityProfile, AutomationPreparedApplication) {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let reset = ApplicationSurfaceCatalog.SystemAction(id: "SetStateIntent", typeName: "SetStateIntent", title: "Set task state",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity"), .init(name: "completed", family: "bool", optional: false)],
            parametersComplete: true, compiled: true, registered: true, executed: false, resultFamily: "noValue")
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [reset], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "physical:disposable-account",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.bool", "apple.codec.entity", "siri.recognizedText.api"].map {
            ($0, CapabilityProfile.Record(state: .available, reason: "synthetic test", probeVersion: "test", evidence: []))
        }))
        let original = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title",
            recordName: "Approved task", stateProperty: "completed", initialState: false, expectedState: true,
            request: "Complete Approved task in Example", approval: approval, capabilities: capabilities)
        let plan = try AutomationSiriResetPlan.restoring(original, catalog: catalog, actionID: reset.id, approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "synthetic",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "synthetic", hostBundlePath: "synthetic",
            hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true), host: host, catalog: catalog,
            buildLogPath: "synthetic", buildLogTruncated: false)
        return (plan, approval, capabilities, prepared)
    }
    func testDecodedReviewedWorkflowRunsWithoutProcessLocalQualification() throws {
        let (plan, approval, capabilities, _) = try fixture()
        let retained = try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(plan))
        XCTAssertNoThrow(try PlanValidator.validate(retained, approval: approval, capabilities: capabilities))
        for key in ["apple.codec.bool", "apple.codec.entity", "siri.recognizedText.api"] {
            var veto = capabilities
            veto.records[key] = .init(state: .unavailable, reason: "Explicit veto", probeVersion: "test", evidence: [])
            XCTAssertThrowsError(try PlanValidator.validate(retained, approval: approval, capabilities: veto))
        }
    }
    func testRestorationCannotSwapEntityOrWidenResetEffectsOrState() throws {
        let (plan, approval, _, _) = try fixture()
        for index in 0..<5 {
            var changed = plan
            switch index {
            case 0: changed.setup[1].effects.insert(.externalWrite)
            case 1: changed.setup[1].hostProgram?.operations[0].parameters["completed"] = .bool(true)
            case 2: changed.setup[1].inputBindings = nil
            case 3: changed.setup[2].inputBindings = nil
            default: changed.setup[0].hostProgram?.operations[0].queryText = "Foreign record"
            }
            XCTAssertThrowsError(try AutomationSiriResetPlan.validateStructure(plan: changed, approval: approval))
        }
    }
}
