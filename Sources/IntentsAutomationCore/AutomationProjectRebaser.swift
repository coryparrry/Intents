import Foundation

enum AutomationProjectRebaser {
    static func rebase(_ objects: [String: [String: Any]], originalRoot: URL, frozenRoot: URL,
                       projectDirectory: URL, mainGroupID: String, approvedRoots: [URL]? = nil) throws -> [String: [String: Any]] {
        let allowed = approvedRoots ?? [originalRoot]
        guard (1...9).contains(allowed.count), Set(allowed.map(\.path)).count == allowed.count,
              allowed.allSatisfy({ $0.path == originalRoot.path || $0.path.hasPrefix(originalRoot.path + "/") }) else { throw AutomationContractError.invalidIdentity }
        func permitted(_ path: String) -> Bool { allowed.contains { path == $0.path || path.hasPrefix($0.path + "/") } }
        func permittedGroup(_ path: String) -> Bool {
            permitted(path) || ((path == originalRoot.path || path.hasPrefix(originalRoot.path + "/")) && allowed.contains { $0.path.hasPrefix(path + "/") })
        }
        var visited: Set<String> = []
        func walk(_ id: String, parent: URL, depth: Int) throws {
            guard depth <= 64, visited.insert(id).inserted, let object = objects[id] else { throw AutomationContractError.invalidIdentity }
            let tree = object["sourceTree"] as? String ?? "<group>", path = object["path"] as? String
            if ["BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR"].contains(tree) {
                guard (object["children"] as? [String] ?? []).isEmpty else {
                    throw AutomationContractError.missingEvidence("Grouped system references need a qualified source graph")
                }
            }
            var location = parent
            if let path, !path.isEmpty {
                guard !path.contains("\0") else { throw AutomationContractError.invalidIdentity }
                switch tree {
                case "<group>": location = parent.appendingPathComponent(path)
                case "SOURCE_ROOT": location = projectDirectory.appendingPathComponent(path)
                case "<absolute>": location = URL(fileURLWithPath: path)
                case "BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR":
                    guard !path.hasPrefix("/"), !path.contains("$"),
                          !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
                          (object["children"] as? [String] ?? []).isEmpty else {
                        throw AutomationContractError.missingEvidence("Escaping or grouped system references need a qualified source graph")
                    }
                    return
                default: throw AutomationContractError.missingEvidence("Unsupported project reference root: " + tree)
                }
                let actual = try AutomationPath.canonical(location)
                guard permitted(actual.path) || (object["isa"] as? String == "PBXGroup" && permittedGroup(actual.path)) else {
                    throw AutomationContractError.missingEvidence("External project inputs require authorised source-root preparation")
                }
                location = actual
            }
            for child in object["children"] as? [String] ?? [] { try walk(child, parent: location, depth: depth + 1) }
        }
        try walk(mainGroupID, parent: projectDirectory, depth: 0)
        func value(_ input: Any) throws -> Any {
            if let text = input as? String {
                guard !text.contains("\0") else { throw AutomationContractError.invalidIdentity }
                if text == originalRoot.path { return frozenRoot.path }
                return text.replacingOccurrences(of: originalRoot.path + "/", with: frozenRoot.path + "/")
            }
            if let array = input as? [Any] { return try array.map(value) }
            if let fields = input as? [String: Any] { return try fields.mapValues(value) }
            return input
        }
        var result: [String: [String: Any]] = [:]
        for (id, object) in objects {
            if let script = object["shellScript"] as? String, script.contains(originalRoot.path) {
                throw AutomationContractError.missingEvidence("A build script refers to the live checkout; a qualified isolated recipe is required")
            }
            if object["isa"] as? String == "XCLocalSwiftPackageReference", let path = object["relativePath"] as? String {
                // Relative local packages outside the approved root need separately authorised roots.
                guard !path.contains("\0"), !path.hasPrefix("/") else { throw AutomationContractError.invalidIdentity }
                let actual = try AutomationPath.canonical(projectDirectory.appendingPathComponent(path))
                guard permitted(actual.path) else {
                    throw AutomationContractError.missingEvidence("External local packages require authorised source-root preparation")
                }
            }
            if ["PBXFileReference", "PBXGroup", "PBXFileSystemSynchronizedRootGroup"].contains(object["isa"] as? String ?? ""),
               let path = object["path"] as? String, path.hasPrefix("/") || object["sourceTree"] as? String == "<absolute>" {
                let original = try AutomationPath.canonical(URL(fileURLWithPath: path))
                guard permitted(original.path) || (object["isa"] as? String == "PBXGroup" && permittedGroup(original.path)) else {
                    throw AutomationContractError.missingEvidence("External project references require authorised source-root preparation")
                }
                var rebased = try value(object) as! [String: Any]
                rebased["path"] = frozenRoot.path + String(original.path.dropFirst(originalRoot.path.count))
                result[id] = rebased
            } else { result[id] = try value(object) as? [String: Any] }
        }
        return result
    }
}
