#if os(macOS)
import Foundation
import CryptoKit
import Security
import Darwin

/// Validates the sealed private runtime before returning any executable launch paths.
public enum AutomationRuntimeBundle {
    /// A separate private SDK/helper unit is evidence only; never return launch configuration.
    public static func verifiedPrivateMacSDKUnit(root: URL) throws -> AutomationPrivateMacSDKUnit.Evidence {
        try AutomationPrivateMacSDKUnit.verify(root: root)
    }
    struct Manifest: Codable {
        var schemaVersion: Int
        var architecture: String
        var nodeVersion: String
        var files: [String: String]
    }
    static let required = ["Helpers/IntentsAutomationNode", "Helpers/agent-device-macos-helper",
        "Resources/Automation/dist/src/main.js", "Resources/Automation/dependencies.lock.json",
        "Resources/Automation/node_modules/fsevents/fsevents.node",
        "Resources/Automation/node_modules/@esbuild/darwin-arm64/bin/esbuild"]
    public static func verifiedManifestDigest(bundleURL: URL, stateDirectory: URL, expectedTeamID: String) throws -> String {
        _ = try verifiedConfiguration(bundleURL: bundleURL, stateDirectory: stateDirectory, expectedTeamID: expectedTeamID)
        return AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: bundleURL,
            relativePath: "Contents/Resources/Automation/runtime-manifest.json", maximumBytes: 4_194_304))
    }
    public static func verifiedConfiguration(bundleURL: URL, stateDirectory: URL,
                                              expectedTeamID: String, developerDirectory: URL? = nil) throws -> AutomationSidecarProcess.Configuration {
        guard expectedTeamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        #if !arch(arm64)
        throw AutomationContractError.invalidPlan("Only the qualified arm64 runtime is packaged")
        #else
        let bundle = try AutomationPath.canonical(bundleURL), contents = bundle.appendingPathComponent("Contents")
        try verifyAssets(contents: contents)
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw AutomationContractError.invalidIdentity }
        try verifySignature(bundle, requirement: requirement, nested: true)
        for path in [required[0], required[1], required[4], required[5]] {
            try verifySignature(contents.appendingPathComponent(path), requirement: requirement, nested: false)
        }
        return .init(node: contents.appendingPathComponent(required[0]), entry: contents.appendingPathComponent(required[2]),
                     stateDirectory: stateDirectory, helper: contents.appendingPathComponent(required[1]), developerDirectory: developerDirectory)
        #endif
    }
    /// Hash verification is an ingredient, not a substitute for the enclosing signature check.
    static func verifyAssets(contents: URL) throws {
        let assets = contents.appendingPathComponent("Resources/Automation")
        let manifestURL = assets.appendingPathComponent("runtime-manifest.json")
        guard try AutomationPath.canonical(manifestURL).path == manifestURL.path else { throw AutomationContractError.invalidIdentity }
        let handle = try regularFile(manifestURL, maximumBytes: 4_194_304); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_194_305) ?? Data()
        guard data.count <= 4_194_304 else { throw AutomationContractError.invalidIdentity }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.architecture == "arm64", manifest.nodeVersion == "24.21.0",
              manifest.files.count <= 10_000, required.allSatisfy({ manifest.files[$0] != nil }) else {
            throw AutomationContractError.invalidIdentity
        }
        var actual = Set([required[0], required[1]])
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw AutomationContractError.invalidIdentity
        }
        var enumeratedEntries = 0
        for case let file as URL in enumerator {
            enumeratedEntries += 1
            guard enumeratedEntries <= 10_000, enumerator.level <= 32 else { throw AutomationContractError.invalidIdentity }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                guard values.isSymbolicLink != true else { throw AutomationContractError.invalidIdentity }
                continue
            }
            if file == manifestURL { continue }
            guard file.path.hasPrefix(contents.path + "/") else { throw AutomationContractError.invalidIdentity }
            actual.insert(String(file.path.dropFirst(contents.path.count + 1)))
            guard actual.count <= 10_000 else { throw AutomationContractError.invalidIdentity }
        }
        guard !enumerationFailed, actual == Set(manifest.files.keys) else { throw AutomationContractError.invalidIdentity }
        var total = 0
        for (relative, digest) in manifest.files {
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !relative.contains("\\"),
                  digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
            let file = contents.appendingPathComponent(relative), resolved = try AutomationPath.canonical(file)
            if relative.hasPrefix("Resources/Automation/") {
                guard resolved.path.hasPrefix(assets.path + "/") else { throw AutomationContractError.invalidIdentity }
            } else {
                guard [required[0], required[1]].contains(relative), resolved.path == file.path else { throw AutomationContractError.invalidIdentity }
            }
            let input = try regularFile(resolved, maximumBytes: 268_435_456); defer { try? input.close() }
            var hash = SHA256(), bytes = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                bytes += chunk.count; total += chunk.count
                guard bytes <= 268_435_456, total <= 536_870_912 else { throw AutomationContractError.invalidIdentity }
                hash.update(data: chunk)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
    private static func regularFile(_ url: URL, maximumBytes: Int) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AutomationContractError.invalidIdentity }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            close(descriptor); throw AutomationContractError.invalidIdentity
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func verifySignature(_ url: URL, requirement: SecRequirement, nested: Bool) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw AutomationContractError.invalidIdentity
        }
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if nested { flags.insert(SecCSFlags(rawValue: kSecCSCheckNestedCode)) }
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AutomationContractError.invalidIdentity
        }
    }
}
#endif
