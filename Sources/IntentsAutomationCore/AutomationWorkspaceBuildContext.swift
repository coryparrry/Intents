import Foundation

/// The workspace and owned schemes used by Xcode, all inside the approved snapshot.
public struct AutomationWorkspaceBuildContext: Codable, Equatable, Sendable {
    public var relativePath: String
    public var subjectScheme: String
    public var projectPaths: [String]
    public var generatedFiles: [String: String]

    static func prepare(workspaceRelativePath: String, selectedProject: AutomationRebasedProject,
                        targetID: String, name: String, manifest: AutomationSourceManifest) throws -> Self {
        let source = selectedProject.session.appendingPathComponent("source")
        let workspace = source.appendingPathComponent(workspaceRelativePath)
        let resolution = try AutomationWorkspaceProjects.resolve(workspace, authorizedRoot: source)
        guard resolution.gaps.isEmpty, resolution.projects.contains(selectedProject.project) else {
            throw AutomationContractError.missingEvidence("The workspace has unresolved project references. Grant its complete source folder before building.")
        }
        var projects: [String] = []
        var files: [String: String] = [:]
        for project in resolution.projects {
            let relative = String(project.path.dropFirst(source.path.count + 1))
            if project != selectedProject.project {
                _ = try AutomationHostGenerator.isolateProject(sessionRoot: selectedProject.session, projectRelativePath: relative)
            }
            projects.append(relative)
            if project != selectedProject.project {
                files[relative + "/project.pbxproj"] = try digest(source, relative + "/project.pbxproj")
            }
        }
        let refs = resolution.projects.map { "<FileRef location=\"group:" + escape(relative($0, to: workspace.deletingLastPathComponent())) + "\"/>" }.joined()
        let contents = workspaceRelativePath + "/contents.xcworkspacedata"
        try Data(("<?xml version=\"1.0\"?><Workspace version=\"1.0\">" + refs + "</Workspace>").utf8).write(to: source.appendingPathComponent(contents), options: .atomic)
        files[contents] = try digest(source, contents)
        let scheme = "IntentsSubject" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let projectReference = relative(selectedProject.project, to: workspace.deletingLastPathComponent())
        let reference = "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"" + escape(targetID) + "\" BuildableName=\"" + escape(name) + ".app\" BlueprintName=\"" + escape(name) + "\" ReferencedContainer=\"container:" + escape(projectReference) + "\"/>"
        let xml = "<?xml version=\"1.0\"?><Scheme version=\"1.7\"><BuildAction parallelizeBuildables=\"NO\" buildImplicitDependencies=\"YES\"><BuildActionEntries><BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"YES\" buildForProfiling=\"NO\" buildForArchiving=\"NO\" buildForAnalyzing=\"YES\">" + reference + "</BuildActionEntry></BuildActionEntries></BuildAction></Scheme>"
        let path = workspaceRelativePath + "/xcshareddata/xcschemes/" + scheme + ".xcscheme"
        try FileManager.default.createDirectory(at: source.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: source.appendingPathComponent(path), options: .withoutOverwriting)
        files[path] = try digest(source, path)
        // Workspace settings and package lock are also build inputs, even without remote packages in the selected target.
        for file in manifest.files where file.relativePath.hasPrefix(workspaceRelativePath + "/") && file.symbolicLink == nil && !file.relativePath.hasSuffix(".xcscheme") && file.relativePath != contents {
            files[file.relativePath] = file.sha256
        }
        return .init(relativePath: workspaceRelativePath, subjectScheme: scheme, projectPaths: projects.sorted(), generatedFiles: files)
    }

    mutating func includeHost(_ generated: AutomationGeneratedHost, session: URL) throws {
        let source = session.appendingPathComponent("source")
        let project = URL(fileURLWithPath: generated.projectPath)
        let original = try AutomationReadOnlyFile.read(root: project, relativePath: "xcshareddata/xcschemes/" + generated.scheme + ".xcscheme", maximumBytes: 1_048_576)
        let reference = Self.relative(project, to: source.appendingPathComponent(relativePath).deletingLastPathComponent())
        let xml = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "container:" + Self.escape(project.lastPathComponent), with: "container:" + Self.escape(reference))
        let path = relativePath + "/xcshareddata/xcschemes/" + generated.scheme + ".xcscheme"
        try Data(xml.utf8).write(to: source.appendingPathComponent(path), options: .withoutOverwriting)
        generatedFiles[path] = try Self.digest(source, path)
    }

    func verify(session: URL, manifest: AutomationSourceManifest) throws {
        let source = session.appendingPathComponent("source")
        guard relativePath.hasSuffix(".xcworkspace"), manifest.files.contains(where: { $0.relativePath == relativePath + "/contents.xcworkspacedata" }),
              !projectPaths.isEmpty, projectPaths.count <= 256, Set(projectPaths).count == projectPaths.count,
              generatedFiles.count <= 10_000 else { throw AutomationContractError.conflictingOperation }
        let resolution = try AutomationWorkspaceProjects.resolve(source.appendingPathComponent(relativePath), authorizedRoot: source)
        guard resolution.gaps.isEmpty, resolution.projects.map({ String($0.path.dropFirst(source.path.count + 1)) }).sorted() == projectPaths.sorted() else { throw AutomationContractError.conflictingOperation }
        for (path, expected) in generatedFiles {
            guard try Self.digest(source, path) == expected else { throw AutomationContractError.conflictingOperation }
        }
    }
    func containerArguments(session: URL) -> [String] { ["-workspace", session.appendingPathComponent("source").appendingPathComponent(relativePath).path] }
    static func packageResolutionPath(_ workspace: String) -> String { workspace + "/xcshareddata/swiftpm/Package.resolved" }
    private static func digest(_ root: URL, _ path: String) throws -> String { AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 16 * 1024 * 1024)) }
    private static func relative(_ url: URL, to root: URL) -> String {
        let a = root.path.split(separator: "/"), b = url.path.split(separator: "/")
        let common = zip(a, b).prefix(while: { $0 == $1 }).count
        return (Array(repeating: "..", count: a.count - common) + b.dropFirst(common).map(String.init)).joined(separator: "/")
    }
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
}
