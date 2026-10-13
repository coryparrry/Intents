#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    /// Synthetic saved-review evidence with actual bundle and xctestrun artifacts.
    /// It exercises the coordinator's receipt contract without any Mac UI runtime.
    struct PreparedMacSavedHarness: Sendable {
        let prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let capabilities: CapabilityProfile, coordinator: AutomationCoordinator, runner: AutomationApplicationRunner, driver: FreshRecordPlanDriver
        let root: URL
    }

    func preparedMacSavedHarness(mode: FreshRecordPlanDriver.Mode = .normal, changedBuild: Bool = false) async throws -> PreparedMacSavedHarness {
        let base = try await fixture()
        let source = AutomationSourceManifest(sourceRoot: base.root.path, files: [], directories: [], excludedPaths: [])
        var host = base.host
        host.app.sourceManifestDigest = try source.digest
        host.app.configuration = "Debug"
        host.app.sourceSyntaxIndexDigest = String(repeating: changedBuild ? "e" : "d", count: 64)
        if changedBuild {
            let executable = URL(fileURLWithPath: host.subjectProductPath).appendingPathComponent("Contents/MacOS/Subject")
            var bytes = try Data(contentsOf: executable); bytes.append(1); try bytes.write(to: executable)
            host.app.productDigest = try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: host.subjectProductPath), version: 2)
            let bundle = URL(fileURLWithPath: host.hostBundlePath)
            let hostExecutable = bundle.appendingPathComponent("Contents/MacOS/OwnedHost-Runner")
            var hostBytes = try Data(contentsOf: hostExecutable); hostBytes.append(1); try hostBytes.write(to: hostExecutable)
            host.hostProductDigest = try AutomationProductDigest.compute(bundle: bundle, version: 2)
            let test = URL(fileURLWithPath: host.xctestrunPath)
            var testBytes = try Data(contentsOf: test); testBytes.append(0x0a); try testBytes.write(to: test)
            host.xctestrunDigest = AutomationArtifactRegistry.digest(testBytes)
        }
        var catalog = ApplicationSurfaceCatalog(app: host.app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true,
            compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        catalog.sourceGraphDigest = String(repeating: changedBuild ? "b" : "a", count: 64)
        catalog.sourceSyntaxIndexDigest = host.app.sourceSyntaxIndexDigest
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "synthetic", scheme: "OwnedHost", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "a", count: 64)),
            host: host, catalog: catalog, buildLogPath: "synthetic", buildLogTruncated: false)
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.entity"].map {
            ($0, .init(state: .available, reason: "Synthetic saved-review receipt fixture", probeVersion: "test", evidence: []))
        }))
        var approval = RunApproval(runID: "saved-fixture", app: host.app, target: host.target,
            environmentID: "selected-mac-session:synthetic-login", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var plan = try AutomationFreshEntityPlanner.compile(catalog: catalog, actionID: "Complete",
            instruction: "Create using approvedText", endpoint: "Tasks", namePrefix: "Invoice", nameProperty: "title", stateProperty: "completed",
            initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: "en_GB", purpose: .nativeMacDraft,
            saveControl: .init(.testId, "task.add"), nameEntry: .init(.testId, "task.title"))
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let root = base.root.appendingPathComponent("saved-contract")
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("preflight"), developerDirectory: base.root)
        return .init(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities, coordinator: coordinator, runner: runner,
            driver: FreshRecordPlanDriver(mode: mode), root: root)
    }
}
#endif
