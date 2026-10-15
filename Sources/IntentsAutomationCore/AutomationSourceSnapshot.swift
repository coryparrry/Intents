import Foundation

public struct AutomationSourceManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var inputPath: String
        public var relativePath: String
        public var bytes: Int
        public var sha256: String
        public var symbolicLink: String?
        public var frozenSymbolicLink: String?
        public var permissions: Int
        public var materializedSourcePath: String? = nil
    }
    public var schemaVersion = 1
    public var sourceRoot: String
    public var captureLayoutRoot: String? = nil
    public var capturedRoots: [CapturedRoot]? = nil
    public var files: [File]
    public var directories: [String]
    public var excludedPaths: [String]
    public var includesDependencies: Bool? = nil
    public var materializedLinks: [MaterializedLink]? = nil
    public struct MaterializedLink: Codable, Equatable, Sendable {
        public var relativePath: String
        public var destination: String
        public var resolvedPath: String
        public var directory: Bool
    }
    public var digest: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return AutomationArtifactRegistry.digest(try encoder.encode(self))
        }
    }
}

/// Captures the current checkout, including dirty and untracked files. Never runs hooks or writes to it.
public enum AutomationSourceSnapshot {
    // Dependency manifests can exceed 16 MiB while remaining within the
    // shared 100,000-entry / 2-GiB content budget. All replay readers share this cap.
    static let maximumManifestBytes = 64 * 1024 * 1024
    static func manifestStore(sessionRoot: URL) throws -> AutomationDurableFile {
        try AutomationDurableFile(url: sessionRoot.appendingPathComponent("source-manifest.json"), maximumBytes: maximumManifestBytes)
    }
    private static let excludedDirectories: Set<String> = [".git", ".build", "DerivedData", "node_modules", ".runtime", ".codex", ".agents", ".aws", ".asc", ".signing", ".wrangler", ".ssh", ".gnupg"]
    static func excludes(_ path: String, includesDependencies: Bool = false) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains(where: { excludedDirectories.contains($0) && !(includesDependencies && $0 == "node_modules") })
            || parts.contains(where: { $0 == ".env" || $0.hasPrefix(".env.") || $0.hasSuffix(".p12") || $0.hasSuffix(".p8") || $0 == ".DS_Store" })
    }
    public static func capture(source: URL, sessionRoot: URL, additionalRoots: [URL] = [], includesDependencies: Bool = false) throws -> AutomationSourceManifest {
        try capture(source: source, sessionRoot: sessionRoot, additionalRoots: additionalRoots, limits: .standard, includesDependencies: includesDependencies)
    }
    static func capture(source: URL, sessionRoot: URL, additionalRoots: [URL], limits: AutomationSourceReadBudget.Limits, includesDependencies: Bool = false) throws -> AutomationSourceManifest {
        _ = try AutomationSourceReadBudget(limits: limits)
        let roots = try validateRoots(source: source, additionalRoots: additionalRoots)
        let original = roots[0]
        let parent = try AutomationPath.canonical(sessionRoot.deletingLastPathComponent())
        let destination = parent.appendingPathComponent(sessionRoot.lastPathComponent)
        guard original.path == source.path, destination.path == sessionRoot.path, !FileManager.default.fileExists(atPath: destination.path),
              roots.allSatisfy({ !destination.path.hasPrefix($0.path + "/") && !$0.path.hasPrefix(destination.path + "/") }) else {
            throw AutomationContractError.invalidIdentity
        }
        return try captureValidated(roots: roots, destination: destination, limits: limits, includesDependencies: includesDependencies)
    }
    /// Checks only the explicitly selected folders, without enumerating their shared ancestor.
    public static func validateRoots(source: URL, additionalRoots: [URL]) throws -> [URL] {
        guard additionalRoots.count <= 8 else { throw AutomationContractError.invalidIdentity }
        let roots = try ([source] + additionalRoots).map { url in
            let value = try AutomationPath.canonical(url)
            guard value.path == url.path, try value.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AutomationContractError.invalidIdentity }
            return value
        }
        guard roots.allSatisfy({ !excludes($0.lastPathComponent) }) else { throw AutomationContractError.invalidPlan("Excluded source folders cannot be capture roots") }
        if roots.count > 1 { _ = try AutomationSourceCaptureLayout.commonAncestor(roots.map(\.path)) }
        return roots
    }
    private static func captureValidated(roots: [URL], destination: URL, limits: AutomationSourceReadBudget.Limits, includesDependencies: Bool) throws -> AutomationSourceManifest {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var stage = "opening the source manifest"
        do {
            let manifestStore = try manifestStore(sessionRoot: destination)
            for attempt in 1...2 {
                let staging = destination.appendingPathComponent("source-attempt-\(attempt)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    stage = "reading approved source folders"
                    let before = try readRoots(roots, limits: limits, includesDependencies: includesDependencies)
                    for relative in before.directories { try FileManager.default.createDirectory(at: staging.appendingPathComponent(relative), withIntermediateDirectories: true) }
                    for file in before.files where file.symbolicLink == nil {
                        stage = "copying " + file.relativePath
                        let (inputRoot, inputRelative) = try before.readOrigin(for: file)
                        let data = try AutomationReadOnlyFile.read(root: inputRoot, relativePath: inputRelative, maximumBytes: max(1, file.bytes))
                        guard data.count == file.bytes, AutomationArtifactRegistry.digest(data) == file.sha256 else { throw AutomationContractError.conflictingOperation }
                        let output = staging.appendingPathComponent(file.relativePath)
                        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: output, options: .withoutOverwriting)
                        // Preserve executable build inputs; approval is still required before executing them.
                        try FileManager.default.setAttributes([.posixPermissions: file.permissions & 0o700], ofItemAtPath: output.path)
                    }
                    for file in before.files where file.symbolicLink != nil {
                        stage = "rebasing " + file.relativePath
                        let output = staging.appendingPathComponent(file.relativePath)
                        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: file.frozenSymbolicLink!)
                    }
                    stage = "verifying unchanged source folders"
                    guard before == (try readRoots(roots, limits: limits, includesDependencies: includesDependencies)) else { throw AutomationContractError.conflictingOperation }
                    let frozen = destination.appendingPathComponent("source")
                    try FileManager.default.moveItem(at: staging, to: frozen)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let encoded = try encoder.encode(before)
                    stage = "saving the source manifest (" + String(encoded.count) + " bytes)"
                    try manifestStore.withLock { try manifestStore.write(encoded) }
                    return before
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    if attempt == 1, error as? AutomationContractError == .conflictingOperation { continue }
                    throw error
                }
            }
            throw AutomationContractError.conflictingOperation
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error as? AutomationContractError == .invalidIdentity { throw AutomationContractError.invalidPlan("Source capture failed while " + stage) }
            throw error
        }
    }
    public static func verifyOriginal(_ manifest: AutomationSourceManifest) throws {
        try verifyOriginal(manifest, limits: .standard)
    }
    static func verifyOriginal(_ manifest: AutomationSourceManifest, limits: AutomationSourceReadBudget.Limits) throws {
        try manifest.validateCaptureLayout()
        guard manifest == (try readRoots(manifest.approvedRoots.map { URL(fileURLWithPath: $0) }, limits: limits, includesDependencies: manifest.includesDependencies == true)) else { throw AutomationContractError.conflictingOperation }
    }
    static func rebasedLink(relativePath: String, target: String) -> String {
        let parent = relativePath.split(separator: "/").dropLast().map(String.init), destination = target.split(separator: "/").map(String.init)
        var common = 0
        while common < parent.count && common < destination.count && parent[common] == destination[common] { common += 1 }
        return (Array(repeating: "..", count: parent.count - common) + destination.dropFirst(common)).joined(separator: "/")
    }
    private static func readRoots(_ roots: [URL], limits: AutomationSourceReadBudget.Limits, includesDependencies: Bool) throws -> AutomationSourceManifest {
        var budget = try AutomationSourceReadBudget(limits: limits), values: [AutomationSourceManifest] = []
        for root in roots {
            try budget.requireAvailable()
            guard !excludes(root.lastPathComponent), try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
            values.append(try includesDependencies ? AutomationDependencySourceReader.manifest(root: root, approvedRoots: roots, budget: &budget) : manifest(root: root, budget: &budget))
        }
        return try AutomationSourceCaptureLayout.aggregate(values)
    }
    private static func manifest(root: URL, budget: inout AutomationSourceReadBudget) throws -> AutomationSourceManifest {
        let root = try AutomationPath.canonical(root)
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw AutomationContractError.invalidIdentity }
        var files: [AutomationSourceManifest.File] = [], directories: [String] = [], excluded: [String] = []
        for case let url as URL in enumerator {
            try budget.entry()
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard relative.split(separator: "/").count <= 64 else { throw AutomationContractError.invalidPlan("Source snapshot exceeds entry budget") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if excludes(relative) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                excluded.append(relative); continue
            }
            if values.isSymbolicLink == true {
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let target = try AutomationPath.canonical(url)
                guard !link.hasPrefix("/"), target.path.hasPrefix(root.path + "/"), !excludes(String(target.path.dropFirst(root.path.count + 1))),
                      try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw AutomationContractError.invalidPlan("Source link requires explicit external-root preparation")
                }
                try budget.consume(bytes: link.utf8.count)
                files.append(.init(inputPath: url.path, relativePath: relative, bytes: link.utf8.count,
                                   sha256: AutomationArtifactRegistry.digest(Data(link.utf8)), symbolicLink: link, frozenSymbolicLink: rebasedLink(relativePath: relative, target: String(target.path.dropFirst(root.path.count + 1))), permissions: 0o700))
            } else if values.isDirectory == true { directories.append(relative); continue }
            else {
                guard values.isRegularFile == true else { throw AutomationContractError.invalidPlan("Unsupported source file type") }
                guard let size = values.fileSize else { throw AutomationContractError.missingEvidence("Source file size is unavailable") }
                let limit = try budget.readLimit(size: size)
                let data = try AutomationReadOnlyFile.read(root: root, relativePath: relative, maximumBytes: limit)
                try budget.consume(bytes: data.count)
                files.append(.init(inputPath: url.path, relativePath: relative, bytes: data.count,
                                   sha256: AutomationArtifactRegistry.digest(data), symbolicLink: nil, frozenSymbolicLink: nil,
                                   permissions: (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0))
            }
        }
        guard !enumerationFailed else { throw AutomationContractError.missingEvidence("Source enumeration was incomplete") }
        return .init(sourceRoot: root.path, files: files.sorted { $0.relativePath < $1.relativePath }, directories: directories.sorted(), excludedPaths: excluded.sorted())
    }
}
