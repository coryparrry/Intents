#if os(macOS)
import Foundation

/// Explicit source recipes run only after native approval, in a frozen copy with
/// OS-enforced write isolation. A raw SwiftPM executable never becomes an app.
public struct AutomationSourceRecipe: Sendable {
    public enum Kind: String, Codable, Sendable { case xcodegen, tuist, swiftPMPackaging }
    public let kind: Kind
    public let source: URL
    public let entry: String
    public let executable: URL
    public let executableDigest: String
    public let entryDigest: String
    public let version: String
    public var qualification: AutomationTuistRecipePin? = nil
    public struct Result: Sendable { public let selection: URL; public let receipt: URL }
    struct Receipt: Codable {
        let kind: Kind; let version: String; let executableDigest: String; let entry: String; let entryDigest: String
        let source: AutomationSourceManifest
        var toolchain: [String: String]? = nil
        var generatedProjects: [String: String]? = nil
    }
    public static func tuist(source: URL, pin: URL) throws -> Self {
        let source = try AutomationPath.canonical(source)
        let value = try AutomationTuistRecipePin.load(source: source, url: pin)
        var recipe = try Self(kind: .tuist, source: source, entry: "Project.swift", executable: URL(fileURLWithPath: value.executablePath), version: value.version)
        guard recipe.executableDigest == value.executableSHA256 else { throw AutomationContractError.conflictingOperation }
        recipe.qualification = value
        return recipe
    }
    public static func tuist(source: URL, developerDirectory: URL) throws -> Self {
        let source = try AutomationPath.canonical(source)
        let pin = try AutomationTuistAutomaticRecipe.pin(source: source, developerDirectory: developerDirectory)
        var recipe = try Self(kind: .tuist, source: source, entry: "Project.swift", executable: URL(fileURLWithPath: pin.executablePath), version: pin.version)
        guard recipe.executableDigest == pin.executableSHA256, recipe.entryDigest == pin.recipeSHA256 else { throw AutomationContractError.conflictingOperation }
        recipe.qualification = pin
        return recipe
    }
    public static func xcodegen(source: URL) throws -> Self {
        let source = try AutomationPath.canonical(source)
        let entry = ["project.yml", "project.yaml", "project.json"].first { FileManager.default.fileExists(atPath: source.appendingPathComponent($0).path) }
        guard let entry else { throw AutomationContractError.missingEvidence("No XcodeGen project specification was found.") }
        let binary = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary else { throw AutomationContractError.missingEvidence("XcodeGen 2.46.0 is required for this qualified project recipe.") }
        let executable = try AutomationPath.canonical(URL(fileURLWithPath: binary))
        let recipe = try Self(kind: .xcodegen, source: source, entry: entry, executable: executable, version: "2.46.0")
        guard recipe.executableDigest == "5b5d393779d405bbe78a2de8130f0bfaa4f90f7295cd3c8436d620b04aaee49a" else {
            throw AutomationContractError.missingEvidence("This XcodeGen binary has not been qualified for the pinned recipe.")
        }
        return recipe
    }
    public static func swiftPMPackaging(source: URL, script: URL) throws -> Self {
        let source = try AutomationPath.canonical(source), script = try AutomationPath.canonical(script)
        guard script.path.hasPrefix(source.path + "/"), script.pathExtension == "sh",
              FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path) else {
            throw AutomationContractError.invalidPlan("Choose this Swift package's existing app-bundle packaging script.")
        }
        let entry = String(script.path.dropFirst(source.path.count + 1))
        let bytes = try AutomationReadOnlyFile.read(root: source, relativePath: entry, maximumBytes: 1_048_576)
        let firstLine = String(decoding: bytes.prefix(512), as: UTF8.self).components(separatedBy: .newlines).first ?? ""
        let interpreters = ["#!/bin/sh": "/bin/sh", "#!/bin/bash": "/bin/bash", "#!/bin/zsh": "/bin/zsh",
                            "#!/usr/bin/env bash": "/bin/bash", "#!/usr/bin/env zsh": "/bin/zsh", "#!/usr/bin/env sh": "/bin/sh"]
        guard let interpreter = interpreters[firstLine] else { throw AutomationContractError.invalidPlan("The packaging script needs a supported sh, bash or zsh interpreter.") }
        return try .init(kind: .swiftPMPackaging, source: source, entry: entry, executable: URL(fileURLWithPath: interpreter), version: "shell-app-bundle-v1")
    }
    private init(kind: Kind, source: URL, entry: String, executable: URL, version: String) throws {
        self.kind = kind; self.source = source; self.entry = entry; self.executable = executable; self.version = version
        executableDigest = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(executable, maximumBytes: 128 * 1024 * 1024))
        entryDigest = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: source, relativePath: entry, maximumBytes: 4 * 1024 * 1024))
    }
    public func run(supportRoot: URL, developerDirectory: URL) async throws -> Result {
        if let qualification { try qualification.verify(source: source) }
        guard executableDigest == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(executable, maximumBytes: 128 * 1024 * 1024)),
              entryDigest == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: source, relativePath: entry, maximumBytes: 4 * 1024 * 1024)) else {
            throw AutomationContractError.conflictingOperation
        }
        let root = supportRoot.appendingPathComponent("SourceRecipes").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.path == (try AutomationPath.canonical(root)).path else { throw AutomationContractError.invalidIdentity }
        let capture = root.appendingPathComponent("capture"), snapshot = capture.appendingPathComponent("source")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: capture)
        guard entryDigest == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: snapshot, relativePath: entry, maximumBytes: 4 * 1024 * 1024)) else { throw AutomationContractError.conflictingOperation }
        let command = AutomationOwnedCommand()
        let developer = try AutomationPath.canonical(developerDirectory)
        if let qualification, qualification.toolchainSHA256 != (try AutomationTuistRecipePin.toolchain(developer: developer)) {
            throw AutomationContractError.conflictingOperation
        }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = ["PATH": developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVELOPER_DIR": developer.path, "HOME": root.path, "CFFIXED_USER_HOME": root.path,
            "TMPDIR": scratch.path + "/", "TMP": scratch.path, "TEMP": scratch.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "CLANG_MODULE_CACHE_PATH": root.appendingPathComponent("module-cache").path, "SWIFTPM_MODULECACHE_OVERRIDE": root.appendingPathComponent("module-cache").path]
        let profile = Self.profile(root: root, executable: executable, developer: developer, originalSource: source)
        try AutomationDurableFile(url: root.appendingPathComponent("isolation.sb"), maximumBytes: 65_536).write(Data(profile.utf8))
        func arguments(_ values: [String]) -> [String] { ["-p", profile, executable.path] + values }
        if kind == .xcodegen || kind == .tuist {
            let check = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: arguments(kind == .tuist ? ["version"] : ["--version"]),
                directory: snapshot, environment: environment, timeout: .seconds(10))
            try AutomationDurableFile(url: root.appendingPathComponent("version.log"), maximumBytes: 2_097_152).write(Data("Exit status: \(check.exitStatus)\n".utf8) + check.stdout + check.stderr)
            guard check.exitStatus == 0, !check.logsTruncated,
                  String(decoding: check.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == (kind == .tuist ? version : "Version: " + version) else {
                throw AutomationContractError.missingEvidence("The pinned generator version or source-isolation capability is unavailable. The source was not generated.")
            }
        }
        let values: [String]
        switch kind {
        case .xcodegen: values = ["generate", "--no-env", "--spec", snapshot.appendingPathComponent(entry).path, "--project", snapshot.path, "--project-root", snapshot.path]
        case .tuist: values = ["generate", "--no-open", "--no-binary-cache", "--path", snapshot.path]
        case .swiftPMPackaging: values = [snapshot.appendingPathComponent(entry).path]
        }
        do {
            let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: arguments(values),
                directory: snapshot, environment: environment, timeout: kind == .xcodegen ? .seconds(60) : .seconds(300))
            try AutomationDurableFile(url: root.appendingPathComponent("recipe.log"), maximumBytes: 2_097_152).write(Data("Exit status: \(result.exitStatus)\n".utf8) + result.stdout + result.stderr)
            guard result.exitStatus == 0, !result.logsTruncated else {
                throw AutomationContractError.missingEvidence("The source recipe did not complete. Its original error and private copy are retained in " + root.path)
            }
            try Task.checkCancellation()
            try AutomationSourceSnapshot.verifyOriginal(manifest)
        } catch {
            try AutomationSourceSnapshot.verifyOriginal(manifest)
            throw error
        }
        let receipt = snapshot.appendingPathComponent("intents-source-recipe.json")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { throw AutomationContractError.conflictingOperation }
        var record = Receipt(kind: kind, version: version, executableDigest: executableDigest, entry: entry, entryDigest: entryDigest, source: manifest)
        if kind == .tuist {
            record.toolchain = try AutomationTuistRecipePin.toolchain(developer: developer)
            guard record.toolchain == qualification?.toolchainSHA256 else { throw AutomationContractError.conflictingOperation }
            record.generatedProjects = try AutomationTuistRecipePin.generatedProjects(root: snapshot)
        }
        try AutomationDurableFile(url: receipt, maximumBytes: 32 * 1024 * 1024).write(JSONEncoder().encode(record))
        if kind == .xcodegen || kind == .tuist {
            guard !(try AutomationApplicationIntake.assess(snapshot)).candidates.isEmpty else { throw AutomationContractError.missingEvidence("The generated project contains no application target.") }
            return .init(selection: snapshot, receipt: receipt)
        }
        let apps = try Self.appBundles(under: snapshot)
        guard apps.count == 1, !(try AutomationApplicationIntake.assess(apps[0])).candidates.isEmpty else {
            throw AutomationContractError.missingEvidence("The packaging recipe must produce one valid .app bundle in its private source folder. A library or raw executable cannot be selected as an app.")
        }
        return .init(selection: apps[0], receipt: receipt)
    }
    static func profile(root: URL, executable: URL, developer: URL, originalSource: URL? = nil) -> String {
        func literal(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let toolRoot = executable.path.contains("/Cellar/") ? executable.deletingLastPathComponent().deletingLastPathComponent().path : executable.path
        let readable = [root.path, toolRoot, developer.deletingLastPathComponent().path, "/System", "/usr", "/bin", "/sbin", "/dev", "/private/var/db/dyld", "/Library/Apple"]
        return "(version 1) (deny default) (allow process*) (allow sysctl-read) (allow mach-lookup) (allow file-read-metadata) " +
            // macOS dyld opens the root directory during startup. This literal
            // admits that directory, not its descendants or user home contents.
            "(allow file-read* (literal \"/\") (literal \"/Library/Preferences/com.apple.dt.Xcode.plist\") " + readable.map { "(subpath " + literal($0) + ")" }.joined(separator: " ") + ") " +
            // Tools must honor the owned scratch environment. A tool that requires
            // ambient user-temporary access fails inside this isolation boundary.
            "(allow file-write* (subpath " + literal(root.path) + ") (literal \"/dev/null\")) " +
            (originalSource.map { "(deny file-write* (subpath " + literal($0.path) + "))" } ?? "")
    }
    static func appBundles(under root: URL) throws -> [URL] {
        var queue: [(URL, Int)] = [(root, 0)], index = 0, visited = 0, result: [URL] = []
        while index < queue.count {
            let (directory, depth) = queue[index]; index += 1
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            visited += entries.count
            guard visited <= 50_000, queue.count <= 5_000 else { throw AutomationContractError.invalidPlan("Packaging output discovery exceeded its bound.") }
            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if entry.pathExtension == "app" { result.append(entry) }
                else if depth < 8 { queue.append((entry, depth + 1)) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
#endif
