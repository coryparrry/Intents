#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationAutomaticIntakeTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/automatic-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ data: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    func testTuistOrdinaryRecipePinsInstalledDistributionWithoutCustomerJSON() throws {
        let root = try root(), source = root.appendingPathComponent("input"), developer = root.appendingPathComponent("Xcode.app/Contents/Developer")
        try write("import ProjectDescription\nlet project = Project(name: \"App\", targets: [])", to: source.appendingPathComponent("Project.swift"))
        try write("compiler fixture", to: developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"))
        try write("Xcode version fixture", to: developer.deletingLastPathComponent().appendingPathComponent("version.plist"))
        let tool = root.appendingPathComponent("Cellar/tuist/4.30.0/bin/tuist")
        try write("installed binary fixture", to: tool, executable: true)
        let pin = try AutomationTuistAutomaticRecipe.pin(source: source, developerDirectory: developer, installedTools: [tool])
        XCTAssertEqual(pin.version, "4.30.0")
        XCTAssertEqual(pin.recipePath, "Project.swift")
        XCTAssertEqual(pin.recipeSHA256, AutomationArtifactRegistry.digest(try Data(contentsOf: source.appendingPathComponent("Project.swift"))))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["Project.swift"])
        try pin.verify(source: source)
        try write("tuist 4.31.0\n", to: source.appendingPathComponent(".tool-versions"))
        XCTAssertThrowsError(try AutomationTuistAutomaticRecipe.pin(source: source, developerDirectory: developer, installedTools: [tool]))
    }
    func testTuistMissingAmbiguousOrOpaqueExecutableRefused() throws {
        let root = try root(), source = root.appendingPathComponent("input"), developer = root.appendingPathComponent("Xcode.app/Contents/Developer")
        try write("import ProjectDescription", to: source.appendingPathComponent("Project.swift"))
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AutomationTuistAutomaticRecipe.pin(source: source, developerDirectory: developer, installedTools: []))
        let a = root.appendingPathComponent("Cellar/tuist/4.30.0/bin/tuist"), b = root.appendingPathComponent("Cellar/tuist/4.31.0/bin/tuist")
        try write("a", to: a, executable: true); try write("b", to: b, executable: true)
        XCTAssertThrowsError(try AutomationTuistAutomaticRecipe.pin(source: source, developerDirectory: developer, installedTools: [a, b]))
        XCTAssertNil(AutomationTuistAutomaticRecipe.distributionVersion(root.appendingPathComponent("scripts/tuist")))
        XCTAssertNil(AutomationTuistAutomaticRecipe.distributionVersion(root.appendingPathComponent("Cellar/tuist/latest/bin/tuist")))
    }
    func testPrivateEnvironmentAndUnsupportedNodeRequirementsDoNotSilentlyChangeConfig() throws {
        let root = try root(), app = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNoThrow(try AutomationMetroAutomaticRecipe.validatePublicEnvironment(source: root, app: app))
        try write("PRIVATE_VALUE=secret", to: app.appendingPathComponent(".env"))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validatePublicEnvironment(source: root, app: app))
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent(".env"), encoding: .utf8), "PRIVATE_VALUE=secret")
        try FileManager.default.removeItem(at: app.appendingPathComponent(".env"))
        try write("export default {name: process.env.APP_NAME}", to: app.appendingPathComponent("app.config.js"))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validatePublicEnvironment(source: root, app: app))
        XCTAssertNoThrow(try AutomationMetroAutomaticRecipe.validateNodeRequirement(">=20.19.4"))
        XCTAssertNoThrow(try AutomationMetroAutomaticRecipe.validateNodeRequirement(nil))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateNodeRequirement(">=26"))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateNodeRequirement("latest"))
    }
    func testEnvironmentAndConfigurationChangesBetweenReviewAndCaptureAreRefused() throws {
        let root = try root(), source = root.appendingPathComponent("source"), app = source.appendingPathComponent("app")
        let config = app.appendingPathComponent("app.config.js")
        try write("export default {name:'App'}", to: config)
        let hash = String(repeating: "a", count: 64)
        let recipe = AutomationMetroAutomaticRecipe(sourceRoot: source.path, appRelativePath: "app", delegateRelativePath: "app/ios/App/AppDelegate.swift",
            delegateSHA256: hash, expoConfigModuleRelativePath: "node_modules/@expo/metro-config", metroModuleRelativePath: "node_modules/metro",
            metroConfigRelativePath: nil, nodePath: "/node", nodeSHA256: hash,
            inputs: ["app/app.config.js": AutomationArtifactRegistry.digest(try Data(contentsOf: config))], bundleRoot: ".expo/.virtual-metro-entry")
        let first = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("first"), includesDependencies: true)
        XCTAssertNoThrow(try recipe.validateCapture(first))
        try write("PRIVATE_VALUE=fixture", to: app.appendingPathComponent(".env"))
        let environment = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("environment"), includesDependencies: true)
        XCTAssertFalse(environment.files.contains { $0.relativePath.hasSuffix(".env") })
        XCTAssertThrowsError(try recipe.validateCapture(environment))
        try FileManager.default.removeItem(at: app.appendingPathComponent(".env"))
        try write("export default {name:process.env.APP_NAME}", to: config)
        let changed = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("changed"), includesDependencies: true)
        XCTAssertThrowsError(try recipe.validateCapture(changed))
    }
    func testStandaloneExpoRootUsesCanonicalPackageAndConfigInputs() throws {
        let root = try root(), source = root.appendingPathComponent("app")
        try write("{\"name\":\"App\"}", to: source.appendingPathComponent("package.json"))
        try write("export default {name:'App'}", to: source.appendingPathComponent("app.config.js"))
        let hash = String(repeating: "a", count: 64)
        let recipe = AutomationMetroAutomaticRecipe(sourceRoot: source.path, appRelativePath: "", delegateRelativePath: "ios/App/AppDelegate.swift",
            delegateSHA256: hash, expoConfigModuleRelativePath: "node_modules/@expo/metro-config", metroModuleRelativePath: "node_modules/metro",
            metroConfigRelativePath: nil, metroConfigModuleRelativePath: "node_modules/metro-config", nodePath: "/node", nodeSHA256: hash,
            inputs: ["package.json": AutomationArtifactRegistry.digest(try Data(contentsOf: source.appendingPathComponent("package.json"))),
                     "app.config.js": AutomationArtifactRegistry.digest(try Data(contentsOf: source.appendingPathComponent("app.config.js")))], bundleRoot: ".expo/.virtual-metro-entry")
        let capture = root.appendingPathComponent("capture")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: capture, includesDependencies: true)
        XCTAssertNoThrow(try recipe.validateCapture(manifest))
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let profile = AutomationServedJavaScriptProfile(schemaVersion: 1, executablePath: "/node", executableSHA256: hash,
            scriptRelativePath: "server.js", scriptSHA256: hash, arguments: [], bundleURL: "http://127.0.0.1:8081/index.bundle", bundleSHA256: hash,
            nativeBindingRelativePath: "binding.json", qualificationEvidence: "test", recipeRelativePath: "profile.json", recipeSHA256: hash)
        let generated = try AutomationMetroBootstrap.write(recipe: recipe, manifest: manifest, frozenRoot: capture.appendingPathComponent("source"), profile: profile, session: session)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: generated.1)) as? [String: String]
        XCTAssertEqual(config?["root"], capture.appendingPathComponent("source").path)
        XCTAssertEqual(config?["app"], "")
        try write("export default {name:process.env.APP_NAME}", to: source.appendingPathComponent("app.config.js"))
        let changed = try AutomationSourceSnapshot.capture(source: source, sessionRoot: root.appendingPathComponent("changed"), includesDependencies: true)
        XCTAssertThrowsError(try recipe.validateCapture(changed))
    }
    func testNativeMetroURLOverridesAndAmbiguousDefaultsAreRefused() throws {
        let recognized = """
        class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
          override func bundleURL() -> URL? {
        #if DEBUG
          return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: ".expo/.virtual-metro-entry")
        #else
          return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        #endif
          }
        }
        """
        XCTAssertNoThrow(try AutomationMetroAutomaticRecipe.validateDelegate(recognized))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateDelegate(recognized + "\nlet jsLocation = \"other\""))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateDelegate(recognized.replacingOccurrences(of: ".expo/.virtual-metro-entry", with: "other")))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateDelegate(recognized.replacingOccurrences(of: "#if DEBUG", with: "#if STAGING")))
        XCTAssertThrowsError(try AutomationMetroAutomaticRecipe.validateDelegate(recognized + "\nlet server = \"http://example.com\""))
    }
    func testNativeConsumerNeedsExactSocketDirectionSelectedDeviceAndProductBytes() throws {
        let bytes = Data("p100\nf19\nn127.0.0.1:50001->127.0.0.1:8081\np200\nf20\nn127.0.0.1:8081->127.0.0.1:50001\n".utf8)
        XCTAssertEqual(try AutomationMetroNativeConsumer.clientPID(bytes: bytes, clientPort: 50001, serverPort: 8081), 100)
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.clientPID(bytes: bytes, clientPort: 50002, serverPort: 8081))
        let root = try root(), target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let bundle = root.appendingPathComponent("CoreSimulator/Devices/" + target.id + "/data/Containers/Bundle/Application/" + UUID().uuidString + "/Demo.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertNoThrow(try AutomationMetroNativeConsumer.validateInstalledPath(bundle, target: target))
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.validateInstalledPath(bundle, target: .init(id: UUID().uuidString, kind: .simulator)))
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: "selected-product")
        let info: [String: Any] = ["CFBundleIdentifier": "example.App", "CFBundleExecutable": "Demo"]
        let executable = bundle.appendingPathComponent("Demo")
        XCTAssertNoThrow(try AutomationMetroNativeConsumer.validateProduct(app: app, digest: "selected-product", info: info, executable: executable))
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.validateProduct(app: app, digest: "arbitrary-client", info: info, executable: executable))
    }
    func testNativeRequestExactFlagsAndStableIdentityAreRequired() throws {
        let approved = "http://127.0.0.1:8081/.expo/.virtual-metro-entry.bundle?platform=ios&dev=true&app=example.App"
        XCTAssertTrue(AutomationMetroNativeConsumer.sameRequest("http://localhost:8081/.expo/.virtual-metro-entry.bundle?app=example.App&dev=true&platform=ios", approved))
        XCTAssertFalse(AutomationMetroNativeConsumer.sameRequest("/.expo/.virtual-metro-entry.bundle?platform=ios&dev=false&app=example.App", approved))
        XCTAssertFalse(AutomationMetroNativeConsumer.sameRequest("http://example.com:8081/.expo/.virtual-metro-entry.bundle?platform=ios&dev=true&app=example.App", approved))
        XCTAssertFalse(AutomationMetroNativeConsumer.sameRequest("/.expo/.virtual-metro-entry.bundle?platform=ios&dev=true&app=example.App&extra=1", approved))
        let identity = AutomationServedJavaScriptIdentity(profileDigest: "profile", sourceManifestDigest: "source", nativeProductDigest: "native", bundleURL: approved, bundleSHA256: "actual-served-bytes")
        XCTAssertEqual(try identity.digest, try JSONDecoder().decode(AutomationServedJavaScriptIdentity.self, from: JSONEncoder().encode(identity)).digest)
        let changed = AutomationServedJavaScriptIdentity(profileDigest: "profile", sourceManifestDigest: "source", nativeProductDigest: "other-native", bundleURL: approved, bundleSHA256: "actual-served-bytes")
        XCTAssertNotEqual(try identity.digest, try changed.digest)
    }
    func testNativeOnlyResultDoesNotClaimJavaScriptAndUIRequiresActualNativeConsumption() throws {
        let hash = String(repeating: "a", count: 64)
        let url = "http://127.0.0.1:8081/index.bundle?platform=ios&dev=true&modulesOnly=false&runModule=true&app=example.App"
        let profile = AutomationServedJavaScriptProfile(schemaVersion: 1, executablePath: "/node", executableSHA256: hash,
            scriptRelativePath: "server.js", scriptSHA256: hash, arguments: [], bundleURL: url, bundleSHA256: hash,
            nativeBindingRelativePath: "binding.json", qualificationEvidence: "test", recipeRelativePath: "profile.json", recipeSHA256: hash)
        let empty = AutomationMetroNativeConsumer.State(pending: [], delivered: [])
        XCTAssertNil(try AutomationMetroNativeConsumer.validateState(empty, profile: profile, proofs: [:], required: false))
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.validateState(empty, profile: profile, proofs: [:], required: true))
        let primary = "/index.bundle?platform=ios&dev=true&modulesOnly=false&runModule=true&app=example.App"
        let split = "/feature.bundle?platform=ios&dev=true&modulesOnly=true&runModule=false&app=example.App"
        XCTAssertTrue(AutomationMetroNativeConsumer.admittedRequest(split, url))
        XCTAssertFalse(AutomationMetroNativeConsumer.admittedRequest(split.replacingOccurrences(of: "dev=true", with: "dev=false"), url))
        let splitHash = String(repeating: "b", count: 64)
        let state = AutomationMetroNativeConsumer.State(pending: [], delivered: [.init(id: 1, port: 50000, url: primary, sha256: hash), .init(id: 2, port: 50001, url: split, sha256: splitHash)])
        let proof = AutomationMetroNativeConsumer.Proof(process: .init(pid: 42, startIdentity: "123:0"), installedProduct: "native", bundleSHA256: hash)
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.validateState(state, profile: profile, proofs: [:], required: true), "An arbitrary client's requests cannot prove selected-app consumption")
        let responses = try AutomationMetroNativeConsumer.validateState(state, profile: profile, proofs: [1: proof, 2: proof], required: true)
        XCTAssertEqual(responses?[primary], hash)
        XCTAssertEqual(responses?[split], splitHash)
        var inFlight = state; inFlight.inFlight = 1
        XCTAssertThrowsError(try AutomationMetroNativeConsumer.validateState(inFlight, profile: profile, proofs: [1: proof, 2: proof], required: true))
    }
}
#endif
