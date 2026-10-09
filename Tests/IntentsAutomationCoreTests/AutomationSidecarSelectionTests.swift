#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSidecarSelectionTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sidecar-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try AutomationPath.canonical(root)
    }
    func testActualOwnedSidecarReceivesSelectedToolchainWithoutInheritedRunnerOverrides() async throws {
        let root = try root(), developer = root.appendingPathComponent("SelectedDeveloper")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: false)
        let source = """
        import {createInterface} from 'node:readline';
        createInterface({input:process.stdin}).on('line',line=>{
          const request=JSON.parse(line);
          process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result:{protocolVersion:1,adapterVersion:'0.1.0',
            developerDirectory:process.env.DEVELOPER_DIR??null,runnerOverride:process.env.AGENT_DEVICE_IOS_BUNDLE_ID??null}})+'\\n');
        });
        """
        let script = root.appendingPathComponent("fixture.mjs"); try Data(source.utf8).write(to: script)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let node = repo.appendingPathComponent("Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node")
        guard FileManager.default.fileExists(atPath: node.path) else { throw XCTSkip("Private pinned Node runtime not acquired") }
        let process = try AutomationSidecarProcess(configuration: .init(node: try AutomationPath.canonical(node), entry: script,
            stateDirectory: root.appendingPathComponent("state"), developerDirectory: developer), reverse: { _, _ in .null })
        do {
            try await process.start()
            let result = try await process.handshake()
            XCTAssertEqual(result.object?["developerDirectory"], .string(developer.path))
            XCTAssertEqual(result.object?["runnerOverride"], .null)
        } catch { _ = await process.stop(); throw error }
        let stopped = await process.stop(); XCTAssertTrue(stopped)
    }
    func testDeveloperDirectoryAliasesAndMissingSelectionsCannotBecomeChildEnvironment() throws {
        let root = try root(), developer = root.appendingPathComponent("Developer"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: developer)
        let file = root.appendingPathComponent("regular-file"); try Data().write(to: file)
        for invalid in [alias, root.appendingPathComponent("missing"), file] {
            XCTAssertThrowsError(try AutomationSidecarProcess.environment(.init(node: root, entry: root, stateDirectory: root, developerDirectory: invalid)))
        }
        let environment = try AutomationSidecarProcess.environment(.init(node: root, entry: root, stateDirectory: root))
        XCTAssertNil(environment["DEVELOPER_DIR"])
        XCTAssertNil(environment["AGENT_DEVICE_IOS_RUNNER_TEST_BUNDLE_ID"])
    }
    private struct Subject: AutomationSubjectVerifier {
        func verify(app: AppIdentity, target: TargetIdentity) async throws {}
    }
    private struct Release: AutomationDeviceReleaseVerifier {
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {}
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool { false }
    }
    func testPhysicalDriverRefusesMissingToolchainOrControllerScopeBeforeCreatingState() throws {
        let root = try root(), target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let approval = RunApproval(runID: "run", app: .init(logicalID: "app", bundleID: "example.App", platform: "ios"),
            target: target, environmentID: "test", effects: [.observe], maximumActions: 1, disposable: false)
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
        let defaults = AutomationSimulatorReleaseVerifier.runnerBundleIDs
        let file = root.appendingPathComponent("regular-file"); try Data().write(to: file)
        for selection in [(Optional<URL>.none, defaults), (Optional(root), []), (Optional(root), ["example.Foreign"]),
                          (Optional(root), defaults + [defaults[0]]), (Optional(root), defaults + ["example.Foreign\n"]),
                          (Optional(root.appendingPathComponent("missing")), defaults), (Optional(URL(string: "https://example.invalid")!), defaults),
                          (Optional(file), defaults)] {
            let state = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try AutomationSidecarRouteDriver(bundleURL: root, expectedTeamID: "3Z3955EFRE", stateDirectory: state,
                approval: approval, leases: leases, artifacts: artifacts, subjectVerifier: Subject(), releaseVerifier: Release(),
                developerDirectory: selection.0, controllerBundleIDs: selection.1))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        }
        // Explicit pinned expected IDs are distinct from runtime-observed controller identity.
        _ = try AutomationSidecarRouteDriver(bundleURL: root, expectedTeamID: "3Z3955EFRE", stateDirectory: root.appendingPathComponent("valid"),
            approval: approval, leases: leases, artifacts: artifacts, subjectVerifier: Subject(), releaseVerifier: Release(),
            developerDirectory: root, controllerBundleIDs: defaults)
    }
}
#endif
