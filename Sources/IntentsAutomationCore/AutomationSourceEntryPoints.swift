import Foundation

/// Bounded read-only repository discovery. Selecting a dependency/example folder
/// directly is still supported; exclusion applies only below the selected root.
enum AutomationSourceEntryPoints {
    struct Result {
        var projects: [URL] = []
        var workspaces: [URL] = []
        var gaps: [String] = []
    }
    struct Limits {
        var depth = 12
        var directories = 2_000
        var entries = 20_000
        var entryPoints = 256
    }
    private static let excluded: Set<String> = [
        "build", "builds", "deriveddata", "dist", "node_modules", "pods",
        "carthage", "vendor", "vendors", "example", "examples", "sample", "samples",
        "test", "tests", "fixtures", "coverage"
    ]
    static func isPrimary(_ url: URL, under root: URL) -> Bool {
        guard url.path.hasPrefix(root.path + "/") else { return false }
        let parts = url.path.dropFirst(root.path.count + 1).split(separator: "/")
        return parts.dropLast().allSatisfy { !$0.hasPrefix(".") && !excluded.contains($0.lowercased()) }
    }
    static func discover(_ root: URL, limits: Limits = .init()) throws -> Result {
        guard limits.depth > 0, limits.directories > 0, limits.entries > 0, limits.entryPoints > 0,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AutomationContractError.invalidIdentity
        }
        var result = Result(), queue: [(URL, Int)] = [(root, 0)]
        var index = 0, inspected = 0, limited = false
        while index < queue.count {
            let (directory, depth) = queue[index]; index += 1
            let entries: [URL]
            do {
                guard try AutomationPath.canonical(directory).path == directory.path else { throw AutomationContractError.invalidIdentity }
                entries = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles])
            } catch {
                result.gaps.append("Could not inspect source folder " + directory.lastPathComponent + ". Discovery is partial.")
                continue
            }
            guard entries.count <= limits.entries - inspected else { limited = true; break }
            inspected += entries.count
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard result.projects.count + result.workspaces.count < limits.entryPoints else { limited = true; break }
                do {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                    guard try AutomationPath.canonical(entry).path == entry.path else {
                        result.gaps.append("A source folder changed while being inspected. Select it again."); continue
                    }
                    switch entry.pathExtension.lowercased() {
                    case "xcodeproj": result.projects.append(entry)
                    case "xcworkspace": result.workspaces.append(entry)
                    case "app", "xcarchive", "framework", "bundle", "playground", "xcassets": break
                    default:
                        guard !excluded.contains(entry.lastPathComponent.lowercased()), values.isPackage != true else { continue }
                        guard depth < limits.depth, queue.count < limits.directories else { limited = true; continue }
                        queue.append((entry, depth + 1))
                    }
                } catch { result.gaps.append("A source entry could not be inspected. Discovery is partial.") }
            }
            if result.projects.count + result.workspaces.count >= limits.entryPoints { limited = true; break }
        }
        if limited { result.gaps.append("Repository discovery reached its inspection limit. Select a more specific app folder to inspect the remaining projects.") }
        return result
    }
}
