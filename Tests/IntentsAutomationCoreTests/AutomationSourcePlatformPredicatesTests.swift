import XCTest
@testable import IntentsAutomationCore

final class AutomationSourcePlatformPredicatesTests: XCTestCase {
    private func settings(platform: String, system: String) -> [String: AutomationJSON] {
        ["SWIFT_PLATFORM_TARGET_PREFIX": .string(system), "IS_MACCATALYST": .string("NO"),
         "SUPPORTS_MACCATALYST": .string("NO"), "EFFECTIVE_PLATFORM_NAME": .string("-" + platform)]
    }
    private func platform(_ name: String) -> AutomationBuildPlatform {
        .init(targetName: "App", configuration: "Debug", projectPath: "/private/tmp/App.xcodeproj",
              platformName: name, platformFamily: ["macosx": "macos", "iphoneos": "ios", "iphonesimulator": "ios", "appletvos": "tvos", "appletvsimulator": "tvos", "watchos": "watchos", "watchsimulator": "watchos", "xros": "visionos", "xrsimulator": "visionos"][name]!, sdkRoot: name, supportedPlatforms: [name])
    }
    func testObservedAppleOSAndEnvironmentPredicatesUseSelectedSettings() throws {
        let rows = [("macosx", "macos", "macOS", false), ("iphoneos", "ios", "iOS", false), ("iphonesimulator", "ios", "iOS", true),
                    ("appletvos", "tvos", "tvOS", false), ("appletvsimulator", "tvos", "tvOS", true),
                    ("watchos", "watchos", "watchOS", false), ("watchsimulator", "watchos", "watchOS", true),
                    ("xros", "xros", "visionOS", false), ("xrsimulator", "xros", "visionOS", true)]
        for (name, prefix, system, simulator) in rows {
            let facts = try XCTUnwrap(AutomationSourcePlatformPredicates.read(settings(platform: name, system: prefix), platform: platform(name)))
            try facts.validate()
            func evaluate(_ expression: String) -> Bool? { AutomationSourceCompilationConditions.evaluate(expression, active: nil, platform: facts) }
            XCTAssertEqual(evaluate("os(" + system + ")"), true, name)
            XCTAssertEqual(evaluate("targetEnvironment(simulator)"), simulator, name)
            XCTAssertEqual(evaluate("targetEnvironment(macCatalyst)"), false, name)
            XCTAssertEqual(evaluate("os(Linux) || os(Windows)"), false, name)
            XCTAssertEqual(evaluate("os(" + system + ") && !targetEnvironment(macCatalyst)"), true, name)
            for unknown in ["arch(arm64)", "canImport(AppIntents)", "compiler(>=6.0)", "os(Unknown)", "os(macOS,iOS)", "targetEnvironment(Unknown)"] {
                XCTAssertNil(evaluate(unknown), unknown)
            }
        }
    }
    func testMissingContradictoryAndOverrideFactsRemainUnknown() throws {
        let base = settings(platform: "macosx", system: "macos")
        var variants: [[String: AutomationJSON]] = []
        for (key, value) in [("SWIFT_PLATFORM_TARGET_PREFIX", "ios"), ("IS_MACCATALYST", "YES"), ("SUPPORTS_MACCATALYST", "YES"),
                             ("SDK_VARIANT", "iosmac"), ("EFFECTIVE_PLATFORM_NAME", "-maccatalyst"), ("OTHER_SWIFT_FLAGS", "-target arm64-apple-ios17.0"),
                             ("OTHER_SWIFT_FLAGS", "-Xfrontend -D DEBUG"), ("OTHER_SWIFT_FLAGS", "$(inherited)"), ("OTHER_SWIFT_FLAGS", "-D"),
                             ("OTHER_SWIFT_FLAGS", "-O")] {
            var changed = base; changed[key] = .string(value); variants.append(changed)
        }
        for key in ["SWIFT_PLATFORM_TARGET_PREFIX", "SUPPORTS_MACCATALYST"] { var changed = base; changed.removeValue(forKey: key); variants.append(changed) }
        var wrongType = base; wrongType["OTHER_SWIFT_FLAGS"] = .array([]); variants.append(wrongType)
        for changed in variants { XCTAssertNil(AutomationSourcePlatformPredicates.read(changed, platform: platform("macosx"))) }
        var known = base; known["OTHER_SWIFT_FLAGS"] = .string("-D DEBUG -DEXTRA")
        XCTAssertNotNil(AutomationSourcePlatformPredicates.read(known, platform: platform("macosx")))
        for name in ["iphoneos", "iphonesimulator"] {
            var changed = settings(platform: name, system: "ios"); changed["SDK_VARIANT"] = .string("iosmac")
            XCTAssertNil(AutomationSourcePlatformPredicates.read(changed, platform: platform(name)))
        }
        XCTAssertThrowsError(try AutomationSourcePlatformPredicates(version: 2, operatingSystem: "macOS", environment: "native").validate())
        XCTAssertThrowsError(try AutomationSourcePlatformPredicates(version: 1, operatingSystem: "macOS", environment: "simulator").validate())
    }
    func testPlatformFactsRequireExactOwnerAndRemainOptionalForLegacyRecords() throws {
        var facts = AutomationSourceCompilationConditions(owner: "App.xcodeproj#APP", configuration: "Debug", settingsSHA256: String(repeating: "a", count: 64), activeConditions: nil)
        var declaration = AutomationSourceDeclaration(name: "Echo", protocols: ["AppIntent"], relativePath: "App.swift", owner: facts.owner, line: 1)
        declaration.compilationConditions = ["os(macOS)"]
        XCTAssertNil(AutomationSourceCompilationConditions.resolve(declaration, facts: facts))
        facts.platformPredicates = .init(version: 1, operatingSystem: "macOS", environment: "native")
        XCTAssertEqual(AutomationSourceCompilationConditions.resolve(declaration, facts: facts), true)
        declaration.owner = "Package.swift#target:Dependency"
        XCTAssertNil(AutomationSourceCompilationConditions.resolve(declaration, facts: facts))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(facts)) as? [String: Any])
        json.removeValue(forKey: "platformPredicates")
        let legacy = try JSONDecoder().decode(AutomationSourceCompilationConditions.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.platformPredicates)
    }
    func testRetainedPlatformPredicatesMustRecomputeFromExactSettings() throws {
        let selected = platform("macosx")
        var fields = settings(platform: "macosx", system: "macos")
        fields.merge(["TARGET_NAME": .string("App"), "CONFIGURATION": .string("Debug"), "PROJECT_FILE_PATH": .string(selected.projectPath),
                      "PLATFORM_NAME": .string("macosx"), "SDKROOT": .string("macosx")]) { _, new in new }
        let data = try JSONEncoder().encode(AutomationJSON.array([.object(["target": .string("App"), "buildSettings": .object(fields)])]))
        var graph = AutomationSourceGraph(sourceManifestDigest: String(repeating: "b", count: 64), projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [], inputs: [], declarations: [], gaps: [])
        graph.platformContext = .init(settingsSHA256: AutomationArtifactRegistry.digest(data), developerDirectory: "/Applications/Xcode.app/Contents/Developer", selected: selected, filterFamily: "macos")
        var facts = try AutomationSourceCompilationConditions.read(data, graph: graph, platform: selected)
        XCTAssertNotNil(facts.platformPredicates); try facts.validateDerived(settings: data, graph: graph)
        facts.platformPredicates = .init(version: 1, operatingSystem: "iOS", environment: "simulator")
        XCTAssertThrowsError(try facts.validateDerived(settings: data, graph: graph))
        facts = try AutomationSourceCompilationConditions.read(data, graph: graph, platform: selected)
        graph.platformContext = nil
        XCTAssertThrowsError(try facts.validateDerived(settings: data, graph: graph))
    }
}
