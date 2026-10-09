#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationSourceSyntaxTests: XCTestCase {
    func testNestedQualifiedCandidatesCannotMatchUnrelatedTopLevelTypes() throws {
        let graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [],
            inputs: [.init(relativePath: "App.swift", sha256: String(repeating: "b", count: 64), owner: "App.xcodeproj#APP", role: "explicitSwiftMembership")], declarations: [], gaps: [])
        var index = AutomationSourceSyntaxIndex(sourceManifestDigest: graph.sourceManifestDigest, sourceGraphDigest: try graph.digest,
            helperTemplateDigest: String(repeating: "c", count: 64), helperDigest: String(repeating: "d", count: 64), toolchain: [], inputs: graph.inputs,
            declarations: [.init(name: "Echo", protocols: ["AppIntent"], relativePath: "App.swift", owner: "App.xcodeproj#APP", line: 1, qualifiedName: "Echo", column: 1, kind: "struct", compilationConditions: []),
                           .init(name: "Echo", protocols: ["AppIntent"], relativePath: "App.swift", owner: "App.xcodeproj#APP", line: 2, qualifiedName: "Container.Echo", column: 1, kind: "struct", compilationConditions: [])], gaps: [])
        var app = AppIdentity(logicalID: "App", bundleID: "example.app", platform: "macos", productDigest: String(repeating: "e", count: 64))
        app.sourceManifestDigest = graph.sourceManifestDigest; app.owningModule = "App"
        func result(type: String = "App.Container.Echo") throws -> ApplicationSurfaceCatalog {
            app.sourceSyntaxIndexDigest = try index.digest
            let action = ApplicationSurfaceCatalog.SystemAction(id: "Echo", typeName: type, title: "Echo", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
            return try AutomationSourceSyntaxReconciliation.apply(index, graph: graph, to: .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []))
        }
        let nested = try result()
        XCTAssertEqual(nested.systemActions[0].sourceCandidates?.map(\.qualifiedName), ["Container.Echo"])
        XCTAssertEqual(nested.systemActions[0].sourceReconciliation, "syntaxCandidate")
        XCTAssertTrue(nested.systemActions[0].compiled); XCTAssertFalse(nested.systemActions[0].registered); XCTAssertFalse(nested.systemDiscoveryComplete)
        XCTAssertEqual(try result(type: "Foreign.Container.Echo").systemActions[0].sourceReconciliation, "unresolved")
        index.declarations.removeLast()
        XCTAssertEqual(try result().systemActions[0].sourceReconciliation, "unresolved")
        XCTAssertEqual(try result(type: "Container.Echo").systemActions[0].sourceReconciliation, "unresolved")
        index.inputs[0].owner = "UNOWNED"
        XCTAssertThrowsError(try result())
    }
    func testAbsentOptionalToolchainComponentsReportUnavailabilityBeforeLaunch() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/source-syntax-absence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [], inputs: [], declarations: [], gaps: [])
        let command = AutomationOwnedCommand()
        do {
            _ = try await AutomationSourceSyntaxDiscovery.analyze(graph: graph, frozenRoot: root, session: root, developer: root.appendingPathComponent("AbsentDeveloper"), command: command)
            XCTFail("An absent component must not produce syntax evidence")
        } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Selected Xcode source syntax component is absent")) }
        let drained = await command.stopOwned(); XCTAssertTrue(drained)
    }
    func testActualSelectedXcodeParserHandlesExtensionsNestedTypesAndLiteralBodies() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SOURCE_SYNTAX_TEST"] == "1" else { throw XCTSkip("Explicit local Xcode source-scanner qualification") }
        let retained = ProcessInfo.processInfo.environment["INTENTS_SOURCE_SYNTAX_TEST_ROOT"]
        let root = URL(fileURLWithPath: retained ?? "/private/tmp").appendingPathComponent("source-syntax-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        let text = ###"""
        import AppIntents
        let r = #/struct RegexFake: AppIntent,/#
        let s = "prefix \(String("struct StringFake: AppIntent, "))"
        struct Container { struct Echo: AppIntent {} }
        struct Item {}
        extension Item: AppEntity {}
        extension Container /* trivia */ . Echo: AppEntity {}
        enum Choice: AppIntents.AppEnum {}
        struct Spaced: AppIntents /* trivia */ . AppIntent {}
        #if CUSTOM_CONDITION
        struct Conditional: AppIntent {}
        #elseif false
        struct Inactive: AppIntent {}
        #else
        struct Alternate: AppIntent {}
        #endif
        #if canImport(UnknownModule)
        struct Unknown: AppIntent {}
        #elseif CUSTOM_CONDITION
        struct UnknownEarlier: AppIntent {}
        #endif
        #if CUSTOM_CONDITION
        #if !OTHER
        struct Nested: AppIntent {}
        #endif
        #endif
        """###
        let data = Data(text.utf8)
        try data.write(to: source.appendingPathComponent("App.swift"))
        let packageSource = Data("struct PackageAction: AppIntent {}".utf8)
        try packageSource.write(to: source.appendingPathComponent("PackageAction.swift"))
        let graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "a", count: 64),
            projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [],
            inputs: [.init(relativePath: "App.swift", sha256: AutomationArtifactRegistry.digest(data), owner: "App.xcodeproj#APP", role: "explicitSwiftMembership"),
                     .init(relativePath: "PackageAction.swift", sha256: AutomationArtifactRegistry.digest(packageSource), owner: "Package.swift#target:Package", role: "packageSwiftMembership")], declarations: [], gaps: ["Synthetic graph fixture"])
        let command = AutomationOwnedCommand()
        let conditions = AutomationSourceCompilationConditions(owner: "App.xcodeproj#APP", configuration: "Debug", settingsSHA256: String(repeating: "a", count: 64), activeConditions: ["CUSTOM_CONDITION"])
        let index = try await AutomationSourceSyntaxDiscovery.analyze(graph: graph, frozenRoot: source, session: root,
            developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), command: command, compilationConditions: conditions)
        XCTAssertEqual(index.sourceGraphDigest, try graph.digest)
        XCTAssertEqual(index.declarations.map(\.name), ["Echo", "Item", "Echo", "Choice", "Spaced", "Conditional", "Inactive", "Alternate", "Unknown", "UnknownEarlier", "Nested", "PackageAction"])
        let resolved = index.declarations.filter { AutomationSourceCompilationConditions.resolve($0, facts: index.compilationConditions) == true }
        XCTAssertEqual(resolved.map(\.name), ["Echo", "Item", "Echo", "Choice", "Spaced", "Conditional", "Nested", "PackageAction"])
        for name in ["Unknown", "UnknownEarlier"] {
            XCTAssertNil(AutomationSourceCompilationConditions.resolve(try XCTUnwrap(index.declarations.first { $0.name == name }), facts: conditions))
        }
        XCTAssertEqual(index.declarations.first?.qualifiedName, "Container.Echo")
        XCTAssertEqual(index.declarations.filter { $0.kind == "extension" }.map(\.qualifiedName), ["Item", "Container.Echo"])
        XCTAssertEqual(index.declarations.first { $0.name == "Item" }?.kind, "extension")
        XCTAssertEqual(index.coverage, "partial"); XCTAssertFalse(index.gaps.isEmpty)
        XCTAssertEqual(index.toolchain.count, 4); XCTAssertEqual(index.inputs, graph.inputs)
        XCTAssertEqual(index.helperTemplateDigest, AutomationArtifactRegistry.digest(Data(AutomationSourceSyntaxTemplate.source.utf8)))
        let bad = root.appendingPathComponent("bad-request.json")
        try JSONSerialization.data(withJSONObject: ["graphDigest": try graph.digest, "inputs": [["relativePath": "App.swift", "owner": "APP", "sha256": graph.inputs[0].sha256, "source": "struct Forged: AppIntent {}"]]])
            .write(to: bad)
        let rejected = try await command.run(executable: root.appendingPathComponent("source-syntax/source-scanner"), arguments: [bad.path], directory: root,
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertNotEqual(rejected.exitStatus, 0); XCTAssertTrue(rejected.stdout.isEmpty)
        XCTAssertEqual(String(decoding: rejected.stderr, as: UTF8.self), "Source syntax scan unavailable\n")
        let drained = await command.stopOwned(); XCTAssertTrue(drained)
    }
}
#endif
