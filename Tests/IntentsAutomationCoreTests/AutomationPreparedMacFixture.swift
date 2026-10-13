#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPreparedMacContractTests {
    struct PreparedMacHarness: Sendable {
        let prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let capabilities: CapabilityProfile, runner: AutomationApplicationRunner
    }

    func preparedMacHarness() throws -> PreparedMacHarness {
        let base = try fixture()
        let source = AutomationSourceManifest(sourceRoot: base.root.path, files: [], directories: [], excludedPaths: [])
        var host = base.host
        host.app.sourceManifestDigest = try source.digest
        host.app.configuration = "Debug"
        host.app.sourceSyntaxIndexDigest = String(repeating: "d", count: 64)
        var catalog = ApplicationSurfaceCatalog(app: host.app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true,
            compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        catalog.sourceGraphDigest = String(repeating: "a", count: 64)
        catalog.sourceSyntaxIndexDigest = host.app.sourceSyntaxIndexDigest
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "synthetic", scheme: "OwnedHost", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "a", count: 64)),
            host: host, catalog: catalog, buildLogPath: "synthetic", buildLogTruncated: false)
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.entity"].map {
            ($0, .init(state: .available, reason: "Synthetic prepared program fixture", probeVersion: "test", evidence: []))
        }))
        var approval = RunApproval(runID: "prepared-fixture", app: host.app, target: host.target,
            environmentID: "selected-mac-session:synthetic-login", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var query = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "TaskQuery",
            requiredCapabilities: ["apple.entity.query"], lifecycle: .persistedStateAcrossSegments)
        query.hostProgram = .init(operations: [.init(id: "record", kind: .query, typeID: "TaskEntity",
            queryText: "Invoice", properties: ["title": "text", "completed": "bool"])])
        var invoke = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete",
            requiredCapabilities: ["apple.intent.invoke", "apple.codec.entity"], effects: [.observe, .fixtureWrite],
            lifecycle: .persistedStateAcrossSegments)
        invoke.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Complete", resultCodec: "noValue")])
        invoke.inputBindings = [.init(producerSegmentID: query.id, outputID: "record", destination: .hostParameter,
            operationID: "invoke", name: "task", uniqueEntity: .init(typeID: "TaskEntity", matchingProperties: ["title": .text("Invoice")]))]
        var plan = AutomationCase(id: "prepared-mac-program", app: host.app, target: host.target,
            environmentID: approval.environmentID, execution: invoke, setup: [query])
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let root = base.root.appendingPathComponent("prepared-contract")
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("preflight"), developerDirectory: base.root)
        return .init(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities, runner: runner)
    }
}
#endif
