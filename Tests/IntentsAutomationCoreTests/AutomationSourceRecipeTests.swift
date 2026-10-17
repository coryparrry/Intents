#if os(macOS)
import Foundation
import Darwin
import XCTest
@testable import IntentsAutomationCore

final class AutomationSourceRecipeTests: XCTestCase {
    func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/source-recipe-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["INTENTS_SOURCE_RECIPE_LIVE"] == "1" { print("Source recipe evidence: " + root.path) }
        else { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        return root
    }
    private func userTemporaryDirectory() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { throw AutomationContractError.invalidIdentity }
        return try AutomationPath.canonical(URL(fileURLWithPath: String(cString: buffer)))
    }
    func testPackagingAdmissionAndProfileNeverGrantRootReadOrOriginalWrite() throws {
        let root = try root(), source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("// package".utf8).write(to: source.appendingPathComponent("Package.swift"))
        let script = source.appendingPathComponent("package.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        let recipe = try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script)
        let profile = AutomationSourceRecipe.profile(root: root.appendingPathComponent("owned"), executable: recipe.executable,
            developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertFalse(profile.contains("(subpath \"/\")"))
        XCTAssertFalse(profile.contains("(subpath \"/var/folders/"))
        XCTAssertFalse(profile.contains("(subpath \"/private/var/folders/"))
        let canonicalTemporary = try userTemporaryDirectory()
        XCTAssertFalse(profile.contains("(subpath \"" + canonicalTemporary.path + "\")"))
        XCTAssertFalse(profile.contains("(subpath \"" + FileManager.default.temporaryDirectory.path + "\")"))
        XCTAssertFalse(profile.contains(source.path))
        XCTAssertFalse(profile.contains("allow network"))
        XCTAssertThrowsError(try AutomationSourceRecipe.swiftPMPackaging(source: source, script: root.appendingPathComponent("other.sh")))
        try Data("#!/usr/bin/python3\nprint('no')\n".utf8).write(to: script)
        XCTAssertThrowsError(try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script))
    }
    func testActualRecipeSandboxDeniesSiblingUserTemporaryReadAndWrite() async throws {
        let root = try userTemporaryDirectory().appendingPathComponent("recipe-sandbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("// package".utf8).write(to: source.appendingPathComponent("Package.swift"))
        let sentinel = root.appendingPathComponent("sibling-sentinel.txt"), sentinelBytes = Data("other task's input".utf8)
        try sentinelBytes.write(to: sentinel)
        let sentinelLiteral = "'" + sentinel.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let script = source.appendingPathComponent("package.sh")
        let probe = """
        #!/bin/sh
        set -eu
        [ "$TMP" = "$TEMP" ]
        [ "$TMPDIR" = "$TMP/" ]
        case "$TMP" in */SourceRecipes/*/scratch) ;; *) exit 24 ;; esac
        printf owned > "$TMPDIR/owned-marker"
        if /bin/cat \(sentinelLiteral) > "$TMPDIR/read-copy"; then exit 25; fi
        if printf changed > \(sentinelLiteral); then exit 26; fi
        printf isolation-verified
        exit 27
        """
        try Data(probe.utf8).write(to: script)
        let recipe = try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script)
        do {
            // This shell-only probe needs no Xcode build or generator installation.
            _ = try await recipe.run(supportRoot: support, developerDirectory: URL(fileURLWithPath: "/System/Library"))
            XCTFail("The probe must retain its intentional failure")
        } catch {
            guard let failure = error as? AutomationContractError, case .missingEvidence = failure else { throw error }
        }
        let sessions = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("SourceRecipes"), includingPropertiesForKeys: nil)
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        let log = try String(contentsOf: session.appendingPathComponent("recipe.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("Exit status: 27\n"), log)
        XCTAssertTrue(log.contains("isolation-verified"), log)
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("scratch/owned-marker")), Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: script), Data(probe.utf8))
    }
    func testChangedRecipeStopsBeforeCreatingOutput() async throws {
        let root = try root(), source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("// package".utf8).write(to: source.appendingPathComponent("Package.swift"))
        let script = source.appendingPathComponent("package.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        let recipe = try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script)
        try Data("#!/bin/sh\nprintf changed\n".utf8).write(to: script)
        do { _ = try await recipe.run(supportRoot: root.appendingPathComponent("support"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")); XCTFail("Changed recipe ran") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("support").path))
    }
    func testActualPinnedXcodeGenGenerationPreservesSource() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SOURCE_RECIPE_LIVE"] == "1" else { throw XCTSkip("Opt-in actual isolated generator qualification") }
        let root = try root(), source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("App"), withIntermediateDirectories: true)
        let spec = """
        name: RecipeFixture
        targets:
          App:
            type: application
            platform: macOS
            sources: [App]
            settings:
              PRODUCT_BUNDLE_IDENTIFIER: example.RecipeFixture
        """
        try Data(spec.utf8).write(to: source.appendingPathComponent("project.yml"))
        try Data("import AppKit\nlet app = NSApplication.shared\n".utf8).write(to: source.appendingPathComponent("App/main.swift"))
        let recipe = try AutomationSourceRecipe.xcodegen(source: source)
        let result = try await recipe.run(supportRoot: root.appendingPathComponent("support"), developerDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(try AutomationApplicationIntake.assess(result.selection).candidates.count, 1)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.yml")), Data(spec.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("RecipeFixture.xcodeproj").path))
        let receipt = try JSONDecoder().decode(AutomationSourceRecipe.Receipt.self, from: Data(contentsOf: result.receipt))
        XCTAssertEqual(receipt.version, "2.46.0")
        XCTAssertEqual(receipt.executableDigest, recipe.executableDigest)
    }
    func testActualSwiftPMPackagingAndWriteIsolation() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SOURCE_RECIPE_LIVE"] == "1" else { throw XCTSkip("Opt-in actual SwiftPM app packaging qualification") }
        let root = try root(), source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sources/RecipeFixture"), withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"RecipeFixture\", platforms: [.macOS(.v14)], targets: [.executableTarget(name: \"RecipeFixture\")])\n".utf8).write(to: source.appendingPathComponent("Package.swift"))
        try Data("import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.regular)\n".utf8).write(to: source.appendingPathComponent("Sources/RecipeFixture/main.swift"))
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.RecipeFixture", "CFBundleExecutable": "RecipeFixture", "CFBundleSupportedPlatforms": ["MacOSX"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: source.appendingPathComponent("AppInfo.plist"))
        let script = source.appendingPathComponent("package.sh")
        let original = "#!/bin/sh\nset -eu\nswift build --disable-sandbox --jobs 2\nmkdir -p dist/RecipeFixture.app/Contents/MacOS\ncp .build/debug/RecipeFixture dist/RecipeFixture.app/Contents/MacOS/RecipeFixture\ncp AppInfo.plist dist/RecipeFixture.app/Contents/Info.plist\n"
        try Data(original.utf8).write(to: script)
        let recipe = try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script)
        let result = try await recipe.run(supportRoot: root.appendingPathComponent("support"), developerDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(try AutomationApplicationIntake.assess(result.selection).candidates.first?.app?.platform, "macos")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".build").path))
        let sentinel = source.appendingPathComponent("sentinel.txt"); try Data("original".utf8).write(to: sentinel)
        try Data(("#!/bin/sh\nset -eu\nprintf changed > '" + sentinel.path + "'\n").utf8).write(to: script)
        let forbidden = try AutomationSourceRecipe.swiftPMPackaging(source: source, script: script)
        do { _ = try await forbidden.run(supportRoot: root.appendingPathComponent("blocked"), developerDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer")); XCTFail("Original write was allowed") }
        catch { XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8)) }
    }
}
#endif
