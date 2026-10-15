#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparationRuntimeRegressionTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/preparation-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ value: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }

    func testPhysicalIdentityResolutionLeavesCaptureDestinationAbsent() async throws {
        let root = try root(), session = root.appendingPathComponent("capture"), source = root.appendingPathComponent("input")
        try write("let value = 1", to: source.appendingPathComponent("App.swift"))
        let target = TargetIdentity(id: UUID().uuidString, kind: .physical)
        // UUID normalization returns without any command, SDK, or device access.
        let resolved = try await AutomationPreparationTargetResolution.resolve(target, sessionRoot: session,
            developerDirectory: root.appendingPathComponent("unused-Xcode"))
        XCTAssertEqual(resolved.id, target.id)
        XCTAssertEqual(resolved.physicalDeviceIdentifier, UUID(uuidString: target.id)?.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["input"])
        _ = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("source/App.swift").path))
    }

    func testPhysicalInventoryUsesSiblingScratchAndCleansUpFailure() async throws {
        let root = try root(), session = root.appendingPathComponent("capture")
        let target = TargetIdentity(id: UUID().uuidString, kind: .physical)
        do {
            _ = try await AutomationPreparationTargetResolution.resolve(target, sessionRoot: session, developerDirectory: root) { _, _, workspace in
                XCTAssertNotEqual(workspace, session)
                XCTAssertEqual(workspace.deletingLastPathComponent(), session.deletingLastPathComponent())
                XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
                throw AutomationContractError.missingEvidence("fixture inventory failed")
            }
            XCTFail("Expected inventory failure")
        } catch { XCTAssertTrue(String(describing: error).contains("fixture inventory failed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPhysicalResolutionRetainsIdentityAndCaptureOwnershipGuards() async throws {
        let root = try root(), session = root.appendingPathComponent("capture")
        do {
            _ = try await AutomationPreparationTargetResolution.resolve(.init(id: "not-a-device", kind: .physical),
                sessionRoot: session, developerDirectory: root)
            XCTFail("Invalid physical identities must remain rejected")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        try Data("preserve".utf8).write(to: session.appendingPathComponent("existing"))
        do {
            _ = try await AutomationPreparationTargetResolution.resolve(.init(id: UUID().uuidString, kind: .physical),
                sessionRoot: session, developerDirectory: root)
            XCTFail("An existing capture destination must remain rejected")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("existing"), encoding: .utf8), "preserve")
    }

    func testDefaultNodeInventoryPrefersEffectivePathAndHasDeterministicFallback() throws {
        let root = try root(), first = root.appendingPathComponent("first/bin/node"), second = root.appendingPathComponent("second/bin/node")
        try write("first installed node", to: first, executable: true)
        try write("second installed node", to: second, executable: true)
        let search = first.deletingLastPathComponent().path + ":" + second.deletingLastPathComponent().path
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: search, fallback: [second, first]), [first])
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: "/missing/GUI/path", fallback: [second, first]), [second])
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: "relative:.", fallback: [first, second]), [first])
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: search, fallback: [], excluding: root.appendingPathComponent("first")), [second])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: search, fallback: []), [second])
        XCTAssertTrue(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: "", fallback: []).isEmpty)
        let directory = root.appendingPathComponent("directory/bin/node")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: directory.deletingLastPathComponent().path, fallback: [second]), [second])
    }

    func testDefaultNodeInventoryCanonicalizesAliasesBeforePinning() throws {
        let root = try root(), node = root.appendingPathComponent("installed/bin/node"), alias = root.appendingPathComponent("path/bin/node")
        try write("pinned installed node", to: node, executable: true)
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: node)
        XCTAssertEqual(AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: alias.deletingLastPathComponent().path, fallback: []), [node])
    }

    func testRecognizedMetroDiscoveryAcceptsSelectedInstalledNodeAndRejectsExplicitMissingOrAmbiguousInventory() throws {
        let root = try root(), source = root.appendingPathComponent("source")
        let project = source.appendingPathComponent("ios/Demo.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write(#"{"dependencies":{"expo":"55.0.23","react-native":"0.83.6"}}"#, to: source.appendingPathComponent("package.json"))
        for (name, version) in [("expo", "55.0.23"), ("react-native", "0.83.6"), ("@expo/metro-config", "55.0.20"), ("@expo/metro", "55.1.1"), ("metro", "0.83.7"), ("metro-config", "0.83.7")] {
            let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": version])
            try write(String(decoding: data, as: UTF8.self), to: source.appendingPathComponent("node_modules/" + name + "/package.json"))
        }
        try write("""
        class Delegate: ExpoReactNativeFactoryDelegate {
        #if DEBUG
        let url = RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: ".expo/.virtual-metro-entry")
        #else
        let url = Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        #endif
        }
        """, to: source.appendingPathComponent("ios/Demo/AppDelegate.swift"))
        try write(#"this._config.maxWorkers > 1; require("./Worker");"#, to: source.appendingPathComponent("node_modules/metro/src/DeltaBundler/WorkerFarm.js"))
        try write(#"RCT_jsLocation @"lazy" @"excludeSource" @"app""#, to: source.appendingPathComponent("node_modules/react-native/React/Base/RCTBundleURLProvider.mm"))
        let node = root.appendingPathComponent("installed/bin/node"), other = root.appendingPathComponent("other/bin/node")
        try write("installed executable, never launched", to: node, executable: true)
        try write("another executable, never launched", to: other, executable: true)
        let candidate = AutomationApplicationCandidate(id: project.path + "#TARGET", name: "Demo", kind: .sourceTarget,
            containerPath: project.path, targetID: "TARGET", bundleID: nil, platform: nil, architectures: [], configurations: ["Debug"], app: nil)
        let selected = AutomationMetroAutomaticRecipe.defaultNodeTools(searchPath: "", fallback: [node, other], excluding: source)
        let recipe = try XCTUnwrap(AutomationMetroAutomaticRecipe.discover(source: source, candidate: candidate, nodeTools: selected))
        XCTAssertEqual(recipe.nodePath, node.path)
        XCTAssertEqual(recipe.nodeSHA256, AutomationArtifactRegistry.digest(try Data(contentsOf: node)))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.discover(source: source, candidate: candidate, nodeTools: []))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.discover(source: source, candidate: candidate, nodeTools: [node, other]))
        let deduplicated = try AutomationMetroAutomaticRecipe.discover(source: source, candidate: candidate, nodeTools: [node, node])
        XCTAssertEqual(deduplicated?.nodePath, node.path)
    }

    func testJavaScriptLifetimePreservesApprovedExecutionAfterSimulatorSetup() throws {
        let now = ContinuousClock.now
        let timing = try AutomationJavaScriptSessionTiming.workflow(wallClockSeconds: 600, allowBootAndInstall: true, campaignDeadline: nil)
        let deadline = timing.operationDeadline(at: now)
        XCTAssertEqual(now.duration(to: deadline), .seconds(600 + 420 + 360))
        // Reproduces the reported two 110-second waits plus 30-second setup:
        // neither the old 240-second gate nor the old 600-second child cap applies.
        XCTAssertGreaterThan(now.duration(to: deadline), .seconds(250))
        XCTAssertGreaterThan(timing.workerTimeout(automaticMetro: true), timing.operationTimeout + .seconds(240))
        XCTAssertGreaterThan(timing.workerTimeout(automaticMetro: false), timing.operationTimeout)
        let ready = now.advanced(by: .seconds(200))
        XCTAssertEqual(ready.duration(to: timing.operationDeadline(at: ready)), timing.operationTimeout)
    }

    func testJavaScriptLifetimeBoundsCampaignAndKeepsCleanupAfterExpiry() throws {
        let now = ContinuousClock.now, campaign = now.advanced(by: .seconds(40))
        let timing = try AutomationJavaScriptSessionTiming.workflow(wallClockSeconds: 600, allowBootAndInstall: true, campaignDeadline: campaign)
        XCTAssertEqual(timing.operationDeadline(at: now), campaign.advanced(by: AutomationJavaScriptSessionTiming.releaseAllowance))
        let short = try AutomationJavaScriptSessionTiming.workflow(wallClockSeconds: 1, allowBootAndInstall: false,
            campaignDeadline: now.advanced(by: .seconds(5000)))
        XCTAssertEqual(now.duration(to: short.operationDeadline(at: now)), short.operationTimeout)
        XCTAssertThrowsError(try AutomationJavaScriptSessionTiming.workflow(wallClockSeconds: 0, allowBootAndInstall: false, campaignDeadline: nil))
        XCTAssertThrowsError(try AutomationJavaScriptSessionTiming.workflow(wallClockSeconds: -1, allowBootAndInstall: false, campaignDeadline: nil))
    }
}
#endif
