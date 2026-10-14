#if os(macOS)
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import IntentsAutomationCore

extension AutomationCLI {
    static func schemeTargetIDs(project: URL, scheme: String) throws -> Set<String> {
        guard !scheme.isEmpty, scheme != ".", scheme != "..", !scheme.contains("/"), !scheme.contains("\\") else {
            throw AutomationContractError.invalidIdentity
        }
        var files = [project.appendingPathComponent("xcshareddata/xcschemes/" + scheme + ".xcscheme")]
        let users = project.appendingPathComponent("xcuserdata")
        if FileManager.default.fileExists(atPath: users.path) {
            let folders = try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)
            guard folders.count <= 100 else { throw AutomationContractError.invalidIdentity }
            files += folders.filter { $0.pathExtension == "xcuserdatad" }.map {
                $0.appendingPathComponent("xcschemes/" + scheme + ".xcscheme")
            }
        }
        let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard present.count == 1, let file = present.first else {
            throw AutomationContractError.invalidPlan("Scheme must identify exactly one saved scheme")
        }
        let canonical = try AutomationPath.canonical(file)
        guard canonical.path == file.path, canonical.path.hasPrefix(project.path + "/") else {
            throw AutomationContractError.invalidIdentity
        }
        let data = try read(canonical.path, maximumBytes: 1_048_576)
        let delegate = AutomationSchemeParser(projectName: project.lastPathComponent)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, !delegate.identifiers.isEmpty else { throw AutomationContractError.invalidPlan("Scheme has no local build application target") }
        return delegate.identifiers
    }
}

private final class AutomationSchemeParser: NSObject, XMLParserDelegate {
    let projectName: String
    var identifiers: Set<String> = []
    var invalid = false
    private var buildAction = false
    private var runnableEntry = false
    init(projectName: String) { self.projectName = projectName }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "BuildAction" { buildAction = true }
        if elementName == "BuildActionEntry", buildAction { runnableEntry = attributes["buildForRunning"] == "YES" }
        if elementName == "BuildableReference", buildAction, runnableEntry,
           attributes["ReferencedContainer"] == "container:" + projectName,
           let identifier = attributes["BlueprintIdentifier"] { identifiers.insert(identifier) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "BuildActionEntry" { runnableEntry = false }
        if elementName == "BuildAction" { buildAction = false; runnableEntry = false }
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
}
#endif
