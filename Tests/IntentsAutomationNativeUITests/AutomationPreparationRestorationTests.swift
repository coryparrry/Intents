#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class AutomationPreparationRestorationTests: XCTestCase {
    func testWorkspaceSelectionRestoresExactCandidateWithoutRebuilding() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try fixture.savePreparation(workspaceSelection: true)
        let model = AppAutomationStore(supportDirectory: fixture.support, preparationExecutor: { _, _, _ in
            XCTFail("Workspace restoration must reuse the retained build")
            throw AutomationContractError.invalidIdentity
        })
        await model.waitForPreparation()
        XCTAssertEqual(model.prepared, prepared)
        XCTAssertEqual(model.candidateID, prepared.host.app.logicalID)
        XCTAssertEqual(model.candidate?.workspacePath, fixture.source.appendingPathComponent("Subject.xcworkspace").path)
        XCTAssertEqual(model.sourcePreparationTarget, prepared.host.target)
        XCTAssertFalse(model.effectsConfirmed)
        model.candidateSelectionChanged()
        XCTAssertEqual(model.prepared, prepared)
        await model.closeAndWait()
    }

    func testStructuredRestorationUsesWorkspacePathAndRejectsIdentityDrift() throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var prepared = try fixture.savePreparation(workspaceSelection: true)
        var graph = AutomationSourceGraph(sourceManifestDigest: try prepared.source.digest,
            projectRelativePath: "Source/Subject.xcodeproj", targetID: "APP", configuration: "Debug",
            nodes: [], edges: [], inputs: [], declarations: [], gaps: [])
        graph.workspaceRelativePath = "Source/Subject.xcworkspace"
        prepared.sourceGraph = graph
        prepared.workspace = .init(relativePath: "Source/Subject.xcworkspace", subjectScheme: "Subject",
            projectPaths: ["Source/Subject.xcodeproj"], generatedFiles: [:])
        XCTAssertEqual(try AutomationPreparedApplicationRecord.intakeURL(for: prepared),
            fixture.source.appendingPathComponent("Subject.xcworkspace"))
        prepared.host.app.logicalID = fixture.project.path + "#APP"
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.intakeURL(for: prepared))
        prepared.sourceGraph?.projectRelativePath = "../Outside.xcodeproj"
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.intakeURL(for: prepared))
    }

    func testNestedWorkspaceRestoresItsSiblingProjectWithinRetainedPrimaryRoot() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try fixture.savePreparation(workspaceSelection: true, nestedWorkspace: true)
        let workspace = fixture.source.appendingPathComponent("Containers/Subject.xcworkspace")
        // Direct workspace intake cannot use the wider source grant that made
        // this sibling reference selectable during the original preparation.
        XCTAssertTrue(try AutomationApplicationIntake.assess(workspace).candidates.isEmpty)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.intakeURL(for: prepared), fixture.source)
        let model = AppAutomationStore(supportDirectory: fixture.support, preparationExecutor: { _, _, _ in
            XCTFail("Nested workspace restoration must reuse the retained build")
            throw AutomationContractError.invalidIdentity
        })
        await model.waitForPreparation()
        XCTAssertEqual(model.prepared, prepared)
        XCTAssertEqual(model.candidateID, prepared.host.app.logicalID)
        XCTAssertEqual(model.candidate?.workspacePath, workspace.path)
        XCTAssertEqual(model.candidate?.containerPath, fixture.project.path)
        XCTAssertEqual(model.selectedSourceRoot, fixture.source)
        XCTAssertEqual(model.sourceGrants.urls, [fixture.library])
        XCTAssertFalse(model.effectsConfirmed)
        await model.closeAndWait()
    }

    func testLaunchRestoresDependencyInclusiveBuildWithoutPreparingOrRestoringEffectsApproval() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dependency = fixture.source.appendingPathComponent("node_modules/fixture/index.js")
        try FileManager.default.createDirectory(at: dependency.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export const retainedDependency = true;".utf8).write(to: dependency)
        let prepared = try fixture.savePreparation(includesDependencies: true)
        XCTAssertEqual(prepared.source.includesDependencies, true)
        XCTAssertTrue(prepared.source.files.contains { $0.relativePath.hasSuffix("node_modules/fixture/index.js") })
        XCTAssertEqual(prepared.host.app.sourceManifestDigest, try prepared.source.digest)
        let model = AppAutomationStore(supportDirectory: fixture.support, preparationExecutor: { _, _, _ in
            XCTFail("Reopening a retained dependency-inclusive build must not rebuild")
            throw AutomationContractError.invalidIdentity
        })
        await model.waitForPreparation()
        XCTAssertEqual(model.prepared, prepared)
        XCTAssertEqual(model.catalog, prepared.catalog)
        XCTAssertEqual(model.candidate?.id, prepared.host.app.logicalID)
        XCTAssertEqual(model.candidateID, prepared.host.app.logicalID)
        XCTAssertEqual(model.sourcePreparationTarget, prepared.host.target)
        XCTAssertTrue(model.includesSourceDependencies)
        XCTAssertFalse(model.effectsConfirmed)
        XCTAssertFalse(model.firstRunEffectsConfirmed)
        XCTAssertFalse(model.canRun)
        XCTAssertNil(model.report)
        XCTAssertNil(model.pendingCommandStatus)
        model.candidateSelectionChanged()
        XCTAssertEqual(model.prepared, prepared)
        XCTAssertTrue(model.includesSourceDependencies)
        await model.closeAndWait()
    }

    func testLaunchRestoresSelectionSourceGrantsAndPreparedBuildWithoutPreparingAgain() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try fixture.savePreparation()
        let model = AppAutomationStore(supportDirectory: fixture.support, preparationExecutor: { _, _, _ in
            XCTFail("Restoring the retained build must not invoke preparation")
            throw AutomationContractError.invalidIdentity
        })
        await model.waitForPreparation()
        XCTAssertEqual(model.prepared, prepared)
        XCTAssertEqual(model.catalog, prepared.catalog)
        XCTAssertEqual(model.candidateID, prepared.host.app.logicalID)
        XCTAssertEqual(model.configuration, "Debug")
        XCTAssertEqual(model.sourcePreparationTarget, prepared.host.target)
        XCTAssertEqual(model.selectedSourceRoot, fixture.source)
        XCTAssertEqual(model.sourceGrants.urls, [fixture.library])
        XCTAssertTrue(model.canPrepare)
        // SwiftUI observes candidate changes after restoration. It must not erase
        // a valid build when notifying the store about the restored candidate.
        model.candidateSelectionChanged()
        XCTAssertEqual(model.prepared, prepared)
        // Explicitly reselecting the candidate retains the original reset behavior.
        model.selectCandidate()
        await model.waitForPreparation()
        XCTAssertNil(model.prepared)
        await model.closeAndWait()
        XCTAssertTrue(model.sourceGrants.urls.isEmpty)
    }

    func testLatestCompletedPreparationRestoresItsAppAndTargetAndIgnoresUnfinishedDirectories() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let older = try fixture.savePreparation()
        let latest = try fixture.savePreparation(appName: "Other")
        try fixture.orderRecords(older: older, latest: latest)
        let unfinished = fixture.support.appendingPathComponent("prepare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: unfinished.path)
        XCTAssertNotEqual(older.host.app.logicalID, latest.host.app.logicalID)
        XCTAssertNotEqual(older.host.target, latest.host.target)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), latest)
        let model = AppAutomationStore(supportDirectory: fixture.support)
        await model.waitForPreparation()
        XCTAssertEqual(model.prepared, latest)
        XCTAssertEqual(model.candidateID, latest.host.app.logicalID)
        XCTAssertEqual(model.sourcePreparationTarget, latest.host.target)
        await model.closeAndWait()
    }

    func testDamagedLatestCompletedPreparationNeverRestoresAnOlderAppOrTarget() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let older = try fixture.savePreparation()
        let latest = try fixture.savePreparation(appName: "Other")
        try fixture.orderRecords(older: older, latest: latest)
        let record = URL(fileURLWithPath: latest.buildLogPath).deletingLastPathComponent().appendingPathComponent("prepared-application.json")
        let files = [URL(fileURLWithPath: latest.host.subjectProductPath).appendingPathComponent("payload"),
            URL(fileURLWithPath: latest.host.hostBundlePath).appendingPathComponent("payload"),
            URL(fileURLWithPath: latest.host.xctestrunPath),
            URL(fileURLWithPath: latest.buildLogPath).deletingLastPathComponent().appendingPathComponent("generated-host/Owned/Sources/HostPlan.swift"), record]
        for file in files {
            let original = try Data(contentsOf: file)
            try Data("changed".utf8).write(to: file)
            XCTAssertThrowsError(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), file.path)
            let model = AppAutomationStore(supportDirectory: fixture.support)
            await model.waitForPreparation()
            XCTAssertNil(model.prepared, file.path)
            XCTAssertNil(model.intake, file.path)
            XCTAssertFalse(model.canRun, file.path)
            XCTAssertTrue(model.message?.contains("Prepare the app again") == true, file.path)
            await model.closeAndWait()
            try original.write(to: file)
            XCTAssertEqual(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), latest)
        }
        var drifted = latest; drifted.source.excludedPaths.append("changed")
        try JSONEncoder().encode(drifted).write(to: record)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support))
        let model = AppAutomationStore(supportDirectory: fixture.support)
        await model.waitForPreparation()
        XCTAssertNil(model.prepared)
        XCTAssertTrue(model.message?.contains("Prepare the app again") == true)
        await model.closeAndWait()
    }

}

private struct RetainedPreparationFixture {
    let root: URL
    var support: URL { root.appendingPathComponent("Support") }
    var source: URL { root.appendingPathComponent("Source") }
    var library: URL { root.appendingPathComponent("Library") }
    var project: URL { source.appendingPathComponent("Subject.xcodeproj") }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/preparation-restoration-" + UUID().uuidString)
        for directory in [support, project, library] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let plist: [String: Any] = ["objects": [
            "APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS"],
            "CONFIGS": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": "Debug"]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
    }
    func orderRecords(older: AutomationPreparedApplication, latest: AutomationPreparedApplication) throws {
        let oldRecord = URL(fileURLWithPath: older.buildLogPath).deletingLastPathComponent().appendingPathComponent("prepared-application.json")
        let newRecord = URL(fileURLWithPath: latest.buildLogPath).deletingLastPathComponent().appendingPathComponent("prepared-application.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: oldRecord.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newRecord.path)
    }
    func savePreparation(appName: String = "Subject", includesDependencies: Bool = false, workspaceSelection: Bool = false,
                         nestedWorkspace: Bool = false) throws -> AutomationPreparedApplication {
        let selectedProject = source.appendingPathComponent(appName + ".xcodeproj")
        if selectedProject != project {
            try FileManager.default.copyItem(at: project, to: selectedProject)
        }
        let selectedWorkspace = source.appendingPathComponent((nestedWorkspace ? "Containers/" : "") + appName + ".xcworkspace")
        if workspaceSelection {
            try FileManager.default.createDirectory(at: selectedWorkspace, withIntermediateDirectories: true)
            let xml = "<?xml version=\"1.0\"?><Workspace version=\"1.0\"><FileRef location=\"group:" + (nestedWorkspace ? "../" : "") + appName + ".xcodeproj\"/></Workspace>"
            try Data(xml.utf8).write(to: selectedWorkspace.appendingPathComponent("contents.xcworkspacedata"))
        }
        let session = support.appendingPathComponent("prepare-" + UUID().uuidString)
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session, additionalRoots: [library], includesDependencies: includesDependencies)
        let subject = session.appendingPathComponent("Subject.app"), host = session.appendingPathComponent("Owned.app")
        for product in [subject, host] {
            try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
            try Data("retained payload".utf8).write(to: product.appendingPathComponent("payload"))
        }
        var app = AppIdentity(logicalID: selectedProject.path + "#APP", bundleID: "example." + appName, platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: subject))
        if workspaceSelection { app.logicalID = selectedWorkspace.path + "::" + app.logicalID }
        app.canonicalBundlePath = subject.path; app.sourceManifestDigest = try manifest.digest; app.configuration = "Debug"
        let sources = session.appendingPathComponent("generated-host/Owned/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var records: [String: String] = [:]
        for file in AutomationHostGenerator.templateFiles {
            let data = Data(("// " + file).utf8); try data.write(to: sources.appendingPathComponent(file))
            records[file] = AutomationArtifactRegistry.digest(data)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let xctestrun = session.appendingPathComponent("host.xctestrun"), testData = Data("retained test settings".utf8)
        try testData.write(to: xctestrun)
        let prepared = AutomationPreparedApplication(source: manifest,
            generatedHost: .init(projectPath: selectedProject.path, scheme: "Owned", targetID: "HOST", bundleID: "example.Owned", configuration: "Debug", templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(records))),
            host: .init(app: app, target: .init(id: UUID().uuidString, kind: .simulator), xctestrunPath: xctestrun.path,
                xctestrunDigest: AutomationArtifactRegistry.digest(testData), subjectProductPath: subject.path, hostBundlePath: host.path,
                hostProductDigest: try AutomationProductDigest.compute(bundle: host), hostBundleID: "example.Owned", testTarget: "Owned"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []),
            buildLogPath: session.appendingPathComponent("build.log").path, buildLogTruncated: false)
        let record = session.appendingPathComponent("prepared-application.json")
        try encoder.encode(prepared).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        return prepared
    }
}
#endif
