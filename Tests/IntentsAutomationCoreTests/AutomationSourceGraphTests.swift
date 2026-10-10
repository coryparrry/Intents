import XCTest
@testable import IntentsAutomationCore

final class AutomationSourceGraphTests: XCTestCase {
    private struct Fixture {
        let root: URL, session: URL, manifest: AutomationSourceManifest
        func read(configuration: String = "Debug", platformSettings: Data? = nil, resolvePackagePlatformConditions: Bool? = nil) throws -> AutomationSourceGraph {
            if let platformSettings {
                return try AutomationSourceGraphReader.read(manifest: manifest, frozenRoot: session.appendingPathComponent("source"),
                    projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: configuration,
                    projectData: Data(contentsOf: session.appendingPathComponent("source/App.xcodeproj/project.pbxproj")),
                    platformSettings: platformSettings, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), resolvePackagePlatformConditions: resolvePackagePlatformConditions)
            }
            return try AutomationSourceGraphReader.read(manifest: manifest, frozenRoot: session.appendingPathComponent("source"),
                projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: configuration)
        }
    }
    private func fixture(additionalFiles: [String: String] = [:], retainedRoot: URL? = nil, _ mutate: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> Fixture {
        let root = (retainedRoot ?? URL(fileURLWithPath: "/private/tmp")).appendingPathComponent("source-graph-" + UUID().uuidString)
        let source = root.appendingPathComponent("checkout"), session = root.appendingPathComponent("prepare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Package"), withIntermediateDirectories: true)
        if retainedRoot == nil { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        let contents = ["Sources/App.swift": "import AppIntents\nstruct Echo: AppIntent {}\nstruct Item: AppEntity {}",
                             "Sources/Library.swift": "struct Choice: AppIntents.AppEnum {}", "Sources/Unrelated.swift": "struct Ghost: AppIntent {}",
                             "Package/Package.swift": "// Frozen package manifest; never evaluated", "Package.swift": "// Root package manifest", "README.md": "Not a target member"].merging(additionalFiles) { _, new in new }
        for (path, text) in contents {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: source.appendingPathComponent(path))
        }
        var objects: [String: [String: Any]] = [
            "PROJECT": ["isa": "PBXProject", "mainGroup": "GROUP", "targets": ["APP", "LIB", "TEST"]],
            "GROUP": ["isa": "PBXGroup", "children": ["SOURCES"], "sourceTree": "<group>"],
            "SOURCES": ["isa": "PBXGroup", "path": "Sources", "children": ["APPFILE", "LIBFILE", "TESTFILE"]],
            "APPFILE": ["isa": "PBXFileReference", "path": "App.swift"], "LIBFILE": ["isa": "PBXFileReference", "path": "Library.swift"],
            "TESTFILE": ["isa": "PBXFileReference", "path": "Unrelated.swift"],
            "APP": ["isa": "PBXNativeTarget", "name": "App", "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS", "dependencies": ["DEP"], "buildPhases": ["APP_PHASE"]],
            "LIB": ["isa": "PBXNativeTarget", "name": "Library", "buildConfigurationList": "CONFIGS", "buildPhases": ["LIB_PHASE"]],
            "TEST": ["isa": "PBXNativeTarget", "name": "Unrelated", "buildConfigurationList": "CONFIGS", "buildPhases": ["TEST_PHASE"]],
            "CONFIGS": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": "Debug", "buildSettings": [:]],
            "DEP": ["isa": "PBXTargetDependency", "target": "LIB"],
            "APP_PHASE": ["isa": "PBXSourcesBuildPhase", "files": ["APP_BUILD"]],
            "LIB_PHASE": ["isa": "PBXSourcesBuildPhase", "files": ["LIB_BUILD"]],
            "TEST_PHASE": ["isa": "PBXSourcesBuildPhase", "files": ["TEST_BUILD"]],
            "APP_BUILD": ["isa": "PBXBuildFile", "fileRef": "APPFILE"], "LIB_BUILD": ["isa": "PBXBuildFile", "fileRef": "LIBFILE"], "TEST_BUILD": ["fileRef": "TESTFILE"]]
        mutate(&objects)
        try PropertyListSerialization.data(fromPropertyList: ["rootObject": "PROJECT", "objects": objects], format: .xml, options: 0)
            .write(to: source.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        return .init(root: root, session: session, manifest: try AutomationSourceSnapshot.capture(source: source, sessionRoot: session))
    }

    private func platformSettings(_ fixture: Fixture, platform: String, mutate: (inout [String: String]) -> Void = { _ in }) throws -> Data {
        var settings = ["TARGET_NAME": "App", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": fixture.session.appendingPathComponent("source/App.xcodeproj").path,
            "PLATFORM_NAME": platform, "SDKROOT": platform, "SUPPORTED_PLATFORMS": platform, "SUPPORTS_MACCATALYST": "NO"]
        mutate(&settings)
        return try JSONSerialization.data(withJSONObject: [["target": "App", "buildSettings": settings]], options: [.sortedKeys])
    }
    private func platformFixture(_ mutate: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> Fixture {
        try fixture(additionalFiles: ["Sources/Mac.swift": "struct MacOnly: AppIntent {}\n"]) { objects in
            objects["SOURCES"]?["children"] = ["APPFILE", "LIBFILE", "TESTFILE", "MACFILE"]
            objects["MACFILE"] = ["isa": "PBXFileReference", "path": "Mac.swift"]
            objects["MAC_BUILD"] = ["isa": "PBXBuildFile", "fileRef": "MACFILE", "platformFilter": "macos"]
            objects["APP_PHASE"]?["files"] = ["APP_BUILD", "MAC_BUILD"]
            objects["APP_BUILD"]?["platformFilters"] = ["ios"]
            mutate(&objects)
        }
    }
    func testObservedPlatformFiltersRetainOnlyActiveSelectedTargetDeclarations() throws {
        let fixture = try platformFixture()
        let iosSettings = try platformSettings(fixture, platform: "iphonesimulator")
        let ios = try fixture.read(platformSettings: iosSettings)
        let mac = try fixture.read(platformSettings: platformSettings(fixture, platform: "macosx"))
        XCTAssertEqual(ios.inputs.first { $0.relativePath == "Sources/App.swift" }?.role, "explicitSwiftMembership")
        XCTAssertEqual(ios.inputs.first { $0.relativePath == "Sources/Mac.swift" }?.role, "inactiveSwiftMembership")
        XCTAssertEqual(mac.inputs.first { $0.relativePath == "Sources/App.swift" }?.role, "inactiveSwiftMembership")
        XCTAssertEqual(mac.inputs.first { $0.relativePath == "Sources/Mac.swift" }?.role, "explicitSwiftMembership")
        XCTAssertTrue(ios.declarations.contains { $0.name == "Echo" }); XCTAssertFalse(ios.declarations.contains { $0.name == "MacOnly" })
        XCTAssertTrue(mac.declarations.contains { $0.name == "MacOnly" }); XCTAssertFalse(mac.declarations.contains { $0.name == "Echo" })
        XCTAssertEqual(ios.coverage, "partial"); XCTAssertEqual(mac.coverage, "partial")
        XCTAssertEqual(ios.platformContext?.settingsSHA256, AutomationArtifactRegistry.digest(iosSettings))
        XCTAssertNotEqual(try ios.digest, try mac.digest)
        XCTAssertEqual(ios, try fixture.read(platformSettings: iosSettings))
        let legacy = try fixture.read()
        XCTAssertNil(legacy.platformContext)
        XCTAssertFalse(legacy.declarations.contains { $0.name == "Echo" || $0.name == "MacOnly" })
        XCTAssertEqual(try JSONDecoder().decode(AutomationSourceGraph.self, from: JSONEncoder().encode(legacy)), legacy)
    }
    func testMalformedConflictingFiltersAndDependencyPlatformsRemainUnresolved() throws {
        let badFilters: [[String: Any]] = [
            ["platformFilters": []], ["platformFilters": ["ios", "ios"]], ["platformFilters": ["ios", "futureOS"]],
            ["platformFilters": [1]], ["platformFilters": "ios"], ["platformFilter": 1],
            ["platformFilter": "ios", "platformFilters": ["ios"]]]
        for bad in badFilters {
            let fixture = try platformFixture { objects in
                objects["APP_BUILD"] = ["isa": "PBXBuildFile", "fileRef": "APPFILE"].merging(bad) { _, new in new }
            }
            let graph = try fixture.read(platformSettings: platformSettings(fixture, platform: "iphoneos"))
            XCTAssertEqual(graph.inputs.first { $0.relativePath == "Sources/App.swift" }?.role, "unresolvedSwiftMembership")
            XCTAssertFalse(graph.declarations.contains { $0.name == "Echo" })
        }
        let fixture = try platformFixture { objects in
            objects["LIB_BUILD"]?["platformFilters"] = ["ios"]
            objects["APP_BUILD"]?["settings"] = ["COMPILER_FLAGS": "-D CUSTOM"]
        }
        let graph = try fixture.read(platformSettings: platformSettings(fixture, platform: "iphoneos"))
        XCTAssertEqual(graph.inputs.first { $0.relativePath == "Sources/Library.swift" }?.role, "unresolvedSwiftMembership")
        XCTAssertEqual(graph.inputs.first { $0.relativePath == "Sources/App.swift" }?.role, "unresolvedSwiftMembership")
    }
    func testForeignPlatformSettingsAndUnresolvedCatalystCannotResolveMembership() throws {
        let fixture = try platformFixture()
        for (key, value) in [("PROJECT_FILE_PATH", "/foreign/App.xcodeproj"), ("CONFIGURATION", "Release"),
            ("TARGET_NAME", "Foreign"), ("SUPPORTED_PLATFORMS", "iphoneos macosx"), ("PLATFORM_NAME", "unknown")] {
            let data = try platformSettings(fixture, platform: "iphoneos") { $0[key] = value }
            XCTAssertThrowsError(try fixture.read(platformSettings: data))
        }
        for (key, value) in [("SUPPORTS_MACCATALYST", "YES"), ("SDK_VARIANT", "macabi"), ("EFFECTIVE_PLATFORM_NAME", "-maccatalyst")] {
            let data = try platformSettings(fixture, platform: "macosx") { $0[key] = value }
            let graph = try fixture.read(platformSettings: data)
            XCTAssertNil(graph.platformContext?.filterFamily)
            XCTAssertFalse(graph.declarations.contains { $0.name == "Echo" || $0.name == "MacOnly" })
        }
        for platform in ["iphoneos", "iphonesimulator", "appletvos", "appletvsimulator", "watchos", "watchsimulator", "xros", "xrsimulator"] {
            for (key, value) in [("SDK_VARIANT", "macabi"), ("SDK_VARIANT", "unknown"), ("EFFECTIVE_PLATFORM_NAME", "-maccatalyst"), ("EFFECTIVE_PLATFORM_NAME", "-unknown")] {
                let data = try platformSettings(fixture, platform: platform) { $0[key] = value }
                let graph = try fixture.read(platformSettings: data)
                XCTAssertNil(graph.platformContext?.filterFamily)
                XCTAssertFalse(graph.declarations.contains { $0.name == "Echo" || $0.name == "MacOnly" })
            }
        }
        let actualIOS = try platformSettings(fixture, platform: "iphonesimulator") {
            $0["SUPPORTS_MACCATALYST"] = "YES"; $0["EFFECTIVE_PLATFORM_NAME"] = "-iphonesimulator"
        }
        XCTAssertEqual(try fixture.read(platformSettings: actualIOS).platformContext?.filterFamily, "ios")
        let changed = try platformSettings(fixture, platform: "iphoneos") { $0["CUSTOM_FACT"] = "changed" }
        XCTAssertNotEqual(try fixture.read(platformSettings: changed).digest, try fixture.read(platformSettings: platformSettings(fixture, platform: "iphoneos")).digest)
    }
    #if os(macOS)
    func testSavedPlatformMembershipReplaysRawSettingsAndRejectsDriftOrMissingEvidence() throws {
        let fixture = try platformFixture()
        let settings = try platformSettings(fixture, platform: "macosx"), graph = try fixture.read(platformSettings: settings)
        let product = fixture.session.appendingPathComponent("DerivedData/Subject.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        var app = AppIdentity(logicalID: fixture.manifest.sourceRoot + "/App.xcodeproj#APP", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = product.path; app.configuration = "Debug"; app.sourceManifestDigest = try fixture.manifest.digest; app.owningModule = "App"
        let action = ApplicationSurfaceCatalog.SystemAction(id: "MacOnly", typeName: "App.MacOnly", title: "Mac", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
        let catalog = try AutomationSourceCatalogReconciliation.apply(graph, to: .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []))
        let prepared = AutomationPreparedApplication(source: fixture.manifest,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "b", count: 64)),
            host: .init(app: app, target: .init(id: UUID().uuidString, kind: .nativeMac), xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: product.path, hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: catalog, buildLogPath: "unused", buildLogTruncated: false, sourceGraph: graph)
        func write(_ data: Data, _ name: String) throws {
            let file = fixture.session.appendingPathComponent(name)
            try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try write(JSONEncoder().encode(prepared), "prepared-application.json")
        try write(Data(contentsOf: fixture.session.appendingPathComponent("source/App.xcodeproj/project.pbxproj")), "source-graph-project.pbxproj")
        try write(settings, "source-compilation-settings.json")
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        for version in [2, 1] {
            var altered = prepared
            altered.sourceGraph?.packagePlatformConditionVersion = version
            if version == 1 { altered.sourceGraph?.platformContext = nil }
            altered.catalog.sourceGraphDigest = try altered.sourceGraph?.digest
            try write(JSONEncoder().encode(altered), "prepared-application.json")
            XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        }
        var legacy = prepared
        legacy.sourceGraph = try fixture.read(platformSettings: settings, resolvePackagePlatformConditions: false)
        legacy.catalog = try AutomationSourceCatalogReconciliation.apply(XCTUnwrap(legacy.sourceGraph), to: .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []))
        try write(JSONEncoder().encode(legacy), "prepared-application.json")
        XCTAssertNil(legacy.sourceGraph?.packagePlatformConditionVersion)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), legacy)
        try write(JSONEncoder().encode(prepared), "prepared-application.json")
        try write(platformSettings(fixture, platform: "iphoneos"), "source-compilation-settings.json")
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        try write(settings, "source-compilation-settings.json")
        try Data("working project was expanded by host generation".utf8).write(to: fixture.session.appendingPathComponent("source/App.xcodeproj/project.pbxproj"))
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("source-compilation-settings.json"))
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
    }
    #endif

    func testSelectedMembershipAndTransitiveCycleRemainSnapshotBoundAndPartial() throws {
        let fixture = try fixture { objects in
            objects["LIB"]?["dependencies"] = ["BACK"]
            objects["BACK"] = ["target": "APP"]
        }
        let graph = try fixture.read()
        XCTAssertEqual(graph.nodes.map(\.name), ["App", "Library"])
        XCTAssertEqual(graph.inputs.map(\.relativePath), ["Sources/App.swift", "Sources/Library.swift"])
        XCTAssertEqual(graph.declarations.map(\.name), ["Echo", "Item", "Choice"])
        XCTAssertEqual(graph.sourceManifestDigest, try fixture.manifest.digest)
        XCTAssertEqual(graph.coverage, "partial"); XCTAssertFalse(graph.gaps.isEmpty)
        XCTAssertEqual(graph, try fixture.read()); XCTAssertEqual(try graph.digest, try graph.digest)
        XCTAssertThrowsError(try fixture.read(configuration: "Release"))
    }
    func testScriptsPackagesConditionalAndSynchronizedInputsAreVisibleGaps() throws {
        let graph = try fixture { objects in
            objects["APP"]?["buildPhases"] = ["APP_PHASE", "SCRIPT"]
            objects["APP"]?["packageProductDependencies"] = ["LOCAL_PRODUCT", "REMOTE_PRODUCT"]
            objects["APP"]?["fileSystemSynchronizedGroups"] = ["SYNC"]
            objects["APP_BUILD"]?["platformFilters"] = ["ios"]
            objects["SCRIPT"] = ["isa": "PBXShellScriptBuildPhase", "shellScript": "echo do-not-run"]
            objects["LOCAL_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Local", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"]
            objects["REMOTE_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Remote", "package": "REMOTE"]
            objects["REMOTE"] = ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://example.invalid/never-fetch"]
        }.read()
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Package/Package.swift" && $0.role == "packageManifest" })
        for word in ["Script", "Conditional", "Synchronized", "Remote", "Local package"] { XCTAssertTrue(graph.gaps.contains { $0.contains(word) }, word) }
        XCTAssertFalse(graph.declarations.contains { $0.name == "Ghost" })
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Sources/App.swift" && $0.role == "unresolvedSwiftMembership" })
        XCTAssertFalse(graph.declarations.contains { $0.relativePath == "Sources/App.swift" })
    }
    func testChangedFrozenSourceAndProjectAreRejected() throws {
        let fixture = try fixture()
        let source = fixture.session.appendingPathComponent("source/Sources/App.swift")
        try Data("struct Injected: AppIntent {}".utf8).write(to: source)
        XCTAssertThrowsError(try fixture.read())
        try Data("changed".utf8).write(to: fixture.session.appendingPathComponent("source/App.xcodeproj/project.pbxproj"))
        XCTAssertThrowsError(try fixture.read())
    }
    func testInheritedProjectAndXCConfigMembershipCannotBecomeDeclarationCandidates() throws {
        let inherited = try fixture { objects in
            objects["PROJECT"]?["buildConfigurationList"] = "PROJECT_CONFIGS"
            objects["PROJECT_CONFIGS"] = ["buildConfigurations": ["PROJECT_DEBUG"]]
            objects["PROJECT_DEBUG"] = ["name": "Debug", "buildSettings": ["EXCLUDED_SOURCE_FILE_NAMES": "App.swift"]]
        }.read()
        XCTAssertTrue(inherited.inputs.contains { $0.role == "unresolvedSwiftMembership" && $0.relativePath == "Sources/App.swift" })
        XCTAssertFalse(inherited.declarations.contains { $0.name == "Echo" })
        for configuration in ["DEBUG", "PROJECT_DEBUG"] {
            let graph = try fixture(additionalFiles: ["Membership.xcconfig": "EXCLUDED_SOURCE_FILE_NAMES = App.swift"]) { objects in
                objects["GROUP"]?["children"] = ["SOURCES", "CONFIGFILE"]
                objects["CONFIGFILE"] = ["isa": "PBXFileReference", "path": "Membership.xcconfig"]
                objects["PROJECT"]?["buildConfigurationList"] = "PROJECT_CONFIGS"
                objects["PROJECT_CONFIGS"] = ["buildConfigurations": ["PROJECT_DEBUG"]]
                objects["PROJECT_DEBUG"] = ["name": "Debug", "buildSettings": [:]]
                objects[configuration]?["baseConfigurationReference"] = "CONFIGFILE"
            }.read()
            XCTAssertTrue(graph.inputs.contains { $0.role == "buildConfiguration" && $0.relativePath == "Membership.xcconfig" })
            XCTAssertFalse(graph.declarations.contains { $0.name == "Echo" })
            XCTAssertTrue(graph.gaps.contains { $0.contains("xcconfig") })
        }
    }
    func testRootLocalPackageManifestIsIncludedWithoutEvaluation() throws {
        let graph = try fixture { objects in
            objects["APP"]?["packageProductDependencies"] = ["PRODUCT"]
            objects["PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Root", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "."]
        }.read()
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Package.swift" && $0.role == "packageManifest" })
        XCTAssertFalse(graph.gaps.contains { $0.contains("External package root") })
    }
    private var remoteResolution: String {
        "{\"version\":3,\"originHash\":\"" + String(repeating: "b", count: 64) + "\",\"pins\":[{\"identity\":\"remote\",\"kind\":\"remoteSourceControl\",\"location\":\"https://example.invalid/Remote.git\",\"state\":{\"revision\":\"" + String(repeating: "a", count: 40) + "\",\"version\":\"1.2.3\"}}]}"
    }
    private func remoteFixture(resolution: String? = nil, location: String = "https://example.invalid/Remote.git", requirement: [String: String] = ["kind": "exactVersion", "version": "1.2.3"], appName: String = "App") throws -> Fixture {
        try fixture(additionalFiles: ["App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": resolution ?? remoteResolution]) { objects in
            objects["APP"]?["name"] = appName
            objects["APP"]?["packageProductDependencies"] = ["REMOTE_PRODUCT"]
            objects["REMOTE_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Remote", "package": "REMOTE"]
            objects["REMOTE"] = ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": location, "requirement": requirement]
        }
    }
    func testCapturedRemotePinsBindExactFrozenFileAndDeclaredRequirementWithoutCheckoutClaims() throws {
        let fixture = try remoteFixture(), graph = try fixture.read()
        let pin = try XCTUnwrap(graph.packagePins?.first)
        XCTAssertEqual(pin.identity, "remote"); XCTAssertEqual(pin.requirementState, "satisfied")
        XCTAssertEqual(pin.resolutionDigest, graph.inputs.first { $0.role == "packageResolution" }?.sha256)
        XCTAssertTrue(graph.gaps.contains { $0.contains("actual build consumption") }); XCTAssertEqual(graph.coverage, "partial")
        XCTAssertFalse(graph.inputs.contains { $0.role == "packageSwiftMembership" })
        XCTAssertEqual(graph, try fixture.read())
        XCTAssertEqual(try remoteFixture(requirement: ["kind": "exactVersion", "version": "9.0.0"]).read().packagePins?.first?.requirementState, "mismatch")
        XCTAssertEqual(try remoteFixture(requirement: ["kind": "upToNextMajorVersion", "minimumVersion": "1.0.0"]).read().packagePins?.first?.requirementState, "unresolved")
        try Data("{}".utf8).write(to: fixture.session.appendingPathComponent("source/" + pin.resolutionPath))
        XCTAssertThrowsError(try fixture.read())
    }
    func testUnmatchedMalformedAndCredentialLocationsCannotBecomeRemotePinClaims() throws {
        let composed = "https://example.invalid/Caf\u{00e9}/Remote.git", decomposed = "https://example.invalid/Cafe\u{0301}/Remote.git"
        XCTAssertEqual(composed, decomposed)
        let unicodeResolution = remoteResolution.replacingOccurrences(of: "https://example.invalid/Remote.git", with: composed)
        XCTAssertNil(try remoteFixture(resolution: unicodeResolution, location: decomposed).read().packagePins)
        XCTAssertEqual(try remoteFixture(resolution: unicodeResolution, location: composed).read().packagePins?.first?.location.utf8.map { $0 }, Array(composed.utf8))
        for graph in [try remoteFixture(resolution: "{}").read(), try remoteFixture(location: "https://foreign.invalid/Remote.git").read(),
                      try remoteFixture(location: "https://credential@example.invalid/Remote.git").read()] {
            XCTAssertNil(graph.packagePins); XCTAssertFalse(graph.gaps.isEmpty)
        }
        let old = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [], inputs: [], declarations: [], gaps: [])
        XCTAssertNil(try JSONDecoder().decode(AutomationSourceGraph.self, from: JSONEncoder().encode(old)).packagePins)
    }
    private let literalPackage = """
    import PackageDescription
    let package = Package(name: "Local", products: [.library(name: "Local", targets: ["Main"])], targets: [
        .target(name: "Main", dependencies: ["Shared"], path: "Code", exclude: ["Nested/Excluded.swift"], sources: ["Main.swift", "Nested"]),
        .target(name: "Shared", dependencies: ["Main"], path: "Shared"),
        .target(name: "Unreachable", path: "Unused")
    ])
    """
    private func packageFixture(manifest: String? = nil, extraFiles: [String: String] = [:], references: Int = 1) throws -> Fixture {
        try fixture(additionalFiles: ["Package/Package.swift": manifest ?? literalPackage,
            "Package/Code/Main.swift": "struct PackageAction: AppIntent {}",
            "Package/Code/Nested/Included.swift": "struct Included: AppEntity {}",
            "Package/Code/Nested/Excluded.swift": "struct Excluded: AppIntent {}",
            "Package/Code/Other.swift": "struct Unselected: AppIntent {}",
            "Package/Shared/Shared.swift": "struct Shared: AppEnum {}", "Package/Unused/Unused.swift": "struct Unreachable: AppIntent {}"].merging(extraFiles) { _, new in new })
        { objects in
            objects["APP"]?["packageProductDependencies"] = Array(repeating: "LOCAL_PRODUCT", count: references)
            objects["LOCAL_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Local", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"]
        }
    }

    func testLiteralPackagePlatformTargetEdgesUseSelectedDestinationAndRemainPartial() throws {
        let manifest = "import PackageDescription\nlet package = Package(name: \"Local\", products: [.library(name: \"Local\", targets: [\"Main\"])], targets: [.target(name: \"Main\", dependencies: [.target(name: \"MacOnly\", condition: .when(platforms: [.macOS])), .target(name: \"IOSOnly\", condition: .when(platforms: [.iOS]))], path: \"Code\", sources: [\"Main.swift\"]), .target(name: \"MacOnly\"), .target(name: \"IOSOnly\")])"
        let fixture = try packageFixture(manifest: manifest, extraFiles: ["Package/Sources/MacOnly/Mac.swift": "struct MacPackageAction: AppIntent {}", "Package/Sources/IOSOnly/IOS.swift": "struct IOSPackageAction: AppIntent {}"])
        let macSettings = try platformSettings(fixture, platform: "macosx")
        let mac = try fixture.read(platformSettings: macSettings)
        let ios = try fixture.read(platformSettings: platformSettings(fixture, platform: "iphonesimulator"))
        XCTAssertTrue(mac.declarations.contains { $0.name == "MacPackageAction" }); XCTAssertFalse(mac.declarations.contains { $0.name == "IOSPackageAction" })
        XCTAssertTrue(ios.declarations.contains { $0.name == "IOSPackageAction" }); XCTAssertFalse(ios.declarations.contains { $0.name == "MacPackageAction" })
        XCTAssertEqual(mac.packagePlatformConditionVersion, 1); XCTAssertEqual(mac.coverage, "partial")
        XCTAssertTrue(mac.gaps.contains { $0.contains("compiler") || $0.contains("Compiler") })
        let unknown = try fixture.read()
        XCTAssertFalse(unknown.declarations.contains { $0.name == "MacPackageAction" || $0.name == "IOSPackageAction" })
        XCTAssertTrue(unknown.gaps.contains { $0.contains("Conditional target") })
        let ambiguous = try fixture.read(platformSettings: platformSettings(fixture, platform: "macosx") { $0["SUPPORTS_MACCATALYST"] = "YES" })
        XCTAssertFalse(ambiguous.declarations.contains { $0.name == "MacPackageAction" || $0.name == "IOSPackageAction" })
        let legacy = try fixture.read(platformSettings: macSettings, resolvePackagePlatformConditions: false)
        XCTAssertNil(legacy.packagePlatformConditionVersion)
        XCTAssertFalse(legacy.declarations.contains { $0.name == "MacPackageAction" || $0.name == "IOSPackageAction" })
        XCTAssertTrue(legacy.gaps.contains { $0.contains("Conditional target") })
        XCTAssertNotEqual(try legacy.digest, try mac.digest)
        XCTAssertEqual(legacy, try fixture.read(platformSettings: macSettings, resolvePackagePlatformConditions: false))
    }
    func testTransitivePlatformProductConditionsSkipInactiveAndPreserveOpaqueHostTargetGaps() throws {
        let conditional = transitivePackage.replacingOccurrences(of: "package: \"leaf\")", with: "package: \"leaf\", condition: .when(platforms: [.macOS]))")
        let fixture = try transitiveFixture(root: conditional)
        let mac = try fixture.read(platformSettings: platformSettings(fixture, platform: "macosx"))
        let ios = try fixture.read(platformSettings: platformSettings(fixture, platform: "iphoneos"))
        XCTAssertTrue(mac.inputs.contains { $0.relativePath == "Leaf/Sources/Leaf/Leaf.swift" })
        XCTAssertTrue(mac.inputs.contains { $0.relativePath == "Deep/Sources/Deep/Deep.swift" })
        XCTAssertFalse(ios.inputs.contains { $0.relativePath.hasPrefix("Leaf/") || $0.relativePath.hasPrefix("Deep/") })
        XCTAssertEqual(mac, try fixture.read(platformSettings: platformSettings(fixture, platform: "macosx")))
        for condition in [".when(configuration: .debug)", ".when(platforms: [.futureOS])", ".when(platforms: [.macOS], traits: [\"opaque\"])"] {
            let root = transitivePackage.replacingOccurrences(of: "package: \"leaf\")", with: "package: \"leaf\", condition: " + condition + ")")
            let fixture = try transitiveFixture(root: root)
            let graph = try fixture.read(platformSettings: platformSettings(fixture, platform: "macosx"))
            XCTAssertFalse(graph.inputs.contains { $0.relativePath.hasPrefix("Leaf/") })
            XCTAssertTrue(graph.gaps.contains { $0.contains("Conditional") })
        }
        let macro = "import PackageDescription\nlet package = Package(name: \"Local\", products: [.library(name: \"Local\", targets: [\"Main\"])], targets: [.macro(name: \"Main\", dependencies: [.target(name: \"HostHelper\", condition: .when(platforms: [.macOS]))]), .target(name: \"HostHelper\")])"
        let host = try packageFixture(manifest: macro, extraFiles: ["Package/Sources/HostHelper/Helper.swift": "struct HostOnly: AppIntent {}"])
        let graph = try host.read(platformSettings: platformSettings(host, platform: "macosx"))
        XCTAssertFalse(graph.declarations.contains { $0.name == "HostOnly" })
        XCTAssertTrue(graph.gaps.contains { $0.contains("Target kind") })
    }

    func testOpaqueHostClosuresCannotBorrowDestinationOrPoisonRuntimeHelpers() throws {
        let helper = ".target(name: \"HostHelper\", dependencies: [.target(name: \"IOSOnly\", condition: .when(platforms: [.iOS])), .target(name: \"MacOnly\", condition: .when(platforms: [.macOS]))]), .target(name: \"IOSOnly\"), .target(name: \"MacOnly\")"
        let files = ["Package/Sources/HostHelper/Helper.swift": "struct HelperAction: AppIntent {}", "Package/Sources/IOSOnly/IOS.swift": "struct IOSAction: AppIntent {}", "Package/Sources/MacOnly/Mac.swift": "struct MacAction: AppIntent {}"]
        for kind in ["macro", "plugin", "testTarget"] {
            let manifest = "import PackageDescription\nlet package = Package(name: \"Local\", products: [.library(name: \"Local\", targets: [\"Main\"])], targets: [." + kind + "(name: \"Main\", dependencies: [\"HostHelper\"]), " + helper + "])"
            let fixture = try packageFixture(manifest: manifest, extraFiles: files)
            for platform in ["macosx", "iphoneos"] {
                let graph = try fixture.read(platformSettings: platformSettings(fixture, platform: platform))
                XCTAssertFalse(graph.nodes.contains { $0.name == "HostHelper" || $0.name == "IOSOnly" || $0.name == "MacOnly" })
                XCTAssertTrue(graph.gaps.contains { $0.contains("Target kind") })
            }
            let legacy = try fixture.read(platformSettings: platformSettings(fixture, platform: "iphoneos"), resolvePackagePlatformConditions: false)
            XCTAssertTrue(legacy.nodes.contains { $0.name == "HostHelper" })
        }
        let runtime = "import PackageDescription\nlet package = Package(name: \"Local\", products: [.library(name: \"Local\", targets: [\"Main\"])], targets: [.target(name: \"Main\", dependencies: [\"Macro\", \"HostHelper\"], path: \"Code\", sources: [\"Main.swift\"]), .macro(name: \"Macro\", dependencies: [\"HostHelper\"]), " + helper + "])"
        let fixture = try packageFixture(manifest: runtime, extraFiles: files)
        for (platform, included, excluded) in [("macosx", "MacAction", "IOSAction"), ("iphoneos", "IOSAction", "MacAction")] {
            let graph = try fixture.read(platformSettings: platformSettings(fixture, platform: platform))
            XCTAssertTrue(graph.declarations.contains { $0.name == "HelperAction" })
            XCTAssertTrue(graph.declarations.contains { $0.name == included })
            XCTAssertFalse(graph.declarations.contains { $0.name == excluded })
        }
        let hostProduct = transitivePackage.replacingOccurrences(of: ".target(name: \"Main\"", with: ".macro(name: \"Main\"")
        let host = try transitiveFixture(root: hostProduct)
        let graph = try host.read(platformSettings: platformSettings(host, platform: "macosx"))
        XCTAssertFalse(graph.inputs.contains { $0.relativePath.hasPrefix("Leaf/") || $0.relativePath.hasPrefix("Deep/") })
        XCTAssertTrue(graph.gaps.contains { $0.contains("Target kind") })
    }

    func testDependencyXcodeTargetPackageClosureCannotBorrowSelectedSettings() throws {
        let package = literalPackage.replacingOccurrences(of: "dependencies: [\"Shared\"]", with: "dependencies: [.target(name: \"Shared\", condition: .when(platforms: [.macOS]))]")
        let fixture = try fixture(additionalFiles: ["Package/Package.swift": package, "Package/Code/Main.swift": "struct DependencyAction: AppIntent {}", "Package/Shared/Shared.swift": "struct DependencyHelper: AppIntent {}"]) { objects in
            objects["LIB"]?["packageProductDependencies"] = ["LOCAL_PRODUCT"]
            objects["LOCAL_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Local", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"]
        }
        let settings = try platformSettings(fixture, platform: "macosx")
        let graph = try fixture.read(platformSettings: settings)
        XCTAssertFalse(graph.declarations.contains { $0.name == "DependencyAction" || $0.name == "DependencyHelper" })
        XCTAssertTrue(graph.gaps.contains { $0.contains("Package destination is unresolved for dependency target") })
        let legacy = try fixture.read(platformSettings: settings, resolvePackagePlatformConditions: false)
        XCTAssertTrue(legacy.declarations.contains { $0.name == "DependencyAction" })
    }

    func testLiteralPackageClosureUsesFrozenMembershipAndExcludesUnreachableTargets() throws {
        let fixture = try packageFixture(), graph = try fixture.read()
        XCTAssertEqual(graph.nodes.filter { $0.kind == "localPackageTarget" }.map(\.name), ["Main", "Shared"])
        XCTAssertEqual(graph.inputs.filter { $0.role == "packageSwiftMembership" }.map(\.relativePath),
            ["Package/Code/Main.swift", "Package/Code/Nested/Included.swift", "Package/Shared/Shared.swift"])
        XCTAssertEqual(graph.declarations.filter { $0.owner.hasPrefix("Package/") }.map(\.name), ["PackageAction", "Included", "Shared"])
        XCTAssertFalse(graph.declarations.contains { ["Excluded", "Unselected", "Unreachable"].contains($0.name) })
        XCTAssertEqual(graph.coverage, "partial"); XCTAssertEqual(graph, try fixture.read())
        let member = fixture.session.appendingPathComponent("source/Package/Code/Main.swift")
        try Data("struct Forged: AppIntent {}".utf8).write(to: member)
        XCTAssertThrowsError(try fixture.read())
    }
    private var transitivePackage: String {
        literalPackage.replacingOccurrences(of: "])], targets:", with: "])], dependencies: [.package(path: \"../Leaf\")], targets:")
            .replacingOccurrences(of: "dependencies: [\"Shared\"]", with: "dependencies: [\"Shared\", .product(name: \"LeafProduct\", package: \"leaf\")]")
    }
    private var leafPackage: String {
        "import PackageDescription\nlet package = Package(name: \"Leaf\", products: [.library(name: \"LeafProduct\", targets: [\"Leaf\"])], dependencies: [.package(path: \"../Deep\")], targets: [.target(name: \"Leaf\", dependencies: [.product(name: \"DeepProduct\", package: \"deep\")]), .target(name: \"Unused\")])"
    }
    private func transitiveFixture(root: String? = nil, leaf: String? = nil, extra: [String: String] = [:]) throws -> Fixture {
        try packageFixture(manifest: root ?? transitivePackage, extraFiles: [
            "Leaf/Package.swift": leaf ?? leafPackage,
            "Leaf/Sources/Leaf/Leaf.swift": "struct LeafAction: AppIntent {}",
            "Leaf/Sources/Unused/Unused.swift": "struct UnreachableLeaf: AppIntent {}",
            "Deep/Package.swift": "import PackageDescription\nlet package = Package(name: \"Deep\", products: [.library(name: \"DeepProduct\", targets: [\"Deep\"])], targets: [.target(name: \"Deep\")])",
            "Deep/Sources/Deep/Deep.swift": "struct DeepAction: AppIntent {}"
        ].merging(extra) { _, new in new })
    }
    func testTransitiveLiteralLocalProductsRetainExactManifestsAndSelectedMembers() throws {
        let fixture = try transitiveFixture(), graph = try fixture.read()
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Leaf/Package.swift" && $0.role == "packageManifest" })
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Deep/Package.swift" && $0.role == "packageManifest" })
        XCTAssertEqual(graph.inputs.filter { $0.role == "packageSwiftMembership" && !$0.relativePath.hasPrefix("Package/") }.map(\.relativePath),
            ["Deep/Sources/Deep/Deep.swift", "Leaf/Sources/Leaf/Leaf.swift"])
        XCTAssertTrue(graph.declarations.contains { $0.name == "DeepAction" && $0.owner == "Deep/Package.swift#target:Deep" })
        XCTAssertFalse(graph.declarations.contains { $0.name == "UnreachableLeaf" })
        XCTAssertEqual(graph.coverage, "partial"); XCTAssertEqual(graph, try fixture.read())
        try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
        let retained = fixture.session.appendingPathComponent("source/Deep/Package.swift")
        try Data("// changed retained dependency".utf8).write(to: retained)
        XCTAssertThrowsError(try fixture.read())
    }
    func testAmbiguousRemoteConditionalOpaqueAndEscapingLocalDependenciesStayGaps() throws {
        let path = ".package(path: \"../Leaf\")"
        let manifests = [
            transitivePackage.replacingOccurrences(of: path, with: path + ", " + path),
            transitivePackage.replacingOccurrences(of: path, with: path + ", .package(path: \"../Other/Leaf\")"),
            transitivePackage.replacingOccurrences(of: path, with: path + ", .package(url: \"https://example.invalid/Leaf.git\", from: \"1.0.0\")"),
            transitivePackage.replacingOccurrences(of: path, with: path + ", .package(id: \"opaque.package\", from: \"1.0.0\")"),
            transitivePackage.replacingOccurrences(of: "../Leaf", with: "../../outside/Leaf"),
            transitivePackage.replacingOccurrences(of: "../Leaf", with: "/outside/Leaf"),
            transitivePackage.replacingOccurrences(of: "package: \"leaf\")", with: "package: \"leaf\", condition: .when(platforms: [.macOS]))"),
            transitivePackage + "\npackage.dependencies.removeAll()"
        ]
        for root in manifests {
            let graph = try transitiveFixture(root: root).read()
            XCTAssertFalse(graph.inputs.contains { $0.relativePath == "Leaf/Sources/Leaf/Leaf.swift" })
            XCTAssertFalse(graph.gaps.isEmpty); XCTAssertEqual(graph.coverage, "partial")
        }
        let absent = try packageFixture(manifest: transitivePackage).read()
        XCTAssertFalse(absent.inputs.contains { $0.relativePath == "Leaf/Package.swift" })
        XCTAssertTrue(absent.gaps.contains { $0.contains("absent") })
    }
    func testLocalDependencyAliasesAndCyclesRemainBoundedAndExact() throws {
        let root = transitivePackage.replacingOccurrences(of: ".package(path: \"../Leaf\")", with: ".package(name: \"Alias\", path: \"../Leaf\")")
            .replacingOccurrences(of: "package: \"leaf\"", with: "package: \"Alias\"")
        XCTAssertTrue(try transitiveFixture(root: root).read().inputs.contains { $0.relativePath == "Leaf/Sources/Leaf/Leaf.swift" })
        let mismatch = root.replacingOccurrences(of: "package: \"Alias\"", with: "package: \"alias\"")
        XCTAssertFalse(try transitiveFixture(root: mismatch).read().inputs.contains { $0.relativePath == "Leaf/Sources/Leaf/Leaf.swift" })
        let cycle = leafPackage.replacingOccurrences(of: "../Deep", with: "../Package")
            .replacingOccurrences(of: "name: \"DeepProduct\", package: \"deep\"", with: "name: \"Local\", package: \"package\"")
        let graph = try transitiveFixture(leaf: cycle).read()
        XCTAssertTrue(graph.gaps.contains { $0.contains("product cycle") })
        XCTAssertEqual(graph.nodes.filter { $0.kind == "localPackageTarget" && $0.name == "Main" }.count, 1)
        let sharedProductRoot = transitivePackage
            .replacingOccurrences(of: ".library(name: \"Local\", targets: [\"Main\"])", with: ".library(name: \"Local\", targets: [\"Main\"]), .library(name: \"Alternate\", targets: [\"Main\"])")
            .replacingOccurrences(of: ".target(name: \"Shared\", dependencies: [\"Main\"]", with: ".target(name: \"Shared\", dependencies: []")
        let alternate = cycle.replacingOccurrences(of: "name: \"Local\", package: \"package\"", with: "name: \"Alternate\", package: \"package\"")
        let sharedGraph = try transitiveFixture(root: sharedProductRoot, leaf: alternate).read()
        XCTAssertTrue(sharedGraph.gaps.contains { $0 == "Local package target cycle at Package/Package.swift#target:Main" })
    }
    func testTransitiveLocalProductDepthBudgetAndFrozenLinkAreEnforced() throws {
        var extra: [String: String] = [:]
        for index in 0..<66 {
            extra["P\(index)/Package.swift"] = "import PackageDescription\nlet package = Package(name: \"P\(index)\", products: [.library(name: \"LeafProduct\", targets: [\"Leaf\"])], dependencies: [.package(path: \"../P\(index + 1)\")], targets: [.target(name: \"Leaf\", dependencies: [.product(name: \"LeafProduct\", package: \"p\(index + 1)\")])])"
            extra["P\(index)/Sources/Leaf/Leaf.swift"] = "struct P\(index): AppIntent {}"
        }
        let root = transitivePackage.replacingOccurrences(of: "../Leaf", with: "../P0").replacingOccurrences(of: "package: \"leaf\"", with: "package: \"p0\"")
        XCTAssertThrowsError(try packageFixture(manifest: root, extraFiles: extra).read()) { error in
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Local package target depth exceeds budget"))
        }
        let fixture = try transitiveFixture(), member = fixture.session.appendingPathComponent("source/Leaf/Package.swift")
        try FileManager.default.removeItem(at: member)
        try FileManager.default.createSymbolicLink(at: member, withDestinationURL: fixture.session.appendingPathComponent("source/Deep/Package.swift"))
        XCTAssertThrowsError(try fixture.read())
    }
    func testExplicitTrustedLocalPackageBuildFixtureMatchesRetainedGraph() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_LOCAL_PACKAGE_TEST_ROOT"] else { throw XCTSkip("Explicit authored local package build fixture") }
        let files = [
            "Package/Package.swift": "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Root\", products: [.executable(name: \"Local\", targets: [\"Main\"])], dependencies: [.package(name: \"Alias\", path: \"../Leaf\")], targets: [.executableTarget(name: \"Main\", dependencies: [.product(name: \"LeafProduct\", package: \"Alias\")])])",
            "Package/Sources/Main/main.swift": "import Leaf\nprint(Leaf.value)",
            "Leaf/Package.swift": "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Leaf\", products: [.library(name: \"LeafProduct\", targets: [\"Leaf\"])], dependencies: [.package(path: \"../Deep\")], targets: [.target(name: \"Leaf\", dependencies: [.product(name: \"DeepProduct\", package: \"deep\")]), .target(name: \"Unused\")])",
            "Leaf/Sources/Leaf/Leaf.swift": "import Deep\npublic enum Leaf { public static let value = Deep.value }",
            "Leaf/Sources/Unused/Unused.swift": "#error(\"Unselected target must not compile\")",
            "Deep/Package.swift": "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Deep\", products: [.library(name: \"DeepProduct\", targets: [\"Deep\"])], targets: [.target(name: \"Deep\")])",
            "Deep/Sources/Deep/Deep.swift": "public enum Deep { public static let value = \"selected\" }"
        ]
        let fixture = try self.fixture(additionalFiles: files) { objects in
            objects["APP"]?["packageProductDependencies"] = ["LOCAL_PRODUCT"]
            objects["LOCAL_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "Local", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"]
        }
        let graph = try fixture.read()
        XCTAssertEqual(graph.inputs.filter { $0.role == "packageSwiftMembership" }.map(\.relativePath),
            ["Deep/Sources/Deep/Deep.swift", "Leaf/Sources/Leaf/Leaf.swift", "Package/Sources/Main/main.swift"])
        try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
        let root = URL(fileURLWithPath: path)
        for (relative, source) in files {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: file)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(graph).write(to: root.appendingPathComponent("retained-graph.json"))
        try encoder.encode(files.mapValues { AutomationArtifactRegistry.digest(Data($0.utf8)) }).write(to: root.appendingPathComponent("authored-source-digests.json"))
    }
    func testDynamicPluginEscapingAndAbsentPackageMembershipRemainGaps() throws {
        for manifest in ["#if os(macOS)\n" + literalPackage + "\n#endif", literalPackage + "\npackage.targets.removeAll()",
                         literalPackage.replacingOccurrences(of: "path: \"Code\"", with: "path: \"../Sources\""),
                         literalPackage.replacingOccurrences(of: "path: \"Code\"", with: "path: \"Code\", plugins: [.plugin(name: \"Generator\")]"),
                         literalPackage.replacingOccurrences(of: "\"Main.swift\", \"Nested\"", with: "\"Absent.swift\"")] {
            let graph = try packageFixture(manifest: manifest).read()
            XCTAssertFalse(graph.inputs.contains { $0.relativePath == "Package/Code/Main.swift" && $0.role == "packageSwiftMembership" })
            XCTAssertFalse(graph.gaps.isEmpty); XCTAssertEqual(graph.coverage, "partial")
        }
    }
    func testFrozenPackageSourceLinkCannotReplaceLiteralMember() throws {
        let fixture = try packageFixture(), member = fixture.session.appendingPathComponent("source/Package/Code/Main.swift")
        try FileManager.default.removeItem(at: member)
        try FileManager.default.createSymbolicLink(at: member, withDestinationURL: fixture.session.appendingPathComponent("source/Sources/App.swift"))
        XCTAssertThrowsError(try fixture.read())
    }
    func testPackageRootHiddenAndOpaqueDirectoriesCannotBecomeSourceMembers() throws {
        let manifest = literalPackage.replacingOccurrences(of: "path: \"Code\", exclude: [\"Nested/Excluded.swift\"], sources: [\"Main.swift\", \"Nested\"]", with: "path: \".\"")
        let paths = ["Package/.Hidden/Fake.swift", "Package/.Fake.swift", "Package/Preview.playground/Fake.swift",
                     "Package/Foreign.xcodeproj/Fake.swift", "Package/Foreign.xcworkspace/Fake.swift", "Package/Assets.bundle/Fake.swift", "Package/Package@swift-6.swift"]
        let graph = try packageFixture(manifest: manifest, extraFiles: Dictionary(uniqueKeysWithValues: paths.map { ($0, "struct Ignored: AppIntent {}") })).read()
        let members = graph.inputs.filter { $0.role == "packageSwiftMembership" }.map(\.relativePath)
        XCTAssertFalse(members.contains("Package/Package.swift"))
        XCTAssertFalse(paths.contains(where: members.contains))
        XCTAssertTrue(members.contains("Package/Code/Main.swift"))
        XCTAssertTrue(graph.gaps.contains { $0.contains("Opaque") })
    }
    func testRepeatedPackageReferencesDoNotRepeatExpansionAndMembershipComparisonsAreBounded() throws {
        let graph = try packageFixture(references: 1000).read()
        XCTAssertEqual(graph.nodes.filter { $0.kind == "localPackageTarget" }.count, 2)
        XCTAssertEqual(graph.inputs.filter { $0.role == "packageSwiftMembership" }.count, 3)
        let exclusions = (0..<256).map { "\"Excluded\($0)\"" }.joined(separator: ",")
        let manifest = literalPackage.replacingOccurrences(of: "[\"Nested/Excluded.swift\"]", with: "[" + exclusions + "]")
        let files = Dictionary(uniqueKeysWithValues: (0..<700).map { ("Package/Code/File\($0).swift", "// snapshot input") })
        XCTAssertThrowsError(try packageFixture(manifest: manifest, extraFiles: files).read()) { error in
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Source graph traversal budget exceeded"))
        }
    }
    func testRepositoryCorePackageGraphCapturesOnlyItsLiteralTargetClosure() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packageData = try Data(contentsOf: repository.appendingPathComponent("Package.swift"))
        let package = try XCTUnwrap(AutomationPackageManifest.read(packageData))
        let names = ["IntentsAutomationCore", "IntentsAutomationDateCodec", "IntentLabContracts"]
        var contents = ["Package/Package.swift": try XCTUnwrap(String(data: packageData, encoding: .utf8))]
        for name in names {
            let path = try XCTUnwrap(package.targetsByName[name]?.path)
            let directory = repository.appendingPathComponent(path)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relative = String(url.path.dropFirst(repository.path.count + 1))
                contents["Package/" + relative] = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
            }
        }
        let retained = ProcessInfo.processInfo.environment["INTENTS_PACKAGE_GRAPH_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
        let fixture = try fixture(additionalFiles: contents, retainedRoot: retained) { objects in
            objects["APP"]?["packageProductDependencies"] = ["CORE_PRODUCT"]
            objects["CORE_PRODUCT"] = ["isa": "XCSwiftPackageProductDependency", "productName": "IntentsAutomationCore", "package": "LOCAL"]
            objects["LOCAL"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"]
        }
        let graph = try fixture.read()
        XCTAssertEqual(Set(graph.nodes.filter { $0.kind == "localPackageTarget" }.map(\.name)), Set(names))
        let core = graph.inputs.filter { $0.owner == "Package/Package.swift#target:IntentsAutomationCore" }
        XCTAssertEqual(core.count, contents.keys.filter { $0.hasPrefix("Package/Sources/IntentsAutomationCore/") }.count)
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Package/Integration/AutomationHost/AutomationDateCodec.swift" && $0.role == "packageSwiftMembership" })
        XCTAssertFalse(graph.inputs.contains { $0.relativePath == "Package/Integration/AutomationHost/IntentDefinitionsHost.swift" && $0.role == "packageSwiftMembership" })
        XCTAssertFalse(graph.inputs.contains { $0.relativePath.hasPrefix("Package/Code/") })
        XCTAssertEqual(graph, try fixture.read()); try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
        if let retained {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(graph).write(to: retained.appendingPathComponent("repository-core-graph.json"))
        }
        let projectPath = "FoundationEvals/FoundationEvals.xcodeproj"
        let resolutionPath = projectPath + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        var actualContents = Dictionary(uniqueKeysWithValues: contents.map { (String($0.key.dropFirst("Package/".count)), $0.value) })
        for path in [projectPath + "/project.pbxproj", resolutionPath] {
            actualContents[path] = try XCTUnwrap(String(data: Data(contentsOf: repository.appendingPathComponent(path)), encoding: .utf8))
        }
        let actualFixture = try self.fixture(additionalFiles: actualContents, retainedRoot: retained)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(repository.appendingPathComponent(projectPath)).candidates.first { $0.name == "FoundationEvals" })
        let actualGraph = try AutomationSourceGraphReader.read(manifest: actualFixture.manifest, frozenRoot: actualFixture.session.appendingPathComponent("source"),
            projectRelativePath: projectPath, targetID: try XCTUnwrap(candidate.targetID), configuration: "Debug")
        XCTAssertEqual(Set(actualGraph.packagePins?.map(\.identity) ?? []), Set(["coreai-models", "hummingbird", "posthog-ios", "sparkle"]))
        XCTAssertEqual(Set(actualGraph.packagePins?.filter { $0.requirementState == "satisfied" }.map(\.identity) ?? []), Set(["coreai-models", "posthog-ios", "sparkle"]))
        XCTAssertEqual(actualGraph.packagePins?.first { $0.identity == "hummingbird" }?.requirementState, "unresolved")
        XCTAssertTrue(actualGraph.gaps.contains { $0.contains("Synchronized") })
        XCTAssertEqual(actualGraph.coverage, "partial"); try AutomationSourceSnapshot.verifyOriginal(actualFixture.manifest)
        if let retained {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(actualGraph).write(to: retained.appendingPathComponent("repository-remote-graph.json"))
        }
    }
    func testRepeatedReferencesHitTraversalBudgetAndEmbeddedOwnershipIsIndexed() throws {
        let fixture = try fixture { objects in
            objects["APP"]?["buildPhases"] = Array(repeating: "COPY", count: 60_000)
            objects["COPY"] = ["isa": "PBXCopyFilesBuildPhase", "files": ["EMBED"]]
            objects["EMBED"] = ["fileRef": "LIBPRODUCT"]
            objects["LIB"]?["productReference"] = "LIBPRODUCT"
        }
        XCTAssertThrowsError(try fixture.read()) { error in
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Source graph traversal budget exceeded"))
        }
        let graph = try self.fixture { objects in
            objects["APP"]?["dependencies"] = []
            objects["APP"]?["buildPhases"] = ["APP_PHASE", "COPY", "COPY"]
            objects["COPY"] = ["isa": "PBXCopyFilesBuildPhase", "files": ["EMBED"]]
            objects["EMBED"] = ["fileRef": "LIBPRODUCT"]
            objects["LIB"]?["productReference"] = "LIBPRODUCT"
        }.read()
        XCTAssertEqual(graph.edges.filter { $0.kind == "linkedOrEmbeddedProduct" }.count, 1)
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Sources/Library.swift" })
    }
    func testEscapingAndAbsentSourceReferencesDoNotBecomeMembers() throws {
        let graph = try fixture { objects in
            objects["APPFILE"]?["path"] = "/outside/private.swift"; objects["APPFILE"]?["sourceTree"] = "<absolute>"
            objects["LIBFILE"]?["path"] = "Missing.swift"
        }.read()
        XCTAssertTrue(graph.inputs.isEmpty); XCTAssertTrue(graph.declarations.isEmpty)
        XCTAssertTrue(graph.gaps.contains { $0.contains("External source root") })
        XCTAssertTrue(graph.gaps.contains { $0.contains("absent") })
    }
    private func synchronizedFixture(files: [String: String] = ["Synced/Intent.swift": "import AppIntents\nstruct FolderIntent: AppIntent {}\nstruct FolderEntity: AppEntity {}", "Synced/notes.txt": "not Swift"],
                                     _ mutate: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> Fixture {
        try fixture(additionalFiles: files) { objects in
            objects["GROUP"]?["children"] = ["SOURCES", "SYNC"]
            objects["SYNC"] = ["isa": "PBXFileSystemSynchronizedRootGroup", "path": "Synced", "sourceTree": "<group>", "exceptions": [String](), "explicitFolders": [String](), "explicitFileTypes": [String: String]()]
            objects["APP"]?["fileSystemSynchronizedGroups"] = ["SYNC"]
            mutate(&objects)
        }
    }
    func testSimpleSynchronizedFolderSuppliesOnlyCapturedSwiftWithExactOwner() throws {
        let fixture = try synchronizedFixture(), graph = try fixture.read()
        XCTAssertEqual(graph.synchronizedMembershipVersion, 1); XCTAssertEqual(graph.coverage, "partial")
        let input = try XCTUnwrap(graph.inputs.first { $0.role == "synchronizedSwiftMembership" })
        XCTAssertEqual(input.relativePath, "Synced/Intent.swift"); XCTAssertEqual(input.owner, "App.xcodeproj#APP")
        XCTAssertEqual(input.sha256, fixture.manifest.files.first { $0.relativePath == input.relativePath }?.sha256)
        XCTAssertEqual(graph.declarations.filter { $0.relativePath == input.relativePath }.map(\.name), ["FolderIntent", "FolderEntity"])
        XCTAssertFalse(graph.inputs.contains { $0.relativePath == "Synced/notes.txt" })
        try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.session.appendingPathComponent("source"))
        let path = fixture.session.appendingPathComponent("source/Synced/Intent.swift")
        try Data("struct Changed: AppIntent {}".utf8).write(to: path)
        XCTAssertThrowsError(try fixture.read())
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.session.appendingPathComponent("source")))
        try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
    }
    func testSynchronizedAndExplicitOverlapRetainsOneInputAndDeclaration() throws {
        let graph = try synchronizedFixture { objects in
            objects["GROUP"]?["children"] = ["SOURCES", "SYNC", "EXPLICIT_SYNC"]
            objects["EXPLICIT_SYNC"] = ["isa": "PBXFileReference", "path": "Synced/Intent.swift", "sourceTree": "<group>"]
            objects["EXPLICIT_SYNC_BUILD"] = ["isa": "PBXBuildFile", "fileRef": "EXPLICIT_SYNC"]
            objects["APP_PHASE"]?["files"] = ["APP_BUILD", "EXPLICIT_SYNC_BUILD"]
        }.read()
        let inputs = graph.inputs.filter { $0.relativePath == "Synced/Intent.swift" }
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.role, "explicitSwiftMembership")
        XCTAssertEqual(graph.declarations.filter { $0.relativePath == "Synced/Intent.swift" }.map(\.name), ["FolderIntent", "FolderEntity"])
    }
    func testSynchronizedWrapperRootRemainsUnresolved() throws {
        let graph = try synchronizedFixture(files: ["Scene.scnassets/Extra.swift": "struct Other: AppIntent {}"] ) {
            $0["SYNC"]?["path"] = "Scene.scnassets"
        }.read()
        XCTAssertFalse(graph.inputs.contains { $0.role == "synchronizedSwiftMembership" })
        XCTAssertTrue(graph.gaps.contains { $0.contains("Synchronized Swift membership is unresolved") })
    }
    func testUnsupportedSynchronizedAssociationsAndExceptionsRemainGaps() throws {
        for change in 0..<12 {
            let graph = try synchronizedFixture { objects in
                switch change {
                case 0: objects["APP"]?["fileSystemSynchronizedGroups"] = ["SYNC", "SYNC"]
                case 1: objects["TEST"]?["fileSystemSynchronizedGroups"] = ["SYNC"]
                case 2: objects["SYNC"]?["exceptions"] = ["EXCEPTION"]; objects["EXCEPTION"] = ["isa": "PBXFileSystemSynchronizedBuildFileExceptionSet", "target": "APP", "membershipExceptions": ["Intent.swift"]]
                case 3: objects["SYNC"]?["exceptions"] = "invalid"
                case 4: objects["SYNC"]?["explicitFolders"] = ["Nested"]
                case 5: objects["SYNC"]?["explicitFileTypes"] = ["Intent.swift": "text"]
                case 6: objects["SYNC"]?["unsupportedFlag"] = true
                case 7: objects["SYNC"]?["path"] = "Missing"
                case 8: objects["DEBUG"]?["buildSettings"] = ["EXCLUDED_SOURCE_FILE_NAMES": "Intent.swift"]
                case 9: objects["TEST"]?["fileSystemSynchronizedGroups"] = "invalid"
                case 10: objects["SYNC"]?["path"] = "../ungranted"
                default: objects["ORPHAN"] = ["isa": "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"]
                }
            }.read()
            XCTAssertFalse(graph.inputs.contains { $0.role == "synchronizedSwiftMembership" }, "case \(change)")
            XCTAssertFalse(graph.declarations.contains { $0.name == "FolderIntent" }, "case \(change)")
            XCTAssertTrue(graph.gaps.contains { $0.contains("Synchronized") && $0.contains("unresolved") }, "case \(change)")
        }
        let unrelated = try synchronizedFixture { $0["APP"]?.removeValue(forKey: "fileSystemSynchronizedGroups"); $0["TEST"]?["fileSystemSynchronizedGroups"] = ["SYNC"] }.read()
        XCTAssertFalse(unrelated.declarations.contains { $0.name == "FolderIntent" })
    }
    func testSynchronizedCaseVariantsOpaqueFoldersAndLinkedSwiftNeverBecomeCandidates() throws {
        for path in ["Synced/Other.SWIFT", "Synced/.hidden.swift", "Synced/Assets.xcassets/Extra.swift",
                     "Synced/Scene.scnassets/Extra.swift", "Synced/Model.xcdatamodeld/Extra.swift",
                     "Synced/Library.xcframework/Extra.swift", "Synced/Docs.docc/Extra.swift",
                     "Synced/Unknown.wrapper/Extra.swift"] {
            let graph = try synchronizedFixture(files: ["Synced/Intent.swift": "struct FolderIntent: AppIntent {}", path: "struct Other: AppIntent {}"]).read()
            XCTAssertFalse(graph.inputs.contains { $0.role == "synchronizedSwiftMembership" }, path)
            XCTAssertTrue(graph.gaps.contains { $0.contains("Synchronized Swift membership is unresolved") }, path)
        }
        let collision = try synchronizedFixture()
        var manifest = collision.manifest
        var alias = try XCTUnwrap(manifest.files.first { $0.relativePath == "Synced/Intent.swift" })
        alias.relativePath = "Synced/INTENT.swift"; alias.inputPath = manifest.sourceRoot + "/" + alias.relativePath
        manifest.files.append(alias)
        let graph = try AutomationSourceGraphReader.read(manifest: manifest, frozenRoot: collision.session.appendingPathComponent("source"), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug")
        XCTAssertFalse(graph.inputs.contains { $0.role == "synchronizedSwiftMembership" })
        let fixture = try synchronizedFixture(), privateRoot = fixture.session.appendingPathComponent("source")
        try FileManager.default.removeItem(at: privateRoot.appendingPathComponent("Synced/Intent.swift"))
        try FileManager.default.createSymbolicLink(at: privateRoot.appendingPathComponent("Synced/Intent.swift"), withDestinationURL: privateRoot.appendingPathComponent("Sources/App.swift"))
        XCTAssertThrowsError(try fixture.read())
    }
    func testLegacySynchronizedGraphsRetainTheirUnknownMembershipOnReplay() throws {
        let fixture = try synchronizedFixture(), root = fixture.session.appendingPathComponent("source")
        let bytes = try Data(contentsOf: root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let legacy = try AutomationSourceGraphReader.read(manifest: fixture.manifest, frozenRoot: root, projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", projectData: bytes, resolveSynchronizedMembership: false)
        XCTAssertNil(legacy.synchronizedMembershipVersion)
        XCTAssertFalse(legacy.inputs.contains { $0.role == "synchronizedSwiftMembership" })
        XCTAssertTrue(legacy.gaps.contains { $0.contains("Synchronized group membership is unresolved") })
        let decoded = try JSONDecoder().decode(AutomationSourceGraph.self, from: JSONEncoder().encode(legacy))
        let replayed = try AutomationSourceGraphReader.read(manifest: fixture.manifest, frozenRoot: root, projectRelativePath: decoded.projectRelativePath, targetID: decoded.targetID, configuration: decoded.configuration, projectData: bytes, resolveSynchronizedMembership: decoded.synchronizedMembershipVersion == 1)
        XCTAssertEqual(try replayed.digest, try legacy.digest)
    }
    func testSharedConfigurationAndSynchronizedListsConsumeWorkBudget() throws {
        for key in ["buildConfigurations", "fileSystemSynchronizedGroups"] {
            let fixture = try fixture { objects in
                if key == "buildConfigurations" { objects["CONFIGS"]?[key] = ["DEBUG"] + Array(repeating: "MISSING", count: 60_000) }
                else {
                    objects["APP"]?[key] = Array(repeating: "SYNC", count: 60_000)
                    objects["LIB"]?[key] = Array(repeating: "SYNC", count: 60_000)
                }
            }
            XCTAssertThrowsError(try fixture.read()) { error in
                XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Source graph traversal budget exceeded"))
            }
        }
    }
    func testCommentAndQuotedTextAreNotDeclarationCandidates() throws {
        let text = #"""
        // struct Comment: AppIntent {}
        /* outer /* struct Nested: AppEntity {} */ */
        let a = "struct Quoted: AppIntent {}"
        let raw = ##"struct Raw: AppIntent {}"##
        struct `Real`: AppIntents.AppIntent {}
        struct Generic<T: AppIntent> {}
        struct Unrelated: Other.AppIntent {}
        """#
        let found = try AutomationSourceDeclarationReader.read(Data(text.utf8), path: "App.swift", owner: "APP")
        XCTAssertEqual(found.map(\.name), ["Real"]); XCTAssertEqual(found[0].line, 5)
    }
    func testCatalogKeepsCompiledRuntimeAndSourceCandidateStatesSeparate() throws {
        var graph = try fixture().read()
        var app = AppIdentity(logicalID: "App", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.sourceManifestDigest = graph.sourceManifestDigest; app.owningModule = "App"
        let action = ApplicationSurfaceCatalog.SystemAction(id: "Echo", typeName: "App.Echo", title: "Echo", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
        let original = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let decoded = try JSONDecoder().decode(ApplicationSurfaceCatalog.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.sourceGraphDigest); XCTAssertNil(decoded.systemActions[0].sourceCandidates)
        let reconciled = try AutomationSourceCatalogReconciliation.apply(graph, to: decoded)
        XCTAssertEqual(reconciled.systemActions[0].sourceReconciliation, "lexicalCandidate")
        XCTAssertEqual(reconciled.systemActions[0].sourceCandidates?.first?.relativePath, "Sources/App.swift")
        XCTAssertTrue(reconciled.systemActions[0].compiled); XCTAssertFalse(reconciled.systemActions[0].registered)
        XCTAssertFalse(reconciled.systemActions[0].executed); XCTAssertFalse(reconciled.systemDiscoveryComplete)
        graph.declarations += graph.declarations.filter { $0.name == "Echo" }
        XCTAssertEqual(try AutomationSourceCatalogReconciliation.apply(graph, to: original).systemActions[0].sourceReconciliation, "ambiguous")
        graph.declarations = []
        XCTAssertEqual(try AutomationSourceCatalogReconciliation.apply(graph, to: original).systemActions[0].sourceReconciliation, "unresolved")
        graph.sourceManifestDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationSourceCatalogReconciliation.apply(graph, to: original))
    }
    func testRegexBodiesAndNestedQuotedInterpolationDoNotLeakCandidates() throws {
        let text = ###"""
        let r = #/struct RegexFake: AppIntent,/#
        let bare = /struct BareFake: AppIntent,/
        let s = "prefix \(String("struct StringFake: AppIntent, "))"
        let raw = #"prefix \#(String("struct RawFake: AppIntent, "))"#
        let escapedParenthesis = /\(/
        struct Actual: AppIntent {}
        """###
        let found = try AutomationSourceDeclarationReader.read(Data(text.utf8), path: "App.swift", owner: "APP")
        XCTAssertEqual(found.map(\.name), ["Actual"]); XCTAssertEqual(found[0].line, 6)
        XCTAssertThrowsError(try AutomationSourceDeclarationReader.read(Data(String(repeating: "#", count: 65).utf8), path: "App.swift", owner: "APP"))
    }
    func testDependencyDeclarationsCannotBorrowTheSelectedAppModule() throws {
        var graph = try fixture().read()
        var dependency = try XCTUnwrap(graph.declarations.first { $0.name == "Echo" })
        dependency.owner = "App.xcodeproj#LIB"; dependency.relativePath = "Sources/Library.swift"
        graph.declarations.append(dependency)
        var app = AppIdentity(logicalID: "App", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.sourceManifestDigest = graph.sourceManifestDigest; app.owningModule = "App"
        let action = ApplicationSurfaceCatalog.SystemAction(id: "Echo", typeName: "App.Echo", title: "Echo", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        XCTAssertEqual(try AutomationSourceCatalogReconciliation.apply(graph, to: catalog).systemActions[0].sourceCandidates?.map(\.owner), ["App.xcodeproj#APP"])
        var declarations = graph.declarations
        for position in declarations.indices { declarations[position].qualifiedName = declarations[position].name; declarations[position].column = 1; declarations[position].kind = "struct"; declarations[position].compilationConditions = [] }
        let syntax = AutomationSourceSyntaxIndex(sourceManifestDigest: graph.sourceManifestDigest, sourceGraphDigest: try graph.digest,
            helperTemplateDigest: String(repeating: "b", count: 64), helperDigest: String(repeating: "c", count: 64), toolchain: [], inputs: graph.inputs, declarations: declarations, gaps: [])
        var syntaxCatalog = catalog; syntaxCatalog.app.sourceSyntaxIndexDigest = try syntax.digest
        XCTAssertEqual(try AutomationSourceSyntaxReconciliation.apply(syntax, graph: graph, to: syntaxCatalog).systemActions[0].sourceCandidates?.map(\.owner), ["App.xcodeproj#APP"])
        syntaxCatalog.systemActions[0].typeName = "Library.Echo"
        XCTAssertEqual(try AutomationSourceSyntaxReconciliation.apply(syntax, graph: graph, to: syntaxCatalog).systemActions[0].sourceReconciliation, "unresolved")
    }
    #if os(macOS)
    func testSavedGraphIsRecomputedAndTamperedOrDetachedSourceClaimsAreRejected() throws {
        let fixture = try remoteFixture(appName: "Caf\u{00e9}"), graph = try fixture.read()
        let product = fixture.session.appendingPathComponent("DerivedData/Subject.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        var app = AppIdentity(logicalID: fixture.manifest.sourceRoot + "/App.xcodeproj#APP", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = product.path; app.configuration = "Debug"; app.sourceManifestDigest = try fixture.manifest.digest; app.owningModule = "App"
        let action = ApplicationSurfaceCatalog.SystemAction(id: "Echo", typeName: "App.Echo", title: "Echo", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
        let catalog = try AutomationSourceCatalogReconciliation.apply(graph, to: .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []))
        var prepared = AutomationPreparedApplication(source: fixture.manifest,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "b", count: 64)),
            host: .init(app: app, target: .init(id: UUID().uuidString, kind: .nativeMac), xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: product.path, hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: catalog, buildLogPath: "unused", buildLogTruncated: false, sourceGraph: graph)
        let record = fixture.session.appendingPathComponent("prepared-application.json")
        let originalProject = fixture.session.appendingPathComponent("source-graph-project.pbxproj")
        try Data(contentsOf: fixture.session.appendingPathComponent("source/App.xcodeproj/project.pbxproj")).write(to: originalProject)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalProject.path)
        let resolutionArchive = fixture.session.appendingPathComponent("source-graph-resolution.json")
        let workingResolution = fixture.session.appendingPathComponent("source/" + (try XCTUnwrap(graph.packagePins?.first?.resolutionPath)))
        let resolutionBytes = try Data(contentsOf: workingResolution)
        try resolutionBytes.write(to: resolutionArchive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolutionArchive.path)
        func save() throws {
            try JSONEncoder().encode(prepared).write(to: record)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        }
        try save(); XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        try Data("rewritten by resolver".utf8).write(to: workingResolution)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        try FileManager.default.removeItem(at: workingResolution)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        try Data("altered archive".utf8).write(to: resolutionArchive)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        try FileManager.default.removeItem(at: resolutionArchive)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        try resolutionBytes.write(to: resolutionArchive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolutionArchive.path)
        prepared.sourceGraph?.packagePins?[0].revision = String(repeating: "f", count: 40)
        prepared.catalog.sourceGraphDigest = try prepared.sourceGraph?.digest
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceGraph = graph; prepared.catalog = catalog; try save()
        prepared.sourceGraph?.schemaVersion = 1; try save()
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root)) { error in
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Retained source evidence predates conditional-compilation tracking; prepare this source target again"))
        }
        prepared.sourceGraph?.schemaVersion = 2; try save()
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root)) { error in
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Retained source evidence lacks current local-package dependency tracking; prepare this source target again"))
        }
        prepared.sourceGraph = graph; try save()
        let syntaxFile = fixture.session.appendingPathComponent("source-syntax-index.json")
        let syntax = AutomationSourceSyntaxIndex(sourceManifestDigest: graph.sourceManifestDigest, sourceGraphDigest: try graph.digest,
            helperTemplateDigest: String(repeating: "e", count: 64), helperDigest: String(repeating: "f", count: 64), toolchain: [],
            inputs: graph.inputs.filter { $0.role == "explicitSwiftMembership" },
            declarations: [.init(name: "Echo", protocols: ["AppIntent"], relativePath: "Sources/App.swift", owner: "App.xcodeproj#APP", line: 2, qualifiedName: "Echo", column: 1, kind: "struct", compilationConditions: [])], gaps: [])
        let syntaxBytes = try JSONEncoder().encode(syntax)
        try syntaxBytes.write(to: syntaxFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: syntaxFile.path)
        app.sourceSyntaxIndexDigest = try syntax.digest
        prepared.host.app = app; prepared.catalog.app = app; prepared.sourceSyntax = syntax
        prepared.catalog = try AutomationSourceSyntaxReconciliation.apply(syntax, graph: graph, to: prepared.catalog)
        try save(); XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        prepared.sourceSyntax?.schemaVersion = 1; try save()
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceSyntax = syntax; try save()
        var changedSyntax = syntax; changedSyntax.declarations[0].line += 1
        try JSONEncoder().encode(changedSyntax).write(to: syntaxFile)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        try syntaxBytes.write(to: syntaxFile)
        prepared.catalog.systemActions[0].sourceCandidates?[0].qualifiedName = "Foreign.Echo"
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.catalog = try AutomationSourceSyntaxReconciliation.apply(syntax, graph: graph, to: catalogWithApp(catalog, app: app))
        prepared.sourceSyntax = nil
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceSyntax = syntax
        try save(); try FileManager.default.removeItem(at: syntaxFile)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        app.sourceSyntaxIndexDigest = nil; prepared.host.app = app; prepared.catalog = catalog; prepared.sourceSyntax = nil
        try save(); XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        try Data("working project changed by host generation".utf8).write(to: fixture.session.appendingPathComponent("source/App.xcodeproj/project.pbxproj"))
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root), prepared)
        let archivedBytes = try Data(contentsOf: originalProject)
        try Data("tampered archive".utf8).write(to: originalProject)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        try archivedBytes.write(to: originalProject)
        prepared.catalog.systemActions[0].sourceCandidates?[0].line += 1
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.catalog = catalog; prepared.sourceGraph?.declarations[0].line += 1
        prepared.catalog.sourceGraphDigest = try prepared.sourceGraph?.digest
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceGraph = graph; prepared.sourceGraph?.nodes[0].name = "Cafe\u{0301}"
        XCTAssertEqual(prepared.sourceGraph?.nodes[0].name, graph.nodes[0].name)
        prepared.catalog.sourceGraphDigest = try prepared.sourceGraph?.digest
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceGraph = nil; prepared.catalog = catalog
        try save(); XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
        prepared.sourceGraph = graph
        try save(); try Data("changed".utf8).write(to: fixture.session.appendingPathComponent("source/Sources/App.swift"))
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: app, supportRoot: fixture.root))
    }
    private func catalogWithApp(_ catalog: ApplicationSurfaceCatalog, app: AppIdentity) -> ApplicationSurfaceCatalog {
        var result = catalog; result.app = app; return result
    }
    #endif
}
