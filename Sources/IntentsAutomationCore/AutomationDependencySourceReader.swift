import Foundation

/// An explicitly approved dependency copy. Confined Node directory and CocoaPods
/// header aliases retain file identity; other aliases become regular inputs.
enum AutomationDependencySourceReader {
    static func preservesAlias(relativePath: String, directory: Bool) -> Bool {
        let parts = relativePath.split(separator: "/")
        if directory { return parts.contains("node_modules") }
        return zip(parts, parts.dropFirst()).contains { $0.0 == "Pods" && $0.1 == "Headers" }
    }
    static func manifest(root: URL, approvedRoots: [URL], budget: inout AutomationSourceReadBudget) throws -> AutomationSourceManifest {
        var files: [AutomationSourceManifest.File] = []
        var directories: [String] = [], excluded: [String] = []
        var links: [AutomationSourceManifest.MaterializedLink] = []

        func origin(_ url: URL) throws -> (URL, String) {
            guard let owner = approvedRoots.first(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }),
                  !AutomationSourceSnapshot.excludes(String(url.path.dropFirst(owner.path.count + 1)), includesDependencies: true) else {
                throw AutomationContractError.invalidPlan("Dependency link points outside the approved source folders or into excluded private files")
            }
            return (owner, String(url.path.dropFirst(owner.path.count + 1)))
        }
        func walk(_ physical: URL, relative: String, ancestors: Set<String>, depth: Int,
                  budget: inout AutomationSourceReadBudget) throws {
            try Task.checkCancellation()
            guard depth <= 64, !ancestors.contains(physical.path) else {
                throw AutomationContractError.invalidPlan("Dependency source contains a directory link cycle or exceeds the depth budget")
            }
            var active = ancestors; active.insert(physical.path)
            let entries = try FileManager.default.contentsOfDirectory(at: physical,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try budget.entry()
                let path = relative.isEmpty ? entry.lastPathComponent : relative + "/" + entry.lastPathComponent
                guard AutomationSourceCaptureLayout.relative(path) else { throw AutomationContractError.invalidIdentity }
                do {
                if AutomationSourceSnapshot.excludes(path, includesDependencies: true) { excluded.append(path); continue }
                let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
                let resolved = try AutomationPath.canonical(entry)
                let (readRoot, readRelative) = try origin(resolved)
                let facts = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values.isSymbolicLink == true {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                    try budget.consume(bytes: destination.utf8.count)
                    links.append(.init(relativePath: path, destination: destination, resolvedPath: resolved.path,
                        directory: facts.isDirectory == true))
                    // Node package managers intentionally create cyclic directory
                    // aliases. Keep their confined aliases rebased to the captured
                    // target instead of recursively duplicating the dependency graph.
                    // CocoaPods header aliases likewise retain Clang #import identity.
                    if (facts.isDirectory == true || facts.isRegularFile == true),
                       preservesAlias(relativePath: path, directory: facts.isDirectory == true) {
                        let virtual = root.appendingPathComponent(path)
                        files.append(.init(inputPath: virtual.path, relativePath: path, bytes: destination.utf8.count,
                            sha256: AutomationArtifactRegistry.digest(Data(destination.utf8)), symbolicLink: destination,
                            frozenSymbolicLink: AutomationSourceSnapshot.rebasedLink(relativePath: virtual.path, target: resolved.path), permissions: 0o700))
                        continue
                    }
                }
                if facts.isDirectory == true {
                    directories.append(path)
                    try walk(resolved, relative: path, ancestors: active, depth: depth + 1, budget: &budget)
                } else {
                    guard facts.isRegularFile == true, let size = facts.fileSize else { throw AutomationContractError.invalidIdentity }
                    let data = try AutomationReadOnlyFile.read(root: readRoot, relativePath: readRelative,
                        maximumBytes: max(1, try budget.readLimit(size: size)))
                    try budget.consume(bytes: data.count)
                    let permissions = (try FileManager.default.attributesOfItem(atPath: resolved.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                    let virtual = root.appendingPathComponent(path).path
                    files.append(.init(inputPath: virtual, relativePath: path, bytes: data.count,
                        sha256: AutomationArtifactRegistry.digest(data), symbolicLink: nil, frozenSymbolicLink: nil,
                        permissions: permissions, materializedSourcePath: resolved.path == virtual ? nil : resolved.path))
                }
                } catch AutomationContractError.invalidIdentity {
                    throw AutomationContractError.invalidPlan("Dependency input is missing, unreadable or unsupported: " + path)
                } catch let error as CocoaError {
                    throw AutomationContractError.invalidPlan("Dependency input could not be read: " + path + " (" + String(error.code.rawValue) + ")")
                }
            }
        }
        try walk(root, relative: "", ancestors: [], depth: 0, budget: &budget)
        var result = AutomationSourceManifest(sourceRoot: root.path, files: files.sorted { $0.relativePath < $1.relativePath },
            directories: directories.sorted(), excludedPaths: excluded.sorted())
        result.includesDependencies = true
        result.materializedLinks = links.sorted { $0.relativePath < $1.relativePath }
        return result
    }
}
