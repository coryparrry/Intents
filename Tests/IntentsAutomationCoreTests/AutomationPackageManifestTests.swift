import XCTest
@testable import IntentsAutomationCore

final class AutomationPackageManifestTests: XCTestCase {
    private func read(_ text: String) throws -> AutomationPackageManifest.Manifest? { try AutomationPackageManifest.read(Data(text.utf8)) }
    func testLiteralProductsAndImmutableMembershipArrays() throws {
        let manifest = try XCTUnwrap(read("""
        // swift-tools-version: 6.0
        import PackageDescription
        let excluded = ["Hidden", "Unused.swift"]
        let package = Package(name: "Local", products: [.library(name: "Local", targets: ["Main"])], targets: [
            .target(name: "Main", dependencies: ["Shared", .target(name: "Other")], path: "Code", exclude: excluded, sources: ["Main.swift"]),
            .target(name: "Shared", path: "Shared"), .target(name: "Other", path: "Other")
        ])
        """))
        XCTAssertEqual(manifest.products[0].targets, ["Main"])
        XCTAssertEqual(manifest.targets[0].dependencies, ["Shared", "Other"])
        XCTAssertEqual(manifest.targets[0].exclude, ["Hidden", "Unused.swift"])
        XCTAssertTrue(manifest.targets[0].membershipAvailable)
    }
    func testDynamicConditionalMutatedOrDuplicateDeclarationsAreUnresolved() throws {
        let good = "import PackageDescription\nlet package = Package(name: \"Local\", products: [.library(name: \"Local\", targets: [\"Main\"])], targets: [.target(name: \"Main\", path: \"Code\")])"
        XCTAssertNotNil(try read(good))
        for type in [".static", ".dynamic", "nil"] {
            XCTAssertNotNil(try read(good.replacingOccurrences(of: ".library(name: \"Local\", targets:", with: ".library(name: \"Local\", type: " + type + ", targets:")))
        }
        for text in [good + "\npackage.targets.append(.target(name: \"Foreign\"))", good.replacingOccurrences(of: "let package", with: "var package"),
                     "#if os(macOS)\n" + good + "\n#endif", good.replacingOccurrences(of: "path: \"Code\"", with: "path: ProcessInfo.processInfo.environment[\"PATH\"]"),
                     good.replacingOccurrences(of: "path: \"Code\"", with: "path: \"Code\" + suffix"), good.replacingOccurrences(of: "path: \"Code\"", with: "path: \"Code\", path: \"Other\""),
                     good.replacingOccurrences(of: "name: \"Local\", products:", with: "products:"),
                     good.replacingOccurrences(of: "name: \"Local\", products:", with: "name: computeName(), products:"),
                     good.replacingOccurrences(of: "products:", with: "platforms: computePlatforms(), products:"),
                     good.replacingOccurrences(of: ".library(name: \"Local\", targets:", with: ".library(name: \"Local\", unknown: computeValue(), targets:"),
                     good.replacingOccurrences(of: ".library(name: \"Local\", targets:", with: ".library(name: \"Local\", type: computeType(), targets:"),
                     good.replacingOccurrences(of: ".library(name: \"Local\", targets:", with: ".library(name: \"Local\", type: .unknown, targets:"),
                     good.replacingOccurrences(of: "[.target(name: \"Main\", path: \"Code\")]", with: "[.target(name: \"Main\"), .target(name: \"Main\")]"), good + "/* unclosed"] {
            XCTAssertNil(try read(text), text)
        }
    }
    func testRepositoryCoreProductHasLiteralReachableDeclarations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try XCTUnwrap(AutomationPackageManifest.read(Data(contentsOf: root.appendingPathComponent("Package.swift"))))
        XCTAssertEqual(manifest.productsByName["IntentsAutomationCore"]?.targets, ["IntentsAutomationCore"])
        XCTAssertEqual(manifest.targetsByName["IntentsAutomationCore"]?.dependencies, ["IntentsAutomationDateCodec", "IntentLabContracts"])
        for name in ["IntentsAutomationCore", "IntentsAutomationDateCodec", "IntentLabContracts"] { XCTAssertTrue(try XCTUnwrap(manifest.targetsByName[name]).membershipAvailable) }
    }
    func testGeneratorsAndConditionalDependenciesStayVisibleAndPartial() throws {
        let manifest = try XCTUnwrap(read("""
        import PackageDescription
        let package = Package(name: "Local", products: [.library(name: "Local", targets: ["Main"])], targets: [
            .target(name: "Main", dependencies: [.target(name: "Conditional", condition: .when(platforms: [.iOS])), .product(name: "Remote", package: "remote")], path: "Code", plugins: [.plugin(name: "Generator")]),
            .macro(name: "Macro", path: "Macro")
        ])
        """))
        XCTAssertFalse(manifest.targets[0].membershipAvailable)
        XCTAssertTrue(manifest.targets[0].dependencies.isEmpty)
        XCTAssertEqual(manifest.targets[0].conditionalDependencies.map(\.name), ["Conditional"])
        XCTAssertEqual(manifest.targets[0].conditionalDependencies.first?.platforms, ["ios"])
        XCTAssertTrue(manifest.targets[0].destinationConditionsAvailable)
        XCTAssertFalse(manifest.targets[1].destinationConditionsAvailable)
        XCTAssertEqual(manifest.targets[0].products.map(\.name), ["Remote"])
        XCTAssertEqual(manifest.targets[0].products.map(\.package), ["remote"])
        XCTAssertFalse(manifest.targets[1].membershipAvailable)
    }

    func testLiteralPlatformConditionsAreDataAndOpaqueConditionsRemainGaps() throws {
        func manifest(_ condition: String) throws -> AutomationPackageManifest.Manifest {
            try XCTUnwrap(read("import PackageDescription\nlet package = Package(name: \"Local\", products: [], targets: [.target(name: \"Main\", dependencies: [.target(name: \"Child\", condition: " + condition + "), .product(name: \"ChildProduct\", package: \"child\", condition: " + condition + ")])])"))
        }
        let parsed = try manifest(".when(platforms: [.macOS, .iOS, .macCatalyst])")
        XCTAssertEqual(parsed.targets[0].conditionalDependencies.first?.platforms, ["ios", "maccatalyst", "macos"])
        XCTAssertEqual(parsed.targets[0].products.first?.platforms, ["ios", "maccatalyst", "macos"])
        XCTAssertTrue(parsed.targets[0].gaps.isEmpty)
        for condition in [".when()", ".when(configuration: .release)", ".when(platforms: [])", ".when(platforms: [.iOS, .iOS])", ".when(platforms: [.futureOS])", ".when(platforms: [\"iOS\"])", ".when(platforms: [.iOS], configuration: .debug)", ".when(platforms: [.iOS], traits: [\"experimental\"])"] {
            let parsed = try manifest(condition)
            XCTAssertTrue(parsed.targets[0].conditionalDependencies.isEmpty)
            XCTAssertTrue(parsed.targets[0].products.isEmpty)
            XCTAssertEqual(parsed.targets[0].gaps.count, 2)
        }
        XCTAssertNil(try read("import PackageDescription\nlet destinations = [.iOS]\nlet package = Package(name: \"Local\", products: [], targets: [.target(name: \"Main\", dependencies: [.target(name: \"Child\", condition: .when(platforms: destinations))])])"))
    }

    func testBudgetsAndStringsCannotInjectDeclarations() throws {
        XCTAssertNil(try AutomationPackageManifest.read(Data(repeating: 32, count: 1_048_577)))
        XCTAssertNil(try read("let x = " + String(repeating: "[", count: 66) + "\"x\"" + String(repeating: "]", count: 66)))
        XCTAssertNil(try read("let x = [\"prefix\\(injected())\"]"))
        XCTAssertNil(try read("let x = [\"" + String(repeating: "a", count: 4097) + "\"]"))
        let text = "import PackageDescription\nlet package = Package(name: \".target(name: Fake)\", products: [], targets: [])"
        let manifest = try XCTUnwrap(read(text)); XCTAssertTrue(manifest.targets.isEmpty)
    }
}
