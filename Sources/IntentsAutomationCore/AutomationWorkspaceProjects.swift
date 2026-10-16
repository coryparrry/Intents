import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads only in-root references. External roots remain an explicit access/build approval decision.
enum AutomationWorkspaceProjects {
    struct Resolution { var projects: [URL]; var gaps: [String] }
    static func resolve(_ workspace: URL, authorizedRoot: URL? = nil) throws -> Resolution {
        let data = try AutomationReadOnlyFile.read(root: workspace, relativePath: "contents.xcworkspacedata", maximumBytes: 1_048_576)
        guard String(decoding: data, as: UTF8.self).range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw AutomationContractError.invalidIdentity }
        let root = try AutomationPath.canonical(workspace.deletingLastPathComponent())
        let boundary = try authorizedRoot.map(AutomationPath.canonical) ?? root
        guard root.path == boundary.path || root.path.hasPrefix(boundary.path + "/") else { throw AutomationContractError.invalidIdentity }
        let delegate = Reader(root: root, boundary: boundary)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed else { throw AutomationContractError.invalidIdentity }
        return .init(projects: Array(Set(delegate.projects)).sorted { $0.path < $1.path }, gaps: delegate.gaps)
    }
    private final class Reader: NSObject, XMLParserDelegate {
        let root: URL
        let boundary: URL
        var groups: [URL?]
        var projects: [URL] = [], gaps: [String] = []
        var count = 0, failed = false
        init(root: URL, boundary: URL) { self.root = root; self.boundary = boundary; groups = [root] }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 10_000, groups.count <= 64 else { failed = true; parser.abortParsing(); return }
            if name == "Group" {
                let resolved = location(attributes["location"] ?? "group:")
                if resolved == nil { gaps.append("An unsupported workspace group requires explicit preparation.") }
                groups.append(resolved); return
            }
            guard name == "FileRef", let reference = attributes["location"] else { return }
            guard let url = location(reference), url.pathExtension == "xcodeproj" else { gaps.append("An external or unsupported workspace reference requires explicit preparation."); return }
            do {
                let actual = try AutomationPath.canonical(url)
                guard actual.path.hasPrefix(boundary.path + "/") else { gaps.append("Workspace project is outside the authorised source root."); return }
                if !projects.contains(actual) {
                    guard projects.count < 256 else {
                        let gap = "Workspace project inspection reached its limit. Select a more specific app project."
                        if !gaps.contains(gap) { gaps.append(gap) }
                        return
                    }
                    projects.append(actual)
                }
            } catch { gaps.append("A referenced workspace project is unavailable.") }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Group", groups.count > 1 { groups.removeLast() }
        }
        private func location(_ text: String) -> URL? {
            guard let parent = groups.last ?? nil, !text.contains("\0"), let colon = text.firstIndex(of: ":") else { return nil }
            let kind = String(text[..<colon]), path = String(text[text.index(after: colon)...])
            let base: URL
            switch kind {
            case "group": base = parent
            case "container": base = root
            default: return nil
            }
            guard !path.hasPrefix("/") else { return nil }
            // Lexically resolve relative components without Foundation rewriting
            // canonical /private/tmp into the /tmp symlink alias.
            var components = base.path.split(separator: "/").map(String.init)
            for component in path.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard !components.isEmpty else { return nil }
                    components.removeLast()
                } else { components.append(String(component)) }
            }
            return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
        }
    }
}
