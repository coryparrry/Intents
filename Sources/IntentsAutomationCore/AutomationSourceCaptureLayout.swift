import Foundation

extension AutomationSourceManifest {
    public struct CapturedRoot: Codable, Equatable, Sendable {
        public let inputPath: String
        public let relativePath: String
        /// Exact captured content revision, including dirty/untracked files; not a Git revision.
        public let contentDigest: String
    }

    var layoutRoot: String { captureLayoutRoot ?? sourceRoot }
    var approvedRoots: [String] { capturedRoots?.map(\.inputPath) ?? [sourceRoot] }
    var additionalRoots: [String] { Array(approvedRoots.dropFirst()) }

    func includesOrigin(_ path: String) -> Bool {
        approvedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func includesScaffoldOrigin(_ path: String) -> Bool {
        includesOrigin(path) || ((path == layoutRoot || path.hasPrefix(layoutRoot + "/")) && approvedRoots.contains { $0.hasPrefix(path + "/") })
    }

    func origin(for relativePath: String) throws -> (URL, String) {
        if let roots = capturedRoots {
            let matches = roots.filter { relativePath.hasPrefix($0.relativePath + "/") }
            guard matches.count == 1, let root = matches.first else { throw AutomationContractError.invalidIdentity }
            return (URL(fileURLWithPath: root.inputPath), String(relativePath.dropFirst(root.relativePath.count + 1)))
        }
        return (URL(fileURLWithPath: sourceRoot), relativePath)
    }

    func readOrigin(for file: File) throws -> (URL, String) {
        guard let path = file.materializedSourcePath else { return try origin(for: file.relativePath) }
        guard includesDependencies == true, let root = approvedRoots.first(where: { path.hasPrefix($0 + "/") }),
              !AutomationSourceSnapshot.excludes(String(path.dropFirst(root.count + 1)), includesDependencies: true),
              try AutomationPath.canonical(URL(fileURLWithPath: path)).path == path else { throw AutomationContractError.invalidIdentity }
        return (URL(fileURLWithPath: root), String(path.dropFirst(root.count + 1)))
    }

    private func validateDependencyInputs() throws {
        guard includesDependencies == true else {
            guard materializedLinks == nil, files.allSatisfy({ $0.materializedSourcePath == nil }) else { throw AutomationContractError.invalidIdentity }
            return
        }
        guard let links = materializedLinks, links.count <= 100_000,
              Set(links.map(\.relativePath)).count == links.count else { throw AutomationContractError.invalidIdentity }
        let linksByPath = Dictionary(uniqueKeysWithValues: links.map { ($0.relativePath, $0) })
        let filePaths = Set(files.map(\.relativePath))
        let symbolicFilePaths = Set(files.filter { $0.symbolicLink != nil }.map(\.relativePath))
        let directoryPaths = Set(directories)
        let regularInputPaths = Set(files.filter { $0.symbolicLink == nil && $0.frozenSymbolicLink == nil }.map(\.inputPath))
        guard files.allSatisfy({ file in
            if file.symbolicLink == nil && file.frozenSymbolicLink == nil { return true }
            guard file.materializedSourcePath == nil,
                  let link = linksByPath[file.relativePath],
                  AutomationDependencySourceReader.preservesAlias(relativePath: file.relativePath, directory: link.directory),
                  link.directory || regularInputPaths.contains(link.resolvedPath) else { return false }
            return file.symbolicLink == link.destination &&
                file.frozenSymbolicLink == AutomationSourceSnapshot.rebasedLink(relativePath: file.inputPath, target: link.resolvedPath) &&
                file.bytes == link.destination.utf8.count && file.sha256 == AutomationArtifactRegistry.digest(Data(link.destination.utf8))
        }) else { throw AutomationContractError.invalidIdentity }
        func allowed(_ path: String) -> Bool {
            guard AutomationSourceCaptureLayout.absolute(path), let root = approvedRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
            return !AutomationSourceSnapshot.excludes(String(path.dropFirst(root.count + 1)), includesDependencies: true)
        }
        for link in links {
            guard AutomationSourceCaptureLayout.relative(link.relativePath), allowed(link.resolvedPath),
                  !link.destination.isEmpty, link.destination.utf8.count <= 4096, !link.destination.contains("\0"),
                  link.directory ? (directoryPaths.contains(link.relativePath) || symbolicFilePaths.contains(link.relativePath)) : filePaths.contains(link.relativePath) else { throw AutomationContractError.invalidIdentity }
        }
        for file in files where file.materializedSourcePath != nil {
            guard AutomationSourceCaptureLayout.relative(file.relativePath) else { throw AutomationContractError.invalidIdentity }
            // Walk at most 64 components, choosing the nearest exact receipt or
            // directory ancestor without scanning every captured dependency link.
            var components = file.relativePath.split(separator: "/").map(String.init)
            var owner: MaterializedLink?
            while !components.isEmpty {
                let candidate = components.joined(separator: "/")
                if let link = linksByPath[candidate], candidate == file.relativePath || link.directory {
                    owner = link
                    break
                }
                components.removeLast()
            }
            guard allowed(file.materializedSourcePath!), let link = owner,
                  file.materializedSourcePath == link.resolvedPath + String(file.relativePath.dropFirst(link.relativePath.count)) else { throw AutomationContractError.invalidIdentity }
        }
    }

    /// Pure replay validation. Never walks the virtual ancestor or serialized live roots.
    func validateCaptureLayout() throws {
        try validateDependencyInputs()
        if schemaVersion == 1 {
            guard captureLayoutRoot == nil, capturedRoots == nil else { throw AutomationContractError.invalidIdentity }
            return
        }
        guard schemaVersion == 2, let roots = capturedRoots, (2...9).contains(roots.count),
              let layout = captureLayoutRoot, roots.first?.inputPath == sourceRoot,
              roots.dropFirst().map(\.inputPath) == roots.dropFirst().map(\.inputPath).sorted(),
              try AutomationSourceCaptureLayout.commonAncestor(roots.map(\.inputPath)) == layout,
              files.count + directories.count + excludedPaths.count <= 100_000,
              files.allSatisfy({ (0...536_870_912).contains($0.bytes) }), files.reduce(0, { $0 + Int64($1.bytes) }) <= 2_147_483_648,
              Set(files.map(\.relativePath)).count == files.count,
              directories == Array(Set(directories)).sorted(), excludedPaths == Array(Set(excludedPaths)).sorted() else {
            throw AutomationContractError.invalidIdentity
        }
        var covered = Set<String>()
        for root in roots {
            guard root.relativePath == String(root.inputPath.dropFirst(layout.count + 1)), !root.relativePath.isEmpty,
                  root.contentDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
            let components = root.relativePath.split(separator: "/").map(String.init)
            guard (1...components.count).allSatisfy({ directories.contains(components.prefix($0).joined(separator: "/")) }) else { throw AutomationContractError.invalidIdentity }
            let prefix = root.relativePath + "/"
            let owned = files.filter { $0.relativePath.hasPrefix(prefix) }
            let local = try owned.map { file -> File in
                var value = file; value.relativePath = String(file.relativePath.dropFirst(prefix.count))
                guard AutomationSourceCaptureLayout.relative(value.relativePath),
                      file.inputPath == root.inputPath + "/" + value.relativePath else { throw AutomationContractError.invalidIdentity }
                covered.insert(file.relativePath); return value
            }
            var manifest = Self(sourceRoot: root.inputPath, files: local.sorted { $0.relativePath < $1.relativePath },
                directories: directories.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) },
                excludedPaths: excludedPaths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            manifest.includesDependencies = includesDependencies
            manifest.materializedLinks = materializedLinks.map { links in links.filter { $0.relativePath.hasPrefix(prefix) }.map { link in
                var value = link; value.relativePath = String(link.relativePath.dropFirst(prefix.count)); return value
            } }
            guard try manifest.digest == root.contentDigest else { throw AutomationContractError.conflictingOperation }
        }
        guard covered.count == files.count, excludedPaths.allSatisfy({ path in roots.contains { path.hasPrefix($0.relativePath + "/") } }),
              directories.allSatisfy({ path in AutomationSourceCaptureLayout.relative(path) && roots.contains { path == $0.relativePath || path.hasPrefix($0.relativePath + "/") || $0.relativePath.hasPrefix(path + "/") } }) else {
            throw AutomationContractError.invalidIdentity
        }
    }
}

enum AutomationSourceCaptureLayout {
    static func commonAncestor(_ paths: [String]) throws -> String {
        guard (2...9).contains(paths.count), Set(paths).count == paths.count, paths.allSatisfy(absolute) else { throw AutomationContractError.invalidIdentity }
        for a in paths { for b in paths where a != b {
            guard !a.hasPrefix(b + "/") else { throw AutomationContractError.invalidPlan("Source grants must be distinct nonoverlapping folders") }
        } }
        var common = paths[0].split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
        }
        guard !common.isEmpty else { throw AutomationContractError.invalidPlan("Source grants need a shared folder ancestry") }
        return "/" + common.joined(separator: "/")
    }
    static func relative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0") && parts.count <= 64 &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func absolute(_ path: String) -> Bool { path.hasPrefix("/") && relative(String(path.dropFirst())) }

    static func aggregate(_ manifests: [AutomationSourceManifest]) throws -> AutomationSourceManifest {
        guard let primary = manifests.first, manifests.allSatisfy({ $0.schemaVersion == 1 && $0.capturedRoots == nil && $0.captureLayoutRoot == nil }) else {
            throw AutomationContractError.invalidIdentity
        }
        if manifests.count == 1 { return primary }
        let ordered = [primary] + manifests.dropFirst().sorted { $0.sourceRoot < $1.sourceRoot }
        let layout = try commonAncestor(ordered.map(\.sourceRoot))
        var roots: [AutomationSourceManifest.CapturedRoot] = [], files: [AutomationSourceManifest.File] = [], dirs = Set<String>(), excluded: [String] = []
        for manifest in ordered {
            let prefix = String(manifest.sourceRoot.dropFirst(layout.count + 1))
            roots.append(.init(inputPath: manifest.sourceRoot, relativePath: prefix, contentDigest: try manifest.digest))
            let components = prefix.split(separator: "/").map(String.init)
            for count in 1...components.count { dirs.insert(components.prefix(count).joined(separator: "/")) }
            dirs.formUnion(manifest.directories.map { prefix + "/" + $0 })
            excluded += manifest.excludedPaths.map { prefix + "/" + $0 }
            files += manifest.files.map { file in var value = file; value.relativePath = prefix + "/" + file.relativePath; return value }
        }
        var result = AutomationSourceManifest(sourceRoot: primary.sourceRoot, files: files.sorted { $0.relativePath < $1.relativePath }, directories: dirs.sorted(), excludedPaths: excluded.sorted())
        guard manifests.allSatisfy({ $0.includesDependencies == primary.includesDependencies }) else { throw AutomationContractError.invalidIdentity }
        result.includesDependencies = primary.includesDependencies
        result.materializedLinks = primary.materializedLinks == nil ? nil : ordered.flatMap { manifest in
            let prefix = String(manifest.sourceRoot.dropFirst(layout.count + 1))
            return (manifest.materializedLinks ?? []).map { link in var value = link; value.relativePath = prefix + "/" + link.relativePath; return value }
        }.sorted { $0.relativePath < $1.relativePath }
        result.schemaVersion = 2; result.captureLayoutRoot = layout; result.capturedRoots = roots
        try result.validateCaptureLayout(); return result
    }
}
