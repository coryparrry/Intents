import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeDependencyBuildContextTests: XCTestCase {
    func testFlutterPathsUsePrivateSnapshotAndLeaveCapturedConfigurationUnchanged() throws {
        let root = URL(fileURLWithPath: "/private/tmp/native context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), session = root.appendingPathComponent("session")
        let project = original.appendingPathComponent("app/ios/Runner.xcodeproj")
        let config = original.appendingPathComponent("app/ios/Flutter/Generated.xcconfig")
        let package = original.appendingPathComponent("app/.dart_tool/package_config.json")
        try FileManager.default.createDirectory(at: original.appendingPathComponent("package"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sdk = root.appendingPathComponent("tool-sdk")
        let framework = sdk.appendingPathComponent("bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("Modules"), withIntermediateDirectories: true)
        try Data("framework module Flutter { export * }".utf8).write(to: framework.appendingPathComponent("Modules/module.modulemap"))
        try Data("fixture binary".utf8).write(to: framework.appendingPathComponent("Flutter"))
        let configData = Data("FLUTTER_ROOT=\(sdk.path)\nFLUTTER_APPLICATION_PATH=\(original.path)/app\nPACKAGE_CONFIG=.dart_tool/package_config.json\nFLUTTER_BUILD_NAME=1.0.0\nFLUTTER_BUILD_NUMBER=1\n".utf8)
        try configData.write(to: config)
        try JSONSerialization.data(withJSONObject: ["configVersion": 2, "packages": [["name": "example", "rootUri": "../../package", "packageUri": "lib/"], ["name": "alias", "rootUri": original.appendingPathComponent("package").absoluteString.replacingOccurrences(of: "file:///private/tmp/", with: "file:///tmp/"), "packageUri": "lib/"]]]).write(to: package)
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session, includesDependencies: true)
        let rebased = AutomationRebasedProject(session: session, relativePath: "app/ios/Runner.xcodeproj", digest: "unused")
        let capturedPackage = try Data(contentsOf: package)
        let copiedConfig = session.appendingPathComponent("source/app/ios/Flutter/Generated.xcconfig")
        let changedConfig = Data(String(decoding: configData, as: UTF8.self).replacingOccurrences(of: "FLUTTER_BUILD_NAME=1.0.0", with: "FLUTTER_BUILD_NAME=2.0.0").utf8)
        try changedConfig.write(to: copiedConfig)
        XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: "iphonesimulator")) { error in
            XCTAssertEqual(error as? AutomationContractError, .conflictingOperation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("native-build-context").path))
        try configData.write(to: copiedConfig)
        let copiedPackage = session.appendingPathComponent("source/app/.dart_tool/package_config.json")
        try Data("{}".utf8).write(to: copiedPackage)
        XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: "iphonesimulator"))
        try capturedPackage.write(to: copiedPackage)
        let context = try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: "iphonesimulator")
        XCTAssertTrue(context.arguments.contains("FLUTTER_APPLICATION_PATH=" + session.appendingPathComponent("source/app").path))
        XCTAssertTrue(context.arguments.contains("FLUTTER_BUILD_NAME=1.0.0"))
        XCTAssertTrue(context.arguments.contains("FLUTTER_BUILD_NUMBER=1"))
        XCTAssertTrue(context.arguments.contains("FRAMEWORK_SEARCH_PATHS=$(inherited) \"" + framework.deletingLastPathComponent().path + "\""))
        XCTAssertFalse(context.arguments.contains(where: { $0.hasPrefix("SUPPORTED_PLATFORMS=") }))
        let data = try Data(contentsOf: session.appendingPathComponent("native-build-context/package_config.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let packages = try XCTUnwrap(json["packages"] as? [[String: Any]])
        XCTAssertEqual(packages[0]["rootUri"] as? String, session.appendingPathComponent("source/package").absoluteString)
        XCTAssertEqual(packages[1]["rootUri"] as? String, session.appendingPathComponent("source/package").absoluteString)
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("source/app/ios/Flutter/Generated.xcconfig")), configData)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        try context.verify()
        XCTAssertEqual(try Data(contentsOf: copiedPackage), data)
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("native-build-context/captured-package_config.json")), capturedPackage)
        XCTAssertEqual(try Data(contentsOf: package), capturedPackage)
        try context.verify()
        try changedConfig.write(to: copiedConfig)
        XCTAssertThrowsError(try context.verify())
        try configData.write(to: copiedConfig)
        try Data("{}".utf8).write(to: copiedPackage)
        XCTAssertThrowsError(try context.verify())
        try data.write(to: copiedPackage)
        try Data("{}".utf8).write(to: session.appendingPathComponent("native-build-context/package_config.json"))
        XCTAssertThrowsError(try context.verify())
        try capturedPackage.write(to: copiedPackage)
        try FileManager.default.removeItem(at: session.appendingPathComponent("native-build-context"))
        XCTAssertFalse(try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: "iphoneos").arguments.contains(where: { $0.hasPrefix("FRAMEWORK_SEARCH_PATHS=") }))
        try capturedPackage.write(to: copiedPackage)
        try FileManager.default.removeItem(at: session.appendingPathComponent("native-build-context"))
        XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: "iphonesimulator", configuration: "Release")) { error in
            XCTAssertTrue(String(describing: error).contains("requires a Debug configuration"))
        }
    }

    func testFlutterPackagingArgumentsPreserveNumericVersionsAndPositiveBuildNumbers() throws {
        for name in ["1", "1.0", "1.0.0", "0.12.3"] {
            XCTAssertEqual(try AutomationNativeDependencyBuildContext.flutterPackagingArguments([
                "FLUTTER_BUILD_NAME": name, "FLUTTER_BUILD_NUMBER": "42"
            ]), ["FLUTTER_BUILD_NAME=" + name, "FLUTTER_BUILD_NUMBER=42"])
        }
    }

    func testFlutterPackagingArgumentsRejectMissingValues() throws {
        for values in [[String: String](), ["FLUTTER_BUILD_NAME": "1.0.0"], ["FLUTTER_BUILD_NUMBER": "1"]] {
            XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.flutterPackagingArguments(values))
        }
    }

    func testFlutterPackagingArgumentsRejectMalformedValues() throws {
        for name in ["", "1.0.0-beta", "1.0.0.1", "1..0", " 1.0.0", "1.0.0\n", "$(MARKETING_VERSION)", "1.0.0 OTHER_SETTING=1", String(repeating: "1", count: 65)] {
            XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.flutterPackagingArguments([
                "FLUTTER_BUILD_NAME": name, "FLUTTER_BUILD_NUMBER": "1"
            ]), name)
        }
        for number in ["", "0", "01", "-1", "1.0", " 1", "1\n", "$(CURRENT_PROJECT_VERSION)", "1 OTHER_SETTING=1", String(repeating: "1", count: 21)] {
            XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.flutterPackagingArguments([
                "FLUTTER_BUILD_NAME": "1.0.0", "FLUTTER_BUILD_NUMBER": number
            ]), number)
        }
    }

    func testNativeConfigRejectsPathsOutsideApprovedRoots() throws {
        let manifest = AutomationSourceManifest(sourceRoot: "/private/tmp/approved", files: [], directories: [], excludedPaths: [])
        XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.rebase("/private/tmp/unapproved/package", manifest: manifest, source: URL(fileURLWithPath: "/private/tmp/frozen")))
        XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.rebase("/private/tmp/approved/../escape", manifest: manifest, source: URL(fileURLWithPath: "/private/tmp/frozen")))
    }
    func testPackageURIRejectsTraversalAbsoluteAndEncodedEscapes() throws {
        try AutomationNativeDependencyBuildContext.validatePackageURI("lib/")
        try AutomationNativeDependencyBuildContext.validatePackageURI("src/public/")
        try AutomationNativeDependencyBuildContext.validatePackageURI(nil)
        for value in ["../outside/", "/private/tmp/outside/", "file:///private/tmp/outside/", "https://example.test/lib/", "%2e%2e/outside/", "%2Fprivate/tmp/", "lib\\..\\outside", "lib/?override=1"] {
            XCTAssertThrowsError(try AutomationNativeDependencyBuildContext.validatePackageURI(value), value)
        }
    }

}
