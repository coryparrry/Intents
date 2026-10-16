#if os(macOS)
import Foundation

/// A developer's existing, explicitly qualified leaf Node recipe. No inferred
/// npm scripts, package installs, Metro adoption or native runtime rewrites.
public struct AutomationServedJavaScriptProfile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var executablePath: String
    public var executableSHA256: String
    public var scriptRelativePath: String
    public var scriptSHA256: String
    public var arguments: [String]
    public var bundleURL: String
    public var bundleSHA256: String
    public var nativeBindingRelativePath: String
    public var qualificationEvidence: String
    public var recipeRelativePath: String
    public var recipeSHA256: String? = nil
    public var automaticMetro: AutomationMetroAutomaticRecipe? = nil

    public static func load(source: URL, url: URL) throws -> Self {
        guard try AutomationPath.canonical(source).path == source.path,
              try AutomationPath.canonical(url).path == url.path, url.path.hasPrefix(source.path + "/") else {
            throw AutomationContractError.invalidIdentity
        }
        let path = String(url.path.dropFirst(source.path.count + 1))
        let bytes = try AutomationReadOnlyFile.read(root: source, relativePath: path, maximumBytes: 65_536)
        var value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.recipeRelativePath == path, value.recipeSHA256 == nil, value.automaticMetro == nil else { throw AutomationContractError.invalidIdentity }
        value.recipeSHA256 = AutomationArtifactRegistry.digest(bytes)
        try value.validate()
        try value.verifyExecutable()
        guard value.scriptSHA256 == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: source, relativePath: value.scriptRelativePath, maximumBytes: 4 * 1024 * 1024)) else {
            throw AutomationContractError.conflictingOperation
        }
        return value
    }
    public var digest: String {
        get throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return AutomationArtifactRegistry.digest(try encoder.encode(self)) }
    }
    var endpoint: URL { URL(string: bundleURL)! }
    var port: Int { URLComponents(string: bundleURL)!.port! }
    func validate() throws {
        let automatic = automaticMetro != nil
        guard schemaVersion == 1, AutomationTuistRecipePin.validDigest(executableSHA256),
              AutomationTuistRecipePin.validDigest(scriptSHA256), AutomationTuistRecipePin.validDigest(bundleSHA256) || (automatic && bundleSHA256.isEmpty),
              automatic || recipeSHA256.map(AutomationTuistRecipePin.validDigest) == true,
              AutomationSourceCaptureLayout.relative(scriptRelativePath), scriptRelativePath.hasSuffix(".js"),
              automatic || (AutomationSourceCaptureLayout.relative(recipeRelativePath) && recipeRelativePath.hasSuffix(".json")),
              automatic || (AutomationSourceCaptureLayout.relative(nativeBindingRelativePath) && nativeBindingRelativePath.hasSuffix(".json")),
              arguments.count <= 32, arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              !qualificationEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, qualificationEvidence.utf8.count <= 4096,
              let value = URLComponents(string: bundleURL), value.scheme == "http", value.host == "127.0.0.1",
              let port = value.port, (1024...65535).contains(port), value.user == nil, value.password == nil,
              value.fragment == nil, !value.path.isEmpty, bundleURL.utf8.count <= 4096,
              value.url?.absoluteString == bundleURL else { throw AutomationContractError.invalidPlan("Select a qualified loopback JavaScript server recipe with exact installed Node, script and bundle digests.") }
        if let automaticMetro {
            guard executablePath == automaticMetro.nodePath, executableSHA256 == automaticMetro.nodeSHA256,
                  scriptSHA256 == AutomationArtifactRegistry.digest(Data(AutomationMetroBootstrap.source.utf8)),
                  qualificationEvidence == "intents-expo55-rn083-metro083-native-consumer-v1", arguments.isEmpty else { throw AutomationContractError.invalidIdentity }
        }
    }
    func verifyExecutable() throws {
        try validate()
        let url = try AutomationPath.canonical(URL(fileURLWithPath: executablePath))
        guard url.path == executablePath,
              url.lastPathComponent == "node" || (automaticMetro?.nodeRuntimeBundlePath != nil && url.lastPathComponent == "IntentsAutomationNode"),
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw AutomationContractError.missingEvidence("The recipe's pinned Node executable is not installed.")
        }
        try automaticMetro?.verifyNodeRuntime()
        guard executableSHA256 == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(url, maximumBytes: 128 * 1024 * 1024)) else { throw AutomationContractError.conflictingOperation }
    }
    public func validateCapture(_ manifest: AutomationSourceManifest) throws {
        try validate()
        try manifest.validateCaptureLayout()
        if let automaticMetro { try automaticMetro.validateCapture(manifest); return }
        for (relative, digest) in [(scriptRelativePath, scriptSHA256), (recipeRelativePath, recipeSHA256!)] {
            let input = URL(fileURLWithPath: manifest.sourceRoot).appendingPathComponent(relative).path
            guard manifest.files.contains(where: { $0.inputPath == input && $0.sha256 == digest && $0.symbolicLink == nil }) else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
    func verifyFrozenInputs(manifest: AutomationSourceManifest, frozenRoot: URL) throws -> URL {
        try validateCapture(manifest)
        if automaticMetro == nil {
            let recipeInput = URL(fileURLWithPath: manifest.sourceRoot).appendingPathComponent(recipeRelativePath).path
            guard let recipe = manifest.files.first(where: { $0.inputPath == recipeInput }) else { throw AutomationContractError.invalidIdentity }
            var decoded = try JSONDecoder().decode(Self.self, from: AutomationReadOnlyFile.read(root: frozenRoot, relativePath: recipe.relativePath, maximumBytes: 65_536))
            guard decoded.recipeSHA256 == nil else { throw AutomationContractError.invalidIdentity }
            decoded.recipeSHA256 = recipeSHA256
            guard decoded == self else { throw AutomationContractError.conflictingOperation }
        }
        for file in manifest.files where file.symbolicLink == nil {
            let suffix = URL(fileURLWithPath: file.relativePath).pathExtension.lowercased()
            // All source/configuration/dependency bytes can affect the response;
            // native project generation is the sole preparation-owned transform.
            guard ["js", "jsx", "ts", "tsx", "json", "cjs", "mjs"].contains(suffix) else { continue }
            let bytes = try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: file.relativePath, maximumBytes: max(1, file.bytes))
            guard bytes.count == file.bytes, AutomationArtifactRegistry.digest(bytes) == file.sha256 else { throw AutomationContractError.conflictingOperation }
        }
        if automaticMetro != nil { return frozenRoot.appendingPathComponent(scriptRelativePath) }
        let input = URL(fileURLWithPath: manifest.sourceRoot).appendingPathComponent(scriptRelativePath).path
        guard let file = manifest.files.first(where: { $0.inputPath == input }) else { throw AutomationContractError.invalidIdentity }
        return frozenRoot.appendingPathComponent(file.relativePath)
    }
    public func validateNativeProduct(app: AppIdentity) throws {
        try validate()
        if let automaticMetro {
            guard app.configuration?.caseInsensitiveCompare("Debug") == .orderedSame,
                  automaticMetro.compiledNativeDigest == app.productDigest,
                  automaticMetro.compiledSettingsSHA256.map(AutomationTuistRecipePin.validDigest) == true else { throw AutomationContractError.invalidIdentity }
            return
        }
        guard let path = app.canonicalBundlePath else { throw AutomationContractError.invalidIdentity }
        let bytes = try AutomationReadOnlyFile.read(root: URL(fileURLWithPath: path), relativePath: nativeBindingRelativePath, maximumBytes: 65_536)
        let binding = try JSONDecoder().decode(NativeBinding.self, from: bytes)
        guard binding.schemaVersion == 1, binding.mode == "served", binding.bundleID == app.bundleID,
              binding.bundleURL == bundleURL else { throw AutomationContractError.missingEvidence("The actual native product does not declare this qualified JavaScript endpoint.") }
    }
    private struct NativeBinding: Decodable { let schemaVersion: Int; let mode: String; let bundleID: String; let bundleURL: String }
}

public struct AutomationServedJavaScriptIdentity: Codable, Equatable, Sendable {
    public let profileDigest: String
    public let sourceManifestDigest: String
    public let nativeProductDigest: String
    public let bundleURL: String
    public let bundleSHA256: String
    public var nodeConfigurationSHA256: String? = nil
    public var digest: String {
        get throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return AutomationArtifactRegistry.digest(try encoder.encode(self)) }
    }
}
#endif
