#if os(macOS)
import Foundation

/// Existing project-owned qualification. Loading it is read-only; neither Tuist
/// nor its package manager is installed or executed until native recipe approval.
public struct AutomationTuistRecipePin: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var version: String
    public var executablePath: String
    public var executableSHA256: String
    public var toolchainSHA256: [String: String]
    public var qualificationEvidence: String
    public var recipePath: String
    public var recipeSHA256: String? = nil

    static func load(source: URL, url: URL) throws -> Self {
        let path = try AutomationPath.canonical(url)
        guard path.path == url.path, path.path.hasPrefix(source.path + "/"), path.pathExtension == "json",
              FileManager.default.fileExists(atPath: source.appendingPathComponent("Project.swift").path) else {
            throw AutomationContractError.invalidPlan("Select this Tuist project's existing qualification JSON beside Project.swift.")
        }
        let relative = String(path.path.dropFirst(source.path.count + 1))
        let bytes = try AutomationReadOnlyFile.read(root: source, relativePath: relative, maximumBytes: 65_536)
        var value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.schemaVersion == 1, value.version.range(of: #"^4\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              value.recipePath == relative, value.recipeSHA256 == nil,
              !value.qualificationEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.qualificationEvidence.utf8.count <= 4096,
              value.toolchainSHA256.count == 2, value.toolchainSHA256.values.allSatisfy(validDigest) else {
            throw AutomationContractError.invalidPlan("Tuist requires an explicit qualified v4 recipe with installed binary and Xcode toolchain digests.")
        }
        value.recipeSHA256 = AutomationArtifactRegistry.digest(bytes)
        try value.verify(source: source)
        return value
    }
    static func validDigest(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
    func verify(source: URL) throws {
        let executable = try AutomationPath.canonical(URL(fileURLWithPath: executablePath))
        guard executable.path == executablePath, FileManager.default.isExecutableFile(atPath: executable.path),
              executable.lastPathComponent == "tuist", Self.validDigest(executableSHA256) else {
            throw AutomationContractError.missingEvidence("The qualified Tuist executable is not installed at its pinned path.")
        }
        guard executableSHA256 == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(executable, maximumBytes: 128 * 1024 * 1024)),
              recipeSHA256 == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: source, relativePath: recipePath, maximumBytes: 65_536)) else {
            throw AutomationContractError.conflictingOperation
        }
    }
    static func toolchain(developer: URL) throws -> [String: String] {
        let swift = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
        let info = developer.deletingLastPathComponent().appendingPathComponent("version.plist")
        return ["swiftc": AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(AutomationPath.canonical(swift), maximumBytes: 256 * 1024 * 1024)),
                "xcodeVersion": AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(info, maximumBytes: 1_048_576))]
    }
    static func generatedProjects(root: URL) throws -> [String: String] {
        let entries = try AutomationSourceEntryPoints.discover(root)
        guard !entries.projects.isEmpty else { throw AutomationContractError.missingEvidence("Tuist generated no primary project.") }
        var result: [String: String] = [:]
        for project in entries.projects {
            let path = String(project.path.dropFirst(root.path.count + 1)) + "/project.pbxproj"
            result[path] = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 16 * 1024 * 1024))
        }
        for workspace in entries.workspaces {
            let path = String(workspace.path.dropFirst(root.path.count + 1)) + "/contents.xcworkspacedata"
            result[path] = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 1_048_576))
        }
        return result
    }
}
#endif
