#if os(macOS)
import Foundation

/// Product-owned recipe for an installed Tuist v4 distribution and an existing
/// root Project.swift. Picking a folder never executes the generator.
public enum AutomationTuistAutomaticRecipe {
    public static func pin(source: URL, developerDirectory: URL,
                           installedTools: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/tuist"), URL(fileURLWithPath: "/usr/local/bin/tuist")]) throws -> AutomationTuistRecipePin {
        let source = try AutomationPath.canonical(source), developer = try AutomationPath.canonical(developerDirectory)
        let project = try AutomationReadOnlyFile.read(root: source, relativePath: "Project.swift", maximumBytes: 4 * 1024 * 1024)
        guard String(decoding: project, as: UTF8.self).contains("import ProjectDescription") else {
            throw AutomationContractError.missingEvidence("The selected folder has no recognized Tuist Project.swift.")
        }
        var installed: [String: (URL, String)] = [:]
        for selected in installedTools where FileManager.default.isExecutableFile(atPath: selected.path) {
            let executable = try AutomationPath.canonical(selected)
            guard let version = distributionVersion(executable) else { continue }
            installed[executable.path] = (executable, version)
        }
        guard installed.count == 1, let (executable, version) = installed.values.first else {
            throw AutomationContractError.missingEvidence(installed.isEmpty
                ? "A supported installed Tuist v4 distribution is unavailable. Intents does not install generators."
                : "Multiple installed Tuist distributions match this project. Select its existing generator in advanced preparation.")
        }
        try validateProjectVersion(source: source, installedVersion: version)
        let digest = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(executable, maximumBytes: 128 * 1024 * 1024))
        return .init(schemaVersion: 1, version: version, executablePath: executable.path, executableSHA256: digest,
            toolchainSHA256: try AutomationTuistRecipePin.toolchain(developer: developer),
            qualificationEvidence: "intents-installed-tuist-v4-offline-generation-v1", recipePath: "Project.swift",
            recipeSHA256: AutomationArtifactRegistry.digest(project))
    }
    static func distributionVersion(_ executable: URL) -> String? {
        let parts = executable.pathComponents
        guard parts.count >= 5, Array(parts.suffix(2)) == ["bin", "tuist"],
              parts[parts.count - 4] == "tuist", let version = parts.dropLast(2).last,
              version.range(of: #"^4\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        // Accept only known installed distribution layouts; never derive a tool
        // from a project script, PATH executable alias or arbitrary package command.
        let prefix = parts.dropLast(4).joined(separator: "/")
        guard prefix.hasSuffix("/Cellar") || prefix.hasSuffix("/mise/installs") else { return nil }
        return version
    }
    static func validateProjectVersion(source: URL, installedVersion: String) throws {
        for entry in [".tuist-version", ".tool-versions", "mise.toml", ".mise.toml"] {
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent(entry).path) else { continue }
            let text = String(decoding: try AutomationReadOnlyFile.read(root: source, relativePath: entry, maximumBytes: 65_536), as: UTF8.self)
            var pins: [String] = []
            if entry == ".tuist-version" { pins = [text.trimmingCharacters(in: .whitespacesAndNewlines)] }
            else if entry == ".tool-versions" {
                pins = text.split(separator: "\n").filter { $0.split(whereSeparator: { $0.isWhitespace }).first == "tuist" }
                    .map { $0.split(whereSeparator: { $0.isWhitespace }).dropFirst().joined(separator: " ") }
            } else {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0] == "tuist" { pins.append(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))) }
                }
            }
            guard pins.isEmpty || pins == [installedVersion] else {
                throw AutomationContractError.missingEvidence("The project's Tuist version does not match its supported installed generator. Install or select that version yourself, then review preparation again.")
            }
        }
    }
}
#endif
