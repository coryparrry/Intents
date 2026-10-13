#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class AutomationPreparationRestorationTests: XCTestCase {
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

    func testLatestPreparationSkipsNewerBrokenRecordButRejectsChangedRetainedFiles() throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try fixture.savePreparation()
        let badSession = fixture.support.appendingPathComponent("prepare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: badSession, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = badSession.appendingPathComponent("prepared-application.json")
        try Data("broken".utf8).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: record.path)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), prepared)
        let files = [URL(fileURLWithPath: prepared.host.subjectProductPath).appendingPathComponent("payload"),
            URL(fileURLWithPath: prepared.host.hostBundlePath).appendingPathComponent("payload"),
            URL(fileURLWithPath: prepared.host.xctestrunPath),
            URL(fileURLWithPath: prepared.buildLogPath).deletingLastPathComponent().appendingPathComponent("generated-host/Owned/Sources/HostPlan.swift")]
        for file in files {
            let original = try Data(contentsOf: file)
            try Data("changed".utf8).write(to: file)
            XCTAssertThrowsError(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), file.path)
            try original.write(to: file)
            XCTAssertEqual(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: fixture.support), prepared)
        }
    }

    func testChangedPreparedFilesLeaveLaunchUnpreparedWithUsefulMessage() async throws {
        let fixture = try RetainedPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try fixture.savePreparation()
        try Data("changed".utf8).write(to: URL(fileURLWithPath: prepared.host.xctestrunPath))
        let model = AppAutomationStore(supportDirectory: fixture.support)
        await model.waitForPreparation()
        XCTAssertNil(model.prepared)
        XCTAssertNil(model.intake)
        XCTAssertFalse(model.canRun)
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
    func savePreparation() throws -> AutomationPreparedApplication {
        let session = support.appendingPathComponent("prepare-" + UUID().uuidString)
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session, additionalRoots: [library])
        let subject = session.appendingPathComponent("Subject.app"), host = session.appendingPathComponent("Owned.app")
        for product in [subject, host] {
            try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
            try Data("retained payload".utf8).write(to: product.appendingPathComponent("payload"))
        }
        var app = AppIdentity(logicalID: project.path + "#APP", bundleID: "example.Subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: subject))
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
            generatedHost: .init(projectPath: project.path, scheme: "Owned", targetID: "HOST", bundleID: "example.Owned", configuration: "Debug", templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(records))),
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
