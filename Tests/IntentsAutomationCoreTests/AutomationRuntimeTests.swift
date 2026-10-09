#if os(macOS)
import XCTest
@testable import IntentsAutomationCore
import Darwin

final class AutomationRuntimeTests: XCTestCase {
    private func fixture() throws -> URL {
        let contents = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString).appendingPathComponent("Contents")
        var files: [String: String] = [:]
        for path in AutomationRuntimeBundle.required {
            let file = contents.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(path.utf8); try data.write(to: file)
            files[path] = AutomationArtifactRegistry.digest(data)
        }
        let manifest = AutomationRuntimeBundle.Manifest(schemaVersion: 1, architecture: "arm64", nodeVersion: "24.21.0", files: files)
        try JSONEncoder().encode(manifest).write(to: contents.appendingPathComponent("Resources/Automation/runtime-manifest.json"))
        return contents
    }
    func testUnsignedHashCorrectRuntimeDoesNotBecomeLaunchAuthority() throws {
        let contents = try fixture(); defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        try AutomationRuntimeBundle.verifyAssets(contents: contents)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: contents.deletingLastPathComponent(),
            stateDirectory: contents.deletingLastPathComponent().appendingPathComponent("state"), expectedTeamID: "3Z3955EFRE"))
    }
    func testMissingChangedAndUnlistedAssetsFail() throws {
        let contents = try fixture(); defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let entry = contents.appendingPathComponent(AutomationRuntimeBundle.required[2]), original = try Data(contentsOf: entry)
        try Data("changed".utf8).write(to: entry)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
        try original.write(to: entry)
        let extra = contents.appendingPathComponent("Resources/Automation/unlisted.js"); try Data().write(to: extra)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
        try FileManager.default.removeItem(at: extra); try FileManager.default.removeItem(at: entry)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
    }
    func testEscapingSymlinksAndNonregularFilesFailWithoutOpeningThem() throws {
        let contents = try fixture(); defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let entry = contents.appendingPathComponent(AutomationRuntimeBundle.required[2])
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
        try FileManager.default.removeItem(at: entry)
        XCTAssertEqual(mkfifo(entry.path, 0o600), 0)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
    }
    func testManifestTraversalAndHelperAliasesCannotSupplyExecutablePaths() throws {
        let contents = try fixture(); defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let manifestURL = contents.appendingPathComponent("Resources/Automation/runtime-manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(AutomationRuntimeBundle.Manifest.self, from: original)
        manifest.files["Resources/Automation/../../outside.js"] = String(repeating: "a", count: 64)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
        try original.write(to: manifestURL)
        let node = contents.appendingPathComponent(AutomationRuntimeBundle.required[0])
        try FileManager.default.removeItem(at: node)
        try FileManager.default.createSymbolicLink(at: node, withDestinationURL: contents.appendingPathComponent(AutomationRuntimeBundle.required[1]))
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
    }
    func testEmptyDirectoriesAlsoConsumeTraversalAndDepthBudgets() throws {
        let contents = try fixture(); defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let assets = contents.appendingPathComponent("Resources/Automation")
        var deep = assets
        for _ in 0..<33 { deep.appendPathComponent("nested") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
        try FileManager.default.removeItem(at: assets.appendingPathComponent("nested"))
        for index in 0..<10_001 {
            try FileManager.default.createDirectory(at: assets.appendingPathComponent("empty-\(index)"), withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifyAssets(contents: contents))
    }
}
#endif
