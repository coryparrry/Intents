#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationWorkspaceBuildContextTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("workspace-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func workspace(_ source: URL) throws -> URL {
        let workspace = source.appendingPathComponent("Workspace/Subject.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("<Workspace><Group location=\"group:../App\"><FileRef location=\"group:Subject.xcodeproj\"/></Group><FileRef location=\"container:../Dependency/Subject.xcodeproj\"/></Workspace>".utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        return workspace
    }
    func testFrozenWorkspaceRebasesAllProjectsAndRejectsChangedDependency() throws {
        let root = try root(), source = root.appendingPathComponent("original")
        let app = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("App"))
        _ = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("Dependency"))
        _ = try workspace(source)
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "App/Subject.xcodeproj")
        let context = try AutomationWorkspaceBuildContext.prepare(workspaceRelativePath: "Workspace/Subject.xcworkspace", selectedProject: rebased, targetID: app.targetID, name: "Subject", manifest: manifest)
        XCTAssertEqual(context.projectPaths, ["App/Subject.xcodeproj", "Dependency/Subject.xcodeproj"])
        XCTAssertEqual(context.containerArguments(session: session), ["-workspace", session.appendingPathComponent("source/Workspace/Subject.xcworkspace").path])
        try context.verify(session: session, manifest: manifest)
        let xml = try String(contentsOf: session.appendingPathComponent("source/Workspace/Subject.xcworkspace/contents.xcworkspacedata"), encoding: .utf8)
        XCTAssertTrue(xml.contains("../Dependency/Subject.xcodeproj")); XCTAssertFalse(xml.contains(source.path))
        try Data("changed".utf8).write(to: session.appendingPathComponent("source/Dependency/Subject.xcodeproj/project.pbxproj"))
        XCTAssertThrowsError(try context.verify(session: session, manifest: manifest))
        try AutomationSourceSnapshot.verifyOriginal(manifest)
    }
    func testWorkspacePackageLockIsBoundEvenForLocalOnlyTarget() throws {
        let root = try root(), source = root.appendingPathComponent("original")
        let app = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("App"))
        _ = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("Dependency"))
        let container = try workspace(source), lock = container.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":3,\"pins\":[]}".utf8).write(to: lock)
        let session = root.appendingPathComponent("session"), manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "App/Subject.xcodeproj")
        let context = try AutomationWorkspaceBuildContext.prepare(workspaceRelativePath: "Workspace/Subject.xcworkspace", selectedProject: rebased, targetID: app.targetID, name: "Subject", manifest: manifest)
        let path = AutomationWorkspaceBuildContext.packageResolutionPath(context.relativePath)
        XCTAssertNotNil(context.generatedFiles[path])
        try Data("changed".utf8).write(to: session.appendingPathComponent("source/" + path))
        XCTAssertThrowsError(try context.verify(session: session, manifest: manifest))
    }
    func testUnresolvedWorkspaceNeverFallsBackToProject() throws {
        let root = try root(), source = root.appendingPathComponent("original")
        let app = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("App"))
        _ = try workspace(source)
        let session = root.appendingPathComponent("session"), manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "App/Subject.xcodeproj")
        XCTAssertThrowsError(try AutomationWorkspaceBuildContext.prepare(workspaceRelativePath: "Workspace/Subject.xcworkspace", selectedProject: rebased, targetID: app.targetID, name: "Subject", manifest: manifest))
    }
    func testActualWorkspaceBuildAndRetainedReloadWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_WORKSPACE_BUILD"] == "1" else { throw XCTSkip("Opt-in Xcode build, without launching the subject") }
        let root = try root(), source = root.appendingPathComponent("original")
        _ = try AutomationMultiRootPackageFixture.write(source)
        _ = try AutomationMacInputProbeFixture.write(at: source.appendingPathComponent("Dependency"))
        let container = try workspace(source)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(source).candidates.first { $0.containerPath.hasSuffix("/App/Subject.xcodeproj") })
        XCTAssertEqual(candidate.workspacePath, container.path)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let approval = AutomationBuildApproval(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: try AutomationMacGUIIdentity.currentTarget())
        let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: approval, sessionRoot: root.appendingPathComponent("prepare-" + UUID().uuidString), templates: templates, developerDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(prepared.workspace?.relativePath, "Workspace/Subject.xcworkspace")
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
    }
}
#endif
