import Foundation

/// Observed project membership, bound to one frozen snapshot. Partial coverage is
/// explicit: this record is not a compiler index or permission to resolve packages.
public struct AutomationSourceGraph: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
    }
    public struct Edge: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var kind: String
    }
    public struct Input: Codable, Equatable, Sendable {
        public var relativePath: String
        public var sha256: String
        public var owner: String
        public var role: String
    }
    public static let currentSchemaVersion = 3
    public var schemaVersion = currentSchemaVersion
    public var sourceManifestDigest: String
    public var projectRelativePath: String
    public var targetID: String
    public var configuration: String
    public var nodes: [Node]
    public var edges: [Edge]
    public var inputs: [Input]
    public var declarations: [AutomationSourceDeclaration]
    public var coverage: String = "partial"
    public var gaps: [String]
    public var packagePins: [AutomationPackagePin]? = nil
    public var platformContext: AutomationSourcePlatformContext? = nil
    public var packagePlatformConditionVersion: Int? = nil
    public var synchronizedMembershipVersion: Int? = nil
    func admitsSwiftDeclarations(role: String) -> Bool {
        role == "explicitSwiftMembership" || role == "packageSwiftMembership" || (role == "synchronizedSwiftMembership" && synchronizedMembershipVersion == 1)
    }
    public var digest: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return AutomationArtifactRegistry.digest(try encoder.encode(self))
        }
    }
}

public enum AutomationSourceGraphReader {
    public static func read(manifest: AutomationSourceManifest, frozenRoot: URL,
                            projectRelativePath: String, targetID: String,
                            configuration: String) throws -> AutomationSourceGraph {
        var reader = try Reader(manifest: manifest, frozenRoot: frozenRoot,
                                project: projectRelativePath, target: targetID, configuration: configuration, projectData: nil)
        return try reader.read()
    }
    // Host generation deliberately rewrites the working project. Restore uses
    // its separately retained original bytes, still checked against the manifest.
    static func read(manifest: AutomationSourceManifest, frozenRoot: URL,
                     projectRelativePath: String, targetID: String,
                     configuration: String, projectData: Data, resolutionData: Data? = nil,
                     platformSettings: Data? = nil, developerDirectory: URL? = nil, resolvePackagePlatformConditions: Bool? = nil, resolveSynchronizedMembership: Bool? = nil) throws -> AutomationSourceGraph {
        var reader = try Reader(manifest: manifest, frozenRoot: frozenRoot,
                                project: projectRelativePath, target: targetID, configuration: configuration, projectData: projectData, resolutionData: resolutionData, platformSettings: platformSettings, developerDirectory: developerDirectory, resolvePackagePlatformConditions: resolvePackagePlatformConditions, resolveSynchronizedMembership: resolveSynchronizedMembership)
        return try reader.read()
    }

    private struct Reader {
        let manifest: AutomationSourceManifest, frozenRoot: URL, project: String, target: String, configuration: String
        let resolutionData: Data?
        let platformContext: AutomationSourcePlatformContext?
        let resolvePackagePlatformConditions: Bool
        let resolveSynchronizedMembership: Bool
        var synchronizedOwners: [String: [String]] = [:]
        var synchronizedOwnershipUnknown = false, synchronizedExceptionsPresent = false
        let objects: [String: [String: Any]], projectObject: [String: Any]
        let files: [String: AutomationSourceManifest.File]
        let productOwners: [String: [String]]
        var locations: [String: String] = [:], nodes: [AutomationSourceGraph.Node] = [], edges: [AutomationSourceGraph.Edge] = []
        var inputs: [AutomationSourceGraph.Input] = [], declarations: [AutomationSourceDeclaration] = []
        var gaps: Set<String> = ["Compiler index, generated declarations, conditional compilation and SwiftSyntax reconciliation are unavailable; source coverage is partial."]
        var visited: Set<String> = [], totalSourceBytes = 0
        var work = 0, edgeSet: Set<AutomationSourceGraph.Edge> = []
        var nodeIDs: Set<String> = [], inputKeys: Set<InputKey> = []
        var packageManifests: [String: AutomationPackageManifest.Manifest] = [:]
        var unresolvedPackageManifests: Set<String> = [], expandedLocalTargets: Set<String> = []
        var activeLocalProducts: Set<String> = []
        var activeLocalTargets: Set<String> = []
        var packagePins: [String: AutomationPackagePin] = [:]
        var resolutionRecords: [String: AutomationPackageResolution.Index] = [:], unavailableResolutions: Set<String> = []
        struct InputKey: Hashable { let path: String, owner: String, role: String }

        init(manifest: AutomationSourceManifest, frozenRoot: URL, project: String, target: String, configuration: String, projectData: Data?, resolutionData: Data? = nil, platformSettings: Data? = nil, developerDirectory: URL? = nil, resolvePackagePlatformConditions: Bool? = nil, resolveSynchronizedMembership: Bool? = nil) throws {
            self.resolutionData = resolutionData
            self.resolvePackagePlatformConditions = resolvePackagePlatformConditions ?? (platformSettings != nil)
            self.resolveSynchronizedMembership = resolveSynchronizedMembership ?? true
            guard !self.resolvePackagePlatformConditions || platformSettings != nil else { throw AutomationContractError.invalidIdentity }
            try manifest.validateCaptureLayout()
            guard manifest.files.count <= 100_000,
                  Set(manifest.files.map(\.relativePath)).count == manifest.files.count else { throw AutomationContractError.invalidIdentity }
            self.manifest = manifest; self.frozenRoot = frozenRoot; self.project = project; self.target = target; self.configuration = configuration
            files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
            let path = project + "/project.pbxproj"
            guard let file = files[path], file.symbolicLink == nil else { throw AutomationContractError.invalidIdentity }
            let data = try projectData ?? AutomationReadOnlyFile.read(root: frozenRoot, relativePath: path, maximumBytes: 16 * 1024 * 1024)
            guard data.count <= 16 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            guard file.bytes == data.count, file.sha256 == AutomationArtifactRegistry.digest(data),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let objects = plist["objects"] as? [String: [String: Any]], objects.count <= 100_000,
                  let root = plist["rootObject"] as? String, let object = objects[root], object["isa"] as? String == "PBXProject",
                  let selected = objects[target], selected["isa"] as? String == "PBXNativeTarget",
                  (object["targets"] as? [String] ?? []).contains(target) else { throw AutomationContractError.invalidIdentity }
            self.objects = objects; projectObject = object
            if let platformSettings {
                guard let developerDirectory, let name = selected["name"] as? String else { throw AutomationContractError.invalidIdentity }
                platformContext = try AutomationSourcePlatformContext.read(platformSettings,
                    project: frozenRoot.appendingPathComponent(project), targetName: name,
                    configuration: configuration, developer: developerDirectory)
            } else {
                guard developerDirectory == nil else { throw AutomationContractError.invalidIdentity }
                platformContext = nil
            }
            var owners: [String: [String]] = [:]
            for (id, object) in objects {
                try Task.checkCancellation()
                if object["isa"] as? String == "PBXNativeTarget", let ref = object["productReference"] as? String {
                    owners[ref, default: []].append(id)
                }
            }
            productOwners = owners.mapValues { $0.sorted() }
        }
        mutating func read() throws -> AutomationSourceGraph {
            if resolveSynchronizedMembership { try collectSynchronizedOwners() }
            guard let main = projectObject["mainGroup"] as? String else { throw AutomationContractError.invalidIdentity }
            var seen: Set<String> = []
            try group(main, parent: URL(fileURLWithPath: manifest.layoutRoot).appendingPathComponent(project).deletingLastPathComponent(), depth: 0, seen: &seen)
            try visit(target, depth: 0)
            return .init(sourceManifestDigest: try manifest.digest, projectRelativePath: project, targetID: target,
                         configuration: configuration, nodes: nodes.sorted { $0.id < $1.id },
                         edges: edges.sorted { ($0.from, $0.kind, $0.to) < ($1.from, $1.kind, $1.to) },
                         inputs: inputs.sorted { ($0.owner, $0.relativePath, $0.role) < ($1.owner, $1.relativePath, $1.role) },
                         declarations: declarations.sorted { ($0.owner, $0.relativePath, $0.line, $0.name) < ($1.owner, $1.relativePath, $1.line, $1.name) }, gaps: gaps.sorted(),
                         packagePins: packagePins.isEmpty ? nil : packagePins.values.sorted { $0.referenceID < $1.referenceID }, platformContext: platformContext, packagePlatformConditionVersion: resolvePackagePlatformConditions ? 1 : nil, synchronizedMembershipVersion: resolveSynchronizedMembership ? 1 : nil)
        }
        func nodeID(_ id: String) -> String { project + "#" + id }
        func normalizedPath(_ url: URL) -> String {
            var parts: [Substring] = []
            for part in url.path.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                else { parts.append(part) }
            }
            // Pure lexical normalization preserves the manifest's canonical root;
            // Foundation standardization can rewrite /private/tmp to its alias.
            return "/" + parts.joined(separator: "/")
        }
        mutating func consumeWork() throws {
            try Task.checkCancellation(); work += 1
            guard work <= 100_000 else { throw AutomationContractError.missingEvidence("Source graph traversal budget exceeded") }
        }
        mutating func edge(from: String, to: String, kind: String) throws {
            try consumeWork()
            let value = AutomationSourceGraph.Edge(from: from, to: to, kind: kind)
            if edgeSet.insert(value).inserted { edges.append(value) }
        }
        mutating func node(id: String, name: String, kind: String) throws {
            if nodeIDs.insert(id).inserted {
                guard nodes.count < 10_000 else { throw AutomationContractError.missingEvidence("Source graph node budget exceeded") }
                nodes.append(.init(id: id, name: name, kind: kind))
            }
        }
        mutating func group(_ id: String, parent: URL, depth: Int, seen: inout Set<String>) throws {
            try consumeWork()
            guard depth <= 64, seen.insert(id).inserted, let object = objects[id] else { throw AutomationContractError.invalidIdentity }
            let tree = object["sourceTree"] as? String ?? "<group>"
            let path = object["path"] as? String ?? ""
            if ["BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR"].contains(tree) { return }
            guard !path.contains("\0"), !path.contains("$") else { gaps.insert("Unresolved build-setting path at " + id); return }
            let directory = URL(fileURLWithPath: manifest.layoutRoot).appendingPathComponent(project).deletingLastPathComponent()
            let location: URL
            switch tree {
            case "<group>": location = path.isEmpty ? parent : parent.appendingPathComponent(path)
            case "SOURCE_ROOT": location = path.isEmpty ? directory : directory.appendingPathComponent(path)
            case "<absolute>": location = URL(fileURLWithPath: path)
            default: gaps.insert("Unsupported source tree at " + id); return
            }
            let normalized = normalizedPath(location)
            guard manifest.includesOrigin(normalized) || (object["isa"] as? String == "PBXGroup" && manifest.includesScaffoldOrigin(normalized)) else {
                gaps.insert("External source root requires separate approval at " + id); return
            }
            locations[id] = normalized == manifest.layoutRoot ? "" : String(normalized.dropFirst(manifest.layoutRoot.count + 1))
            if object["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
                if !resolveSynchronizedMembership { gaps.insert("Synchronized group membership is unresolved at " + id) }; return
            }
            for child in object["children"] as? [String] ?? [] { try group(child, parent: location, depth: depth + 1, seen: &seen) }
        }
        mutating func collectSynchronizedOwners() throws {
            for (id, object) in objects.sorted(by: { $0.key < $1.key }) {
                try consumeWork()
                let kind = object["isa"] as? String ?? ""
                if kind.hasPrefix("PBXFileSystemSynchronized"), kind != "PBXFileSystemSynchronizedRootGroup" { synchronizedExceptionsPresent = true }
                guard kind == "PBXNativeTarget", let raw = object["fileSystemSynchronizedGroups"] else { continue }
                guard let groups = raw as? [String] else { synchronizedOwnershipUnknown = true; continue }
                for group in groups { try consumeWork(); synchronizedOwners[group, default: []].append(id) }
            }
        }
        mutating func synchronizedMembership(_ id: String, target: String, owner: String, uncertain: Bool) throws {
            let gap = "Synchronized Swift membership is unresolved at " + id
            let allowed: Set<String> = ["isa", "path", "sourceTree", "exceptions", "explicitFileTypes", "explicitFolders"]
            guard !uncertain, !synchronizedOwnershipUnknown, !synchronizedExceptionsPresent,
                  synchronizedOwners[id] == [target], let object = objects[id],
                  object["isa"] as? String == "PBXFileSystemSynchronizedRootGroup", Set(object.keys).isSubset(of: allowed),
                  let root = locations[id], root.isEmpty || manifest.directories.contains(root),
                  root.split(separator: "/").last.map({ !$0.contains(".") }) ?? true else { gaps.insert(gap); return }
            for field in ["exceptions", "explicitFolders"] where object[field] != nil {
                guard let values = object[field] as? [String], values.isEmpty else { gaps.insert(gap); return }
            }
            if let raw = object["explicitFileTypes"] {
                guard let values = raw as? [String: Any], values.isEmpty else { gaps.insert(gap); return }
            }
            let prefix = root.isEmpty ? "" : root + "/"
            var candidates: [String] = [], names: Set<String> = []
            for file in manifest.files {
                try consumeWork()
                guard file.relativePath.hasPrefix(prefix) else { continue }
                let relative = String(file.relativePath.dropFirst(prefix.count))
                let parts = relative.split(separator: "/").map(String.init)
                guard relative.lowercased().hasSuffix(".swift") else { continue }
                guard relative.hasSuffix(".swift"), file.symbolicLink == nil,
                      AutomationSourceCaptureLayout.relative(relative), !parts.contains(where: { $0.hasPrefix(".") }),
                      // Xcode recognizes many resource wrapper types. Until their file-type
                      // rules are captured, only ordinary extensionless subfolders are known.
                      !parts.dropLast().contains(where: { $0.contains(".") }),
                      names.insert(relative.lowercased().precomposedStringWithCanonicalMapping).inserted else { gaps.insert(gap); return }
                candidates.append(file.relativePath)
            }
            guard !candidates.isEmpty else { gaps.insert(gap + ": no captured Swift files"); return }
            for path in candidates.sorted() {
                // Explicit source phases were visited first. One source/owner is scanned once.
                guard !inputKeys.contains(InputKey(path: path, owner: owner, role: "explicitSwiftMembership")) else { continue }
                try input(path, owner: owner, role: "synchronizedSwiftMembership")
            }
            gaps.insert("Synchronized Swift inputs are static captured membership; compiler consumption and generated files remain unresolved at " + id)
        }
        mutating func visit(_ id: String, depth: Int) throws {
            try consumeWork()
            guard depth <= 64, visited.count < 10_000 else { throw AutomationContractError.invalidIdentity }
            if visited.contains(id) { return }
            guard let object = objects[id], object["isa"] as? String == "PBXNativeTarget",
                  let name = object["name"] as? String else { gaps.insert("Unresolved target dependency " + id); return }
            visited.insert(id)
            let owner = nodeID(id)
            try node(id: owner, name: name, kind: object["productType"] as? String ?? "target")
            let configs = (object["buildConfigurationList"] as? String).flatMap { objects[$0]?["buildConfigurations"] as? [String] } ?? []
            var matching: [String] = []
            for config in configs {
                try consumeWork()
                if objects[config]?["name"] as? String == configuration { matching.append(config) }
            }
            guard matching.count == 1 else { throw AutomationContractError.missingEvidence("Selected source graph configuration is unresolved for " + name) }
            var membershipConfigurations = matching
            if let projectList = projectObject["buildConfigurationList"] as? String {
                let projectConfigs = objects[projectList]?["buildConfigurations"] as? [String] ?? []
                var selectedProjectConfigs: [String] = []
                for config in projectConfigs { try consumeWork(); if objects[config]?["name"] as? String == configuration { selectedProjectConfigs.append(config) } }
                if selectedProjectConfigs.count != 1 { gaps.insert("Inherited project configuration is unresolved for " + name) }
                membershipConfigurations += selectedProjectConfigs
            }
            var uncertainMembership = projectObject["buildConfigurationList"] != nil && membershipConfigurations.count != 2
            for config in membershipConfigurations {
                if let ref = objects[config]?["baseConfigurationReference"] as? String {
                    uncertainMembership = true; gaps.insert("Inherited xcconfig source membership is unresolved for " + name)
                    if let path = locations[ref] { try input(path, owner: owner, role: "buildConfiguration") }
                }
                if let settings = objects[config]?["buildSettings"] as? [String: Any] {
                for key in settings.keys {
                    try consumeWork()
                    if key.contains("[") || key == "EXCLUDED_SOURCE_FILE_NAMES" || key == "INCLUDED_SOURCE_FILE_NAMES" { uncertainMembership = true; gaps.insert("Conditional source membership is unresolved for " + name) }
                }
                }
            }
            for dependency in object["dependencies"] as? [String] ?? [] {
                try consumeWork()
                guard let next = objects[dependency]?["target"] as? String else { gaps.insert("Cross-project dependency is unresolved at " + dependency); continue }
                try edge(from: owner, to: nodeID(next), kind: "targetDependency"); try visit(next, depth: depth + 1)
            }
            for product in object["packageProductDependencies"] as? [String] ?? [] { try package(product, owner: owner) }
            for phaseID in object["buildPhases"] as? [String] ?? [] {
                try consumeWork()
                guard let phase = objects[phaseID], let kind = phase["isa"] as? String else { gaps.insert("Unresolved build phase " + phaseID); continue }
                if kind == "PBXShellScriptBuildPhase" {
                    let script = nodeID(phaseID)
                    try node(id: script, name: phase["name"] as? String ?? "Build script", kind: "buildScript")
                    try edge(from: owner, to: script, kind: "generatedInputs"); gaps.insert("Script and generated output inputs are unresolved at " + phaseID)
                }
                for buildID in phase["files"] as? [String] ?? [] {
                    try consumeWork()
                    guard let build = objects[buildID] else { gaps.insert("Unresolved build file " + buildID); continue }
                    if let product = build["productRef"] as? String { try package(product, owner: owner) }
                    guard let ref = build["fileRef"] as? String else { continue }
                    if kind == "PBXSourcesBuildPhase" {
                        guard let path = locations[ref] else { gaps.insert("Unresolved source reference " + ref); continue }
                        let filtered = build["platformFilter"] != nil || build["platformFilters"] != nil
                        // App settings cannot resolve a dependency target's platform.
                        let active: Bool? = !filtered ? true : id == target ? platformContext?.includes(build) : nil
                        let conditional = uncertainMembership || active == nil || build["settings"] != nil
                        if conditional { gaps.insert("Conditional source build-file settings at " + buildID) }
                        if path.hasSuffix(".swift") {
                            let role = conditional ? "unresolvedSwiftMembership" : active == false ? "inactiveSwiftMembership" : "explicitSwiftMembership"
                            try input(path, owner: owner, role: role)
                        }
                    } else if kind == "PBXCopyFilesBuildPhase" || kind == "PBXFrameworksBuildPhase" {
                        for next in productOwners[ref] ?? [] { try edge(from: owner, to: nodeID(next), kind: "linkedOrEmbeddedProduct"); try visit(next, depth: depth + 1) }
                    }
                }
            }
            if resolveSynchronizedMembership, object["fileSystemSynchronizedGroups"] != nil, object["fileSystemSynchronizedGroups"] as? [String] == nil {
                gaps.insert("Synchronized target membership list is unresolved at " + id)
            }
            for sync in object["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                try consumeWork()
                if resolveSynchronizedMembership { try synchronizedMembership(sync, target: id, owner: owner, uncertain: uncertainMembership) }
                else { gaps.insert("Synchronized target membership is unresolved at " + sync) }
            }
        }
        mutating func package(_ id: String, owner: String) throws {
            try consumeWork()
            guard let product = objects[id], product["isa"] as? String == "XCSwiftPackageProductDependency" else { gaps.insert("Unresolved package product " + id); return }
            let key = nodeID(id)
            try node(id: key, name: product["productName"] as? String ?? id, kind: "packageProduct")
            try edge(from: owner, to: key, kind: "packageProduct")
            if resolvePackagePlatformConditions && owner != nodeID(target) {
                gaps.insert("Package destination is unresolved for dependency target at " + owner)
                return
            }
            guard let ref = product["package"] as? String, let package = objects[ref] else { gaps.insert("Package ownership is unresolved for " + id); return }
            if package["isa"] as? String == "XCLocalSwiftPackageReference", let path = package["relativePath"] as? String {
                let base = URL(fileURLWithPath: manifest.layoutRoot).appendingPathComponent(project).deletingLastPathComponent()
                let resolved = normalizedPath(base.appendingPathComponent(path))
                guard !path.contains("$"), !path.contains("\0"), manifest.includesOrigin(resolved) else { gaps.insert("External package root requires separate approval at " + ref); return }
                let relative = resolved == manifest.layoutRoot ? "Package.swift" : String(resolved.dropFirst(manifest.layoutRoot.count + 1)) + "/Package.swift"
                try input(relative, owner: key, role: "packageManifest")
                try localPackage(manifestPath: relative, productID: key, productName: product["productName"] as? String ?? id)
                gaps.insert("Local package compiler consumption, plugins, macros and remote dependencies remain unresolved at " + ref)
            } else if package["isa"] as? String == "XCRemoteSwiftPackageReference" {
                try remotePackage(ref, package: package, product: key)
            } else { gaps.insert("Remote package checkout and resolved revision are unavailable at " + ref) }
        }
        mutating func remotePackage(_ ref: String, package: [String: Any], product: String) throws {
            let path = project + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", reference = nodeID(ref)
            gaps.insert("Remote source checkout and actual build consumption remain unresolved at " + ref)
            guard let location = package["repositoryURL"] as? String, let identity = AutomationPackageResolution.identity(location),
                  let file = files[path], file.symbolicLink == nil else { gaps.insert("Captured remote resolution is absent or unsupported at " + ref); return }
            try input(path, owner: reference, role: "packageResolution")
            if resolutionRecords[path] == nil, !unavailableResolutions.contains(path) {
                if file.bytes <= 1_048_576 {
                    let bytes = try resolutionData ?? AutomationReadOnlyFile.read(root: frozenRoot, relativePath: path, maximumBytes: 1_048_576)
                    guard bytes.count == file.bytes, AutomationArtifactRegistry.digest(bytes) == file.sha256 else { throw AutomationContractError.conflictingOperation }
                    if let parsed = try AutomationPackageResolution.read(bytes) { resolutionRecords[path] = parsed }
                    else { unavailableResolutions.insert(path) }
                } else { unavailableResolutions.insert(path) }
            }
            guard let resolved = resolutionRecords[path], let pin = resolved.pinsByIdentity[identity], pin.location.utf8.elementsEqual(location.utf8) else {
                gaps.insert("Captured remote resolution pin is unmatched or ambiguous at " + ref); return
            }
            let state = AutomationPackageResolution.requirementState(package["requirement"] as? [String: Any], pin: pin)
            packagePins[reference] = .init(referenceID: reference, identity: identity, location: location, revision: pin.state.revision,
                version: pin.state.version, branch: pin.state.branch, originHash: resolved.record.originHash,
                resolutionPath: path, resolutionDigest: file.sha256, requirementState: state)
            let id = reference + "/pin"
            try node(id: id, name: identity, kind: "capturedRemotePin"); try edge(from: product, to: id, kind: "capturedResolution")
            if state != "satisfied" { gaps.insert("Captured remote pin requirement is " + state + " at " + ref) }
            gaps.insert("Resolution originHash is observed without recomputing Xcode's dependency origin at " + ref)
        }
        mutating func localPackage(manifestPath: String, productID: String, productName: String, depth: Int = 0) throws {
            try consumeWork()
            guard depth <= 64 else { throw AutomationContractError.missingEvidence("Local package target depth exceeds budget") }
            let key = manifestPath + "#product:" + productName
            guard activeLocalProducts.insert(key).inserted else { gaps.insert("Local package product cycle at " + key); return }
            defer { activeLocalProducts.remove(key) }
            guard let file = files[manifestPath], file.symbolicLink == nil else { return }
            guard file.bytes <= 1_048_576 else { gaps.insert("Local package declaration budget excludes " + manifestPath); return }
            if packageManifests[manifestPath] == nil, !unresolvedPackageManifests.contains(manifestPath) {
                let data = try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: manifestPath, maximumBytes: 1_048_576)
                guard data.count == file.bytes, AutomationArtifactRegistry.digest(data) == file.sha256 else { throw AutomationContractError.conflictingOperation }
                if let parsed = try AutomationPackageManifest.read(data) { packageManifests[manifestPath] = parsed }
                else { unresolvedPackageManifests.insert(manifestPath) }
            }
            guard let package = packageManifests[manifestPath], let product = package.productsByName[productName] else {
                gaps.insert("Literal local package product mapping is unresolved at " + manifestPath); return
            }
            let root = manifestPath == "Package.swift" ? "" : String(manifestPath.dropLast("/Package.swift".count))
            var visited: Set<String> = []
            for name in product.targets { try localTarget(name, package: package, root: root, manifestPath: manifestPath, from: productID, visited: &visited, depth: depth) }
        }
        mutating func localProduct(_ dependency: AutomationPackageManifest.ProductDependency, package: AutomationPackageManifest.Manifest,
                                   root: String, owner: String, depth: Int) throws {
            var candidates: [(AutomationPackageManifest.PackageDependency, String?)] = []
            let base = URL(fileURLWithPath: manifest.layoutRoot).appendingPathComponent(root)
            for declaration in package.dependencies {
                try consumeWork()
                let resolved = declaration.path.map { normalizedPath(base.appendingPathComponent($0)) }
                let identity = declaration.name.flatMap(packageIdentity)
                    ?? (declaration.name == nil ? resolved.flatMap {
                        let name = URL(fileURLWithPath: $0).lastPathComponent
                        return packageIdentity(name.hasSuffix(".git") ? String(name.dropLast(4)) : name)
                    }
                        ?? declaration.location.flatMap(AutomationPackageResolution.identity) : nil)
                guard let identity else { gaps.insert("Local product dependency has opaque package ownership at " + owner); return }
                if identity == dependency.package.lowercased() { candidates.append((declaration, resolved)) }
            }
            guard candidates.count == 1, let (declaration, resolved) = candidates.first, let path = declaration.path, let resolved,
                  declaration.name.map({ $0.utf8.elementsEqual(dependency.package.utf8) }) ?? true,
                  !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("$"), !path.contains("\\"), !path.contains("\0"),
                  manifest.includesOrigin(resolved) else {
                gaps.insert("Local product dependency is remote, ambiguous or outside the captured source at " + owner + ":" + dependency.package); return
            }
            let manifestPath = resolved == manifest.layoutRoot ? "Package.swift" : String(resolved.dropFirst(manifest.layoutRoot.count + 1)) + "/Package.swift"
            let productID = manifestPath + "#product:" + dependency.name
            try node(id: productID, name: dependency.name, kind: "localPackageProduct")
            try edge(from: owner, to: productID, kind: "localPackageProduct")
            try input(manifestPath, owner: productID, role: "packageManifest")
            try localPackage(manifestPath: manifestPath, productID: productID, productName: dependency.name, depth: depth)
        }
        func packageIdentity(_ name: String) -> String? {
            let identity = name.lowercased()
            guard !identity.isEmpty, identity != ".", identity != "..", identity.utf8.count <= 256,
                  identity.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
            return identity
        }
        mutating func localTarget(_ name: String, package: AutomationPackageManifest.Manifest, root: String, manifestPath: String,
                                  from: String, visited: inout Set<String>, depth: Int) throws {
            try consumeWork()
            guard depth <= 64 else { throw AutomationContractError.missingEvidence("Local package target depth exceeds budget") }
            guard let target = package.targetsByName[name] else { gaps.insert("Literal local package target is unresolved: " + manifestPath + "#" + name); return }
            let owner = manifestPath + "#target:" + name
            try edge(from: from, to: owner, kind: "localPackageTarget")
            guard !activeLocalTargets.contains(owner) else { gaps.insert("Local package target cycle at " + owner); return }
            if !visited.insert(name).inserted || !expandedLocalTargets.insert(owner).inserted { return }
            activeLocalTargets.insert(owner)
            defer { activeLocalTargets.remove(owner) }
            try node(id: owner, name: name, kind: "localPackageTarget")
            for gap in target.gaps { gaps.insert(gap + " at " + owner) }
            // Host tools and test targets do not inherit the app destination,
            // including through unconditional target or product helpers.
            if resolvePackagePlatformConditions && !target.destinationConditionsAvailable { return }
            for dependency in target.dependencies {
                try localTarget(dependency, package: package, root: root, manifestPath: manifestPath, from: owner, visited: &visited, depth: depth + 1)
            }
            for dependency in target.conditionalDependencies {
                try consumeWork()
                guard packageCondition(dependency.platforms, target: target, owner: owner, product: false) else { continue }
                try localTarget(dependency.name, package: package, root: root, manifestPath: manifestPath, from: owner, visited: &visited, depth: depth + 1)
            }
            for dependency in target.products {
                try consumeWork()
                if let platforms = dependency.platforms, !packageCondition(platforms, target: target, owner: owner, product: true) { continue }
                try localProduct(dependency, package: package, root: root, owner: owner, depth: depth + 1)
            }
            guard target.membershipAvailable else { return }
            let defaultPath = "Sources/" + name
            guard let path = packagePath(target.path ?? defaultPath),
                  let excludes = packagePaths(target.exclude), let sources = packagePaths(target.sources ?? []) else {
                gaps.insert("Unsafe local package target path or membership at " + owner); return
            }
            let directory = [root, path].filter { !$0.isEmpty }.joined(separator: "/")
            guard directory.isEmpty || manifest.directories.contains(directory) else { gaps.insert("Local package target directory is absent at " + owner); return }
            // Explicit sources may name files or directories; only snapshot-owned Swift bytes are observed.
            let selected = target.sources == nil ? [""] : sources
            var matched = Set<String>()
            for file in manifest.files {
                try consumeWork()
                let prefix = directory.isEmpty ? "" : directory + "/"
                guard file.relativePath.hasPrefix(prefix) else { continue }
                let relative = String(file.relativePath.dropFirst(prefix.count))
                let packageRelative = root.isEmpty ? file.relativePath : String(file.relativePath.dropFirst(root.count + 1))
                guard !automaticPackageExclusion(packageRelative) else { continue }
                if packageRelative.split(separator: "/").dropLast().contains(where: { $0.contains(".") }) {
                    gaps.insert("Opaque package directories require compiler source traversal at " + owner); continue
                }
                var excluded = false
                for exclusion in excludes {
                    try consumeWork()
                    if exclusion.isEmpty || relative == exclusion || relative.hasPrefix(exclusion + "/") { excluded = true; break }
                }
                if excluded { continue }
                var included = false
                for source in selected {
                    try consumeWork()
                    if source.isEmpty || relative == source || relative.hasPrefix(source + "/") { matched.insert(source); included = true }
                }
                guard relative.hasSuffix(".swift"), included else { continue }
                try input(file.relativePath, owner: owner, role: "packageSwiftMembership")
            }
            for source in selected where !matched.contains(source) { gaps.insert("Literal package source is absent or excluded: " + owner + "/" + source) }
            gaps.insert((resolvePackagePlatformConditions ? "Literal package membership does not resolve plugins, macros, resources or external products at " : "Literal package membership does not resolve platform conditions, plugins, macros, resources or external products at ") + owner)
        }
        func automaticPackageExclusion(_ path: String) -> Bool {
            let parts = path.split(separator: "/")
            if parts.contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".playground") }) { return true }
            return parts.count == 1 && (path == "Package.swift" || path == "Package.resolved" || (path.hasPrefix("Package@") && path.hasSuffix(".swift")))
        }
        mutating func packageCondition(_ platforms: [String], target: AutomationPackageManifest.Target, owner: String, product: Bool) -> Bool {
            guard resolvePackagePlatformConditions, target.destinationConditionsAvailable, let family = platformContext?.filterFamily else {
                // Preserve the exact legacy gap for retained graphs without this algorithm version.
                gaps.insert((product ? "Conditional or unowned product dependency is unresolved" : "Conditional target dependency is unresolved") + " at " + owner)
                return false
            }
            return platforms.contains(family)
        }
        func packagePath(_ path: String) -> String? {
            if path == "." || path.isEmpty { return "" }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("$"), !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
            return path
        }
        func packagePaths(_ paths: [String]) -> [String]? {
            let normalized = paths.compactMap(packagePath)
            return normalized.count == paths.count ? normalized : nil
        }
        mutating func input(_ path: String, owner: String, role: String) throws {
            try consumeWork()
            let key = InputKey(path: path, owner: owner, role: role)
            if inputKeys.contains(key) { return }
            guard inputs.count < 10_000 else { throw AutomationContractError.invalidIdentity }
            guard let file = files[path], file.symbolicLink == nil else { gaps.insert("Source input is absent or linked in the frozen manifest: " + path); return }
            let data: Data
            if role == "packageResolution", path == project + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", let resolutionData { data = resolutionData }
            else { data = try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: path, maximumBytes: 16 * 1024 * 1024) }
            guard data.count == file.bytes, AutomationArtifactRegistry.digest(data) == file.sha256 else { throw AutomationContractError.conflictingOperation }
            totalSourceBytes += data.count
            guard totalSourceBytes <= 64 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            inputs.append(.init(relativePath: path, sha256: file.sha256, owner: owner, role: role))
            inputKeys.insert(key)
            if role == "explicitSwiftMembership" || role == "packageSwiftMembership" || role == "synchronizedSwiftMembership" { declarations += try AutomationSourceDeclarationReader.read(data, path: path, owner: owner) }
        }
    }
}
