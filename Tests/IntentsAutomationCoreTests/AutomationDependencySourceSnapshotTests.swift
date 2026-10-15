import XCTest
@testable import IntentsAutomationCore

final class AutomationDependencySourceSnapshotTests: XCTestCase {
    private func fixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let root = try AutomationPath.canonical(path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ path: URL, _ content: String = "dependency") throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: path)
    }
    func testExpoHeadersRetainIdentityAndFlutterPluginDirectoriesBecomeRegularPrivateInputs() throws {
        let root = try fixture(), source = root.appendingPathComponent("app")
        try file(source.appendingPathComponent("node_modules/package/Header.h"))
        try file(source.appendingPathComponent("packages/plugin/Intent.swift"))
        let headers = source.appendingPathComponent("ios/Pods/Headers"), plugins = source.appendingPathComponent("ios/.symlinks/plugins")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: headers.appendingPathComponent("Header.h").path, withDestinationPath: "../../../node_modules/package/Header.h")
        try FileManager.default.createSymbolicLink(atPath: plugins.appendingPathComponent("plugin").path, withDestinationPath: source.appendingPathComponent("packages/plugin").path)
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("default")))
        let session = root.appendingPathComponent("approved")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session, includesDependencies: true)
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
        XCTAssertEqual(manifest.materializedLinks?.count, 2)
        for path in ["ios/Pods/Headers/Header.h", "ios/.symlinks/plugins/plugin/Intent.swift"] {
            if path.contains("Pods/Headers") {
                XCTAssertNotNil(manifest.files.first { $0.relativePath == path }?.symbolicLink)
                XCTAssertThrowsError(try AutomationReadOnlyFile.read(root: session.appendingPathComponent("source"), relativePath: path, maximumBytes: 100))
                XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("source").appendingPathComponent(path)), Data("dependency".utf8))
            } else {
                XCTAssertNil(manifest.files.first { $0.relativePath == path }?.symbolicLink)
                XCTAssertEqual(try AutomationReadOnlyFile.read(root: session.appendingPathComponent("source"), relativePath: path, maximumBytes: 100), Data("dependency".utf8))
            }
        }
        try file(source.appendingPathComponent("packages/plugin/Intent.swift"), "changed")
        XCTAssertThrowsError(try AutomationSourceSnapshot.verifyOriginal(manifest))
    }
    #if os(macOS)
    func testCocoaPodsHeaderAliasPreservesClangImportIdentityAndRejectsTampering() async throws {
        let root = try fixture(), source = root.appendingPathComponent("app")
        let header = "node_modules/package/Interface.h", alias = "ios/Pods/Headers/Public/Package/Interface.h"
        try file(source.appendingPathComponent(header), "@protocol CapturedInterface\n@end\n")
        try file(source.appendingPathComponent("Probe.m"), "#import \"" + alias + "\"\n#import \"" + header + "\"\n")
        let aliasURL = source.appendingPathComponent(alias)
        try FileManager.default.createDirectory(at: aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: aliasURL.path, withDestinationPath: "../../../../../node_modules/package/Interface.h")
        let session = root.appendingPathComponent("approved")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session, includesDependencies: true)
        let entry = try XCTUnwrap(manifest.files.firstIndex { $0.relativePath == alias })
        XCTAssertNotNil(manifest.files[entry].symbolicLink)
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
        func compile(_ directory: URL) async throws -> Int32 {
            let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/clang"),
                arguments: ["-x", "objective-c", "-fsyntax-only", "-Werror", directory.appendingPathComponent("Probe.m").path],
                directory: directory, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: .seconds(30))
            if result.exitStatus != 0 { XCTAssertFalse((result.stdout + result.stderr).isEmpty) }
            return result.exitStatus
        }
        let frozen = session.appendingPathComponent("source")
        let originalStatus = try await compile(frozen)
        XCTAssertEqual(originalStatus, 0)
        // Reproduces the historical duplicated regular-header failure.
        try FileManager.default.removeItem(at: frozen.appendingPathComponent(alias))
        try FileManager.default.copyItem(at: frozen.appendingPathComponent(header), to: frozen.appendingPathComponent(alias))
        let duplicateStatus = try await compile(frozen)
        XCTAssertNotEqual(duplicateStatus, 0)
        var changed = manifest; changed.files[entry].frozenSymbolicLink = "/outside/Interface.h"
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.files[entry].sha256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.files.removeAll { $0.relativePath == header }
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        let outside = root.appendingPathComponent("outside.h")
        try file(outside, "@protocol Outside\n@end\n")
        try FileManager.default.removeItem(at: aliasURL)
        try FileManager.default.createSymbolicLink(atPath: aliasURL.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("denied"), includesDependencies: true))
    }
    #endif
    func testExternalPluginNeedsAnExplicitRootAndRetainsBothRootDigests() throws {
        let root = try fixture(), source = root.appendingPathComponent("app"), package = root.appendingPathComponent("pub-cache/plugin")
        try file(source.appendingPathComponent("App.swift")); try file(package.appendingPathComponent("Intent.swift"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("plugin").path, withDestinationPath: package.path)
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("denied"), includesDependencies: true))
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("approved"), additionalRoots: [package], includesDependencies: true)
        XCTAssertEqual(manifest.capturedRoots?.count, 2)
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
        var changed = manifest; changed.files[0].materializedSourcePath = root.appendingPathComponent("outside").path
        XCTAssertThrowsError(try changed.validateCaptureLayout())
    }
    func testNodePackageDirectoryAliasesStayConfinedAndSupportDependencyCycles() throws {
        let root = try fixture(), source = root.appendingPathComponent("app")
        try file(source.appendingPathComponent("node_modules/.store/a/index.js"), "package-a")
        try file(source.appendingPathComponent("node_modules/.store/b/index.js"), "package-b")
        for (name, target) in [("a/node_modules/b", "../../b"), ("b/node_modules/a", "../../a")] {
            let path = source.appendingPathComponent("node_modules/.store/" + name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target)
        }
        let session = root.appendingPathComponent("approved")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session, includesDependencies: true)
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("source/node_modules/.store/a/node_modules/b/index.js"), encoding: .utf8), "package-b")
        var changed = manifest
        let index = try XCTUnwrap(changed.files.firstIndex { $0.symbolicLink != nil })
        changed.files[index].frozenSymbolicLink = "/private/tmp/outside"
        XCTAssertThrowsError(try changed.validateCaptureLayout())
    }
    func testPrivateFilesCyclesAndSharedBudgetsStillFailClosed() throws {
        let root = try fixture(), source = root.appendingPathComponent("app")
        try file(source.appendingPathComponent("packages/secret/.env"), "private")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("alias").path, withDestinationPath: "packages/secret/.env")
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("private-denied"), includesDependencies: true))
        try FileManager.default.removeItem(at: source.appendingPathComponent("alias"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("packages/cycle").path, withDestinationPath: ".")
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("cycle-denied"), includesDependencies: true))
        try FileManager.default.removeItem(at: source.appendingPathComponent("packages/cycle"))
        try file(source.appendingPathComponent("node_modules/dependency/file"))
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("budget-denied"), additionalRoots: [], limits: .init(entries: 3, bytes: 100), includesDependencies: true))
    }
    #if os(macOS)
    func testDependencyCaptureRequiresMatchingBuildApprovalAfterSerialization() throws {
        let root = try fixture(), source = root.appendingPathComponent("app")
        try file(source.appendingPathComponent("App.swift"))
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("approved"), includesDependencies: true)
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let defaultApproval = AutomationBuildApproval(sourceRoot: source.path, candidateID: "selected", configuration: "Release", target: target)
        XCTAssertThrowsError(try defaultApproval.validateSourceManifest(manifest))
        let approval = AutomationBuildApproval(sourceRoot: source.path, candidateID: "selected", configuration: "Release", target: target, includesDependencies: true)
        let decoded = try JSONDecoder().decode(AutomationBuildApproval.self, from: JSONEncoder().encode(approval))
        try decoded.validateSourceManifest(manifest)
        var changed = manifest; changed.includesDependencies = nil
        XCTAssertThrowsError(try decoded.validateSourceManifest(changed))
    }
    #endif
}
