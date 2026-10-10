import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads only in-root references. External roots remain an explicit access/build approval decision.
enum AutomationWorkspaceProjects {
    struct Resolution { var projects: [URL]; var gaps: [String] }
    static func resolve(_ workspace: URL) throws -> Resolution {
        let data = try AutomationReadOnlyFile.read(root: workspace, relativePath: "contents.xcworkspacedata", maximumBytes: 1_048_576)
        guard String(decoding: data, as: UTF8.self).range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw AutomationContractError.invalidIdentity }
        let root = try AutomationPath.canonical(workspace.deletingLastPathComponent())
        let delegate = Reader(root: root)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed else { throw AutomationContractError.invalidIdentity }
        return .init(projects: Array(Set(delegate.projects)).sorted { $0.path < $1.path }, gaps: delegate.gaps)
    }
    private final class Reader: NSObject, XMLParserDelegate {
        let root: URL
        var groups: [URL?]
        var projects: [URL] = [], gaps: [String] = []
        var count = 0, failed = false
        init(root: URL) { self.root = root; groups = [root] }
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
                guard actual.path.hasPrefix(root.path + "/") else { gaps.append("Workspace project is outside the authorised source root."); return }
                projects.append(actual)
            } catch { gaps.append("A referenced workspace project is unavailable.") }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Group", groups.count > 1 { groups.removeLast() }
        }
        private func location(_ text: String) -> URL? {
            guard let parent = groups.last ?? nil, !text.contains("\0"), let colon = text.firstIndex(of: ":") else { return nil }
            let kind = String(text[..<colon]), path = String(text[text.index(after: colon)...])
            switch kind {
            case "group": return parent.appendingPathComponent(path).standardizedFileURL
            case "container": return root.appendingPathComponent(path).standardizedFileURL
            default: return nil
            }
        }
    }
}
