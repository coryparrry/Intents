#if os(macOS)
import Foundation

/// Recognized installed Expo 55 / React Native 0.83 profile. Ordinary source
/// selection discovers it read-only; the existing configuration executes only
/// in the approved frozen copy. Other versions/configurations stay explicit.
public struct AutomationMetroAutomaticRecipe: Codable, Equatable, Sendable {
    public var sourceRoot: String
    public var appRelativePath: String
    public var delegateRelativePath: String
    public var delegateSHA256: String
    public var expoConfigModuleRelativePath: String
    public var metroModuleRelativePath: String
    public var metroConfigRelativePath: String?
    public var metroConfigModuleRelativePath: String? = nil
    public var nodePath: String
    public var nodeSHA256: String
    public var nodeRuntimeBundlePath: String? = nil
    public var nodeRuntimeTeamID: String? = nil
    public var nodeRuntimeManifestSHA256: String? = nil
    public var inputs: [String: String]
    public var bundleRoot: String
    public var compiledSettingsSHA256: String? = nil
    public var compiledNativeDigest: String? = nil

    public static func discover(source: URL, candidate: AutomationApplicationCandidate,
        nodeTools: [URL]? = nil) throws -> Self? {
        let source = try AutomationPath.canonical(source)
        let project = try AutomationPath.canonical(URL(fileURLWithPath: candidate.containerPath))
        guard candidate.kind == .sourceTarget, project.deletingLastPathComponent().lastPathComponent == "ios",
              project.path.hasPrefix(source.path + "/") else { return nil }
        let app = project.deletingLastPathComponent().deletingLastPathComponent()
        let package = app.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: package.path) else { return nil }
        let rootPackage = try object(package, source: source)
        let dependencies = rootPackage["dependencies"] as? [String: Any] ?? [:]
        guard dependencies["react-native"] != nil else { return nil }
        guard dependencies["expo"] != nil else { throw AutomationContractError.missingEvidence("This React Native development profile is not yet recognized; bundled native builds remain available.") }
        try validateNodeRequirement((rootPackage["engines"] as? [String: Any])?["node"] as? String)
        try validatePublicEnvironment(source: source, app: app)
        let expo = try resolve("expo", from: app, root: source)
        let react = try resolve("react-native", from: app, root: source)
        let expoConfig = try resolve("@expo/metro-config", from: expo, root: source)
        let wrapper = try resolve("@expo/metro", from: expoConfig, root: source)
        let metro = try resolve("metro", from: wrapper, root: source)
        let metroConfigModule = try resolve("metro-config", from: metro, root: source)
        let versions: [(URL, String, String)] = [(expo, "expo", "55.0.23"), (react, "react-native", "0.83.6"),
            (expoConfig, "@expo/metro-config", "55.0.20"), (wrapper, "@expo/metro", "55.1.1"), (metro, "metro", "0.83.7"), (metroConfigModule, "metro-config", "0.83.7")]
        var pins: [String: String] = [:]
        func pin(_ url: URL) throws {
            let canonical = try AutomationPath.canonical(url)
            guard canonical.path.hasPrefix(source.path + "/") else { throw AutomationContractError.invalidIdentity }
            let path = String(canonical.path.dropFirst(source.path.count + 1))
            pins[path] = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: source, relativePath: path, maximumBytes: 4 * 1024 * 1024))
        }
        try pin(package)
        for entry in ["app.config.ts", "app.config.js", "app.json"] {
            if FileManager.default.fileExists(atPath: app.appendingPathComponent(entry).path) { try pin(app.appendingPathComponent(entry)) }
        }
        for (module, name, version) in versions {
            let metadata = module.appendingPathComponent("package.json"), value = try object(metadata, source: source)
            guard value["name"] as? String == name, value["version"] as? String == version else {
                throw AutomationContractError.missingEvidence("The installed Expo/React Native/Metro versions are outside the recognized development profile; no package installation will run.")
            }
            try validateNodeRequirement((value["engines"] as? [String: Any])?["node"] as? String)
            try pin(metadata)
        }
        let delegate = project.deletingLastPathComponent().appendingPathComponent(candidate.name + "/AppDelegate.swift")
        let delegateBytes = try AutomationReadOnlyFile.read(delegate, maximumBytes: 1_048_576)
        let delegateText = String(decoding: delegateBytes, as: UTF8.self)
        try validateDelegate(delegateText)
        try pin(delegate)
        let configs = ["metro.config.js", "metro.config.cjs", "metro.config.json", "metro.config.ts", "metro.config.mjs"].filter {
            FileManager.default.fileExists(atPath: app.appendingPathComponent($0).path)
        }
        guard configs.count <= 1, configs.isEmpty || configs[0] == "metro.config.js" || configs[0] == "metro.config.cjs" else {
            throw AutomationContractError.missingEvidence("The project's Metro configuration is ambiguous or outside the recognized installed profile.")
        }
        if let config = configs.first { try pin(app.appendingPathComponent(config)) }
        let tools = nodeTools ?? defaultNodeTools(excluding: source)
        let nodes = try Set(tools.filter { FileManager.default.isExecutableFile(atPath: $0.path) }.map { try AutomationPath.canonical($0).path })
        guard nodes.count == 1, let node = nodes.first else { throw AutomationContractError.missingEvidence("One installed Node executable is required for the recognized development profile.") }
        let worker = metro.appendingPathComponent("src/DeltaBundler/WorkerFarm.js")
        let workerText = String(decoding: try AutomationReadOnlyFile.read(worker, maximumBytes: 1_048_576), as: UTF8.self)
        guard workerText.contains("this._config.maxWorkers > 1"), workerText.contains("require(\"./Worker\")") else {
            throw AutomationContractError.missingEvidence("The installed Metro worker implementation is not qualified for owned in-process transformation.")
        }
        try pin(worker)
        let provider = react.appendingPathComponent("React/Base/RCTBundleURLProvider.mm")
        let providerText = String(decoding: try AutomationReadOnlyFile.read(provider, maximumBytes: 1_048_576), as: UTF8.self)
        guard providerText.contains("RCT_jsLocation"), providerText.contains("@\"lazy\""), providerText.contains("@\"excludeSource\""), providerText.contains("@\"app\"") else {
            throw AutomationContractError.missingEvidence("The native bundle URL provider is outside the recognized profile.")
        }
        try pin(provider)
        func relative(_ url: URL) -> String { String(url.path.dropFirst(source.path.count + 1)) }
        return .init(sourceRoot: source.path, appRelativePath: relative(app), delegateRelativePath: relative(delegate),
            delegateSHA256: AutomationArtifactRegistry.digest(delegateBytes), expoConfigModuleRelativePath: relative(expoConfig),
            metroModuleRelativePath: relative(metro), metroConfigRelativePath: configs.first.map { relative(app.appendingPathComponent($0)) },
            metroConfigModuleRelativePath: relative(metroConfigModule),
            nodePath: node, nodeSHA256: AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: node), maximumBytes: 128 * 1024 * 1024)),
            inputs: pins, bundleRoot: ".expo/.virtual-metro-entry")
    }
    /// Match the developer's effective PATH first. GUI launches often omit
    /// Homebrew; inspect known installations without running a shell or Node.
    static func defaultNodeTools(searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fallback: [URL] = installedNodeCandidates(), excluding source: URL? = nil) -> [URL] {
        let pathTools = searchPath.split(separator: ":").filter { $0.hasPrefix("/") }
            .prefix(128).map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        for selected in pathTools + fallback {
            guard FileManager.default.isExecutableFile(atPath: selected.path),
                  let canonical = try? AutomationPath.canonical(selected), canonical.lastPathComponent == "node",
                  (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  source.map({ canonical.path != $0.path && !canonical.path.hasPrefix($0.path + "/") }) ?? true else { continue }
            return [canonical]
        }
        return []
    }
    static func installedNodeCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var result = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].map { URL(fileURLWithPath: $0) }
        for relative in [".nvm/versions/node", ".local/share/mise/installs/node", ".volta/tools/image/node"] {
            let root = home.appendingPathComponent(relative)
            let versions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            // Bound discovery of manually installed runtimes. Prefer the newest
            // named version only when no effective PATH or standard install wins.
            result += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .prefix(64).map { $0.appendingPathComponent("bin/node") }
        }
        return result
    }
    static func validateNodeRequirement(_ value: String?) throws {
        guard let value else { return }
        let qualified = [">=18", ">=18.0.0", ">=20", ">=20.0.0", ">=20.19.4", ">=22.0.0", ">=24.0.0", ">=24.21.0", "^24.0.0", "24.x"]
        guard qualified.contains(String(value.filter { !$0.isWhitespace })) else {
            throw AutomationContractError.missingEvidence("The installed project's Node version requirement is outside the recognized Node development profile. Choose a bundled configuration.")
        }
    }
    static func validatePublicEnvironment(source: URL, app: URL) throws {
        for directory in Set([source, app]) {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard !entries.contains(where: { $0.lastPathComponent == ".env" || $0.lastPathComponent.hasPrefix(".env.") }) else {
                throw AutomationContractError.missingEvidence("This development profile depends on environment files excluded from private copies. Choose a bundled configuration; private values are not copied or inferred.")
            }
        }
        for entry in ["app.config.ts", "app.config.js", "metro.config.js", "metro.config.cjs"] {
            let path = app.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let text = String(decoding: try AutomationReadOnlyFile.read(path, maximumBytes: 1_048_576), as: UTF8.self)
            guard !text.contains("process.env") else { throw AutomationContractError.missingEvidence("The app's dynamic environment configuration is outside the recognized private development profile. Choose a bundled configuration.") }
        }
    }
    func verifyNodeRuntime() throws {
        guard nodeRuntimeBundlePath == nil, nodeRuntimeTeamID == nil, nodeRuntimeManifestSHA256 == nil else {
            throw AutomationContractError.missingEvidence("Prepare this development app again using its installed Node executable")
        }
    }
    static func validateDelegate(_ text: String) throws {
        guard text.contains("ExpoReactNativeFactoryDelegate"), text.contains("#if DEBUG"),
              text.contains("RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: \".expo/.virtual-metro-entry\")"),
              text.contains("Bundle.main.url(forResource: \"main\", withExtension: \"jsbundle\")"),
              !text.contains("jsLocation"), !text.contains("packagerScheme"), !text.contains("http://"), !text.contains("https://") else {
            throw AutomationContractError.missingEvidence("The native development endpoint is customized or cannot be resolved from the recognized Expo delegate. Choose a bundled configuration.")
        }
    }
    public func validateCapture(_ manifest: AutomationSourceManifest) throws {
        guard manifest.sourceRoot == sourceRoot, manifest.includesDependencies == true else { throw AutomationContractError.conflictingOperation }
        try manifest.validateCaptureLayout()
        let appRoot = appRelativePath.isEmpty ? sourceRoot : sourceRoot + "/" + appRelativePath
        for excluded in manifest.excludedPaths {
            let origin = try manifest.origin(for: excluded)
            let path = origin.0.appendingPathComponent(origin.1)
            if path.deletingLastPathComponent().path == sourceRoot || path.deletingLastPathComponent().path == appRoot {
                guard path.lastPathComponent != ".env", !path.lastPathComponent.hasPrefix(".env.") else {
                    throw AutomationContractError.missingEvidence("The source gained an excluded environment file after review. Review a bundled configuration; private values are not copied.")
                }
            }
        }
        let configNames: Set<String> = ["app.config.ts", "app.config.js", "app.json", "metro.config.js", "metro.config.cjs", "metro.config.json", "metro.config.ts", "metro.config.mjs"]
        for file in manifest.files {
            let input = URL(fileURLWithPath: file.inputPath)
            if input.deletingLastPathComponent().path == appRoot, configNames.contains(input.lastPathComponent) {
                let path = String(file.inputPath.dropFirst(sourceRoot.count + 1))
                guard inputs[path] == file.sha256 else { throw AutomationContractError.conflictingOperation }
            }
        }
        for (path, digest) in inputs {
            guard manifest.files.contains(where: { $0.inputPath == sourceRoot + "/" + path && $0.symbolicLink == nil && $0.sha256 == digest }) else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
    public func profile(manifest: AutomationSourceManifest, graph: AutomationSourceGraph, app: AppIdentity,
                        compilationConditions: AutomationSourceCompilationConditions) throws -> AutomationServedJavaScriptProfile {
        try validateCapture(manifest)
        try compilationConditions.validate(graph: graph)
        guard graph.configuration == app.configuration,
              compilationConditions.activeConditions?.contains("DEBUG") == true,
              graph.inputs.contains(where: { $0.relativePath.hasSuffix(delegateRelativePath) && $0.sha256 == delegateSHA256 && graph.admitsSwiftDeclarations(role: $0.role) }),
              app.configuration?.caseInsensitiveCompare("Debug") == .orderedSame,
              let product = app.canonicalBundlePath else { throw AutomationContractError.missingEvidence("The recognized development profile requires compiled Debug membership of its Expo app delegate.") }
        let productRoot = URL(fileURLWithPath: product)
        if FileManager.default.fileExists(atPath: productRoot.appendingPathComponent("ip.txt").path) {
            let host = String(decoding: try AutomationReadOnlyFile.read(root: productRoot, relativePath: "ip.txt", maximumBytes: 4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard host == "localhost" || host == "127.0.0.1" else { throw AutomationContractError.missingEvidence("The compiled development endpoint is outside the owned loopback profile.") }
        }
        var components = URLComponents(string: "http://127.0.0.1:8081/" + bundleRoot + ".bundle")!
        components.queryItems = [.init(name: "platform", value: "ios"), .init(name: "dev", value: "true"), .init(name: "lazy", value: "true"),
            .init(name: "minify", value: "false"), .init(name: "inlineSourceMap", value: "false"), .init(name: "modulesOnly", value: "false"),
            .init(name: "runModule", value: "true"), .init(name: "excludeSource", value: "true"), .init(name: "sourcePaths", value: "url-server"), .init(name: "app", value: app.bundleID)]
        var bound = self; bound.compiledSettingsSHA256 = compilationConditions.settingsSHA256; bound.compiledNativeDigest = app.productDigest
        return .init(schemaVersion: 1, executablePath: nodePath, executableSHA256: nodeSHA256,
            scriptRelativePath: "intents-owned-metro-bootstrap.js", scriptSHA256: AutomationArtifactRegistry.digest(Data(AutomationMetroBootstrap.source.utf8)),
            arguments: [], bundleURL: components.url!.absoluteString, bundleSHA256: "", nativeBindingRelativePath: "",
            qualificationEvidence: "intents-expo55-rn083-metro083-native-consumer-v1", recipeRelativePath: "", automaticMetro: bound)
    }
    static func resolve(_ name: String, from directory: URL, root: URL) throws -> URL {
        var cursor = directory
        while cursor.path == root.path || cursor.path.hasPrefix(root.path + "/") {
            let path = cursor.appendingPathComponent("node_modules/" + name)
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("package.json").path) {
                let resolved = try AutomationPath.canonical(path)
                guard resolved.path.hasPrefix(root.path + "/") else { throw AutomationContractError.missingEvidence("Installed dependencies escape the selected source folder. Select their owning repository before preparation.") }
                return resolved
            }
            if cursor == root { break }; cursor.deleteLastPathComponent()
        }
        throw AutomationContractError.missingEvidence("A required installed Metro dependency is missing; Intents does not download packages.")
    }
    private static func object(_ url: URL, source: URL) throws -> [String: Any] {
        let path = try AutomationPath.canonical(url)
        guard path.path.hasPrefix(source.path + "/"), let result = try JSONSerialization.jsonObject(with: AutomationReadOnlyFile.read(path, maximumBytes: 1_048_576)) as? [String: Any] else { throw AutomationContractError.invalidIdentity }
        return result
    }
}
#endif
