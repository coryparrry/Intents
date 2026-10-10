import XCTest
@testable import IntentsAutomationCore

final class AutomationSourceCompilationConditionsTests: XCTestCase {
    func testBoundedBooleanExpressionsAndUnknownCompilerPredicates() {
        let active = ["DEBUG", "FEATURE"]
        for expression in ["true", "DEBUG", "DEBUG && !RELEASE", "false || (FEATURE && DEBUG)", "true || canImport(Missing)"] {
            XCTAssertEqual(AutomationSourceCompilationConditions.evaluate(expression, active: active), true, expression)
        }
        for expression in ["false", "RELEASE", "DEBUG && RELEASE", "false && canImport(Missing)"] {
            XCTAssertEqual(AutomationSourceCompilationConditions.evaluate(expression, active: active), false, expression)
        }
        for expression in ["canImport(AppIntents)", "os(macOS)", "compiler(>=6.0)", "swift(>=6.0)", "targetEnvironment(simulator)", "hasFeature(X)", "DEBUG && canImport(Missing)", "!canImport(Missing)", "true false", "DEBUG & FEATURE", "!", "(", "DEBUG)"] {
            XCTAssertNil(AutomationSourceCompilationConditions.evaluate(expression, active: active), expression)
        }
        XCTAssertNil(AutomationSourceCompilationConditions.evaluate("DEBUG", active: nil))
        XCTAssertNil(AutomationSourceCompilationConditions.evaluate(String(repeating: "!", count: 70) + "true", active: active))
        XCTAssertNil(AutomationSourceCompilationConditions.evaluate(String(repeating: " ", count: 4097), active: active))
    }

    func testLegacyAndForeignOwnerFactsCannotResolveCustomBranches() {
        var declaration = AutomationSourceDeclaration(name: "Echo", protocols: ["AppIntent"], relativePath: "App.swift", owner: "App.xcodeproj#APP", line: 1)
        let facts = AutomationSourceCompilationConditions(owner: "App.xcodeproj#APP", configuration: "Debug", settingsSHA256: String(repeating: "a", count: 64), activeConditions: ["DEBUG"])
        XCTAssertNil(AutomationSourceCompilationConditions.resolve(declaration, facts: facts))
        declaration.compilationConditions = ["DEBUG", "!canImport(Missing)"]
        XCTAssertNil(AutomationSourceCompilationConditions.resolve(declaration, facts: facts))
        declaration.compilationConditions = ["DEBUG", "false"]
        XCTAssertEqual(AutomationSourceCompilationConditions.resolve(declaration, facts: facts), false)
        declaration.compilationConditions = ["DEBUG"]; declaration.owner = "Package.swift#target:Dependency"
        XCTAssertNil(AutomationSourceCompilationConditions.resolve(declaration, facts: facts))
        declaration.compilationConditions = []
        XCTAssertEqual(AutomationSourceCompilationConditions.resolve(declaration, facts: nil), true)
    }

    func testExactSelectedSettingsResolveCustomFlagsAndUnsupportedFlagsStayUnknown() throws {
        let graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [], inputs: [], declarations: [], gaps: [])
        let project = URL(fileURLWithPath: "/private/tmp/conditions-" + UUID().uuidString + ".xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let platform = AutomationBuildPlatform(targetName: "App", configuration: "Debug", projectPath: project.path, platformName: "macosx", platformFamily: "macos", sdkRoot: "macosx", supportedPlatforms: ["macosx"])
        var settings: [String: Any] = ["TARGET_NAME": "App", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": platform.projectPath, "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FEATURE DEBUG", "OTHER_SWIFT_FLAGS": "-DEXTRA -D SECOND"]
        func bytes() throws -> Data { try JSONSerialization.data(withJSONObject: [["target": "App", "buildSettings": settings]]) }
        let data = try bytes(), facts = try AutomationSourceCompilationConditions.read(data, graph: graph, platform: platform)
        XCTAssertEqual(facts.activeConditions, ["DEBUG", "EXTRA", "FEATURE", "SECOND"])
        XCTAssertEqual(facts.settingsSHA256, AutomationArtifactRegistry.digest(data)); try facts.validate(graph: graph)
        settings["PROJECT_FILE_PATH"] = project.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        XCTAssertEqual(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform).activeConditions, facts.activeConditions)
        settings["PROJECT_FILE_PATH"] = "/tmp/Foreign.xcodeproj"
        XCTAssertThrowsError(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform))
        settings["PROJECT_FILE_PATH"] = platform.projectPath
        settings.removeValue(forKey: "OTHER_SWIFT_FLAGS")
        XCTAssertNil(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform).activeConditions)
        settings["OTHER_SWIFT_FLAGS"] = ""; settings.removeValue(forKey: "SWIFT_ACTIVE_COMPILATION_CONDITIONS")
        XCTAssertNil(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform).activeConditions)
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "FEATURE DEBUG"
        for flag in ["-Xfrontend -D DEBUG", "$(inherited)", "-D", "-D'QUOTED'", "-O"] {
            settings["OTHER_SWIFT_FLAGS"] = flag
            XCTAssertNil(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform).activeConditions, flag)
        }
        settings["OTHER_SWIFT_FLAGS"] = ""; settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited)"
        XCTAssertNil(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform).activeConditions)
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"; settings["CONFIGURATION"] = "Release"
        XCTAssertThrowsError(try AutomationSourceCompilationConditions.read(bytes(), graph: graph, platform: platform))
    }

    func testInactiveAndUnresolvedSyntaxCandidatesCannotMatchMetadata() throws {
        let graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [], inputs: [.init(relativePath: "App.swift", sha256: String(repeating: "b", count: 64), owner: "App.xcodeproj#APP", role: "explicitSwiftMembership")], declarations: [], gaps: [])
        var index = AutomationSourceSyntaxIndex(sourceManifestDigest: graph.sourceManifestDigest, sourceGraphDigest: try graph.digest, helperTemplateDigest: String(repeating: "c", count: 64), helperDigest: String(repeating: "d", count: 64), toolchain: [], inputs: graph.inputs, declarations: [.init(name: "Echo", protocols: ["AppIntent"], relativePath: "App.swift", owner: "App.xcodeproj#APP", line: 1, qualifiedName: "Echo", column: 1, kind: "struct", compilationConditions: ["DEBUG"])], gaps: [])
        index.compilationConditions = .init(owner: "App.xcodeproj#APP", configuration: "Debug", settingsSHA256: String(repeating: "e", count: 64), activeConditions: ["DEBUG"])
        var app = AppIdentity(logicalID: "App", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "f", count: 64))
        app.sourceManifestDigest = graph.sourceManifestDigest
        func match() throws -> ApplicationSurfaceCatalog.SystemAction {
            app.sourceSyntaxIndexDigest = try index.digest
            let action = ApplicationSurfaceCatalog.SystemAction(id: "Echo", typeName: "Echo", title: "Echo", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
            return try AutomationSourceSyntaxReconciliation.apply(index, graph: graph, to: .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])).systemActions[0]
        }
        XCTAssertEqual(try match().sourceReconciliation, "syntaxCandidate")
        for predicates in [["RELEASE"], ["canImport(AppIntents)"], ["!canImport(Missing)", "DEBUG"]] {
            index.declarations[0].compilationConditions = predicates
            XCTAssertEqual(try match().sourceReconciliation, "unresolved"); XCTAssertTrue(try match().compiled); XCTAssertFalse(try match().registered)
        }
        index.declarations[0].compilationConditions = nil
        XCTAssertEqual(try match().sourceReconciliation, "unresolved")
        XCTAssertTrue(try AutomationSourceDeclarationReader.read(Data("#if DEBUG\nstruct Echo: AppIntent {}\n#endif".utf8), path: "App.swift", owner: "APP").isEmpty)
        XCTAssertTrue(try AutomationSourceDeclarationReader.read(Data("/* trivia */ #if false\nstruct Echo: AppIntent {}\n/* trivia */ #endif".utf8), path: "App.swift", owner: "APP").isEmpty)
    }
}
