import Foundation

private final class WorkspaceProjectReferenceParser: NSObject, XMLParserDelegate {
    private let containerBase: URL
    private let fileManager: FileManager
    private var groupBases: [URL]
    private(set) var projects: [URL] = []

    init(workspace: URL, fileManager: FileManager) {
        containerBase = workspace.deletingLastPathComponent()
        self.fileManager = fileManager
        groupBases = [containerBase]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Group" {
            groupBases.append(resolve(attributeDict["location"], groupRelativeTo: groupBases.last!) ?? groupBases.last!)
        } else if elementName == "FileRef",
                  let url = resolve(attributeDict["location"], groupRelativeTo: groupBases.last!),
                  url.pathExtension == "xcodeproj",
                  fileManager.fileExists(atPath: url.path) {
            projects.append(url.standardizedFileURL)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Group", groupBases.count > 1 { groupBases.removeLast() }
    }

    private func resolve(_ location: String?, groupRelativeTo groupBase: URL) -> URL? {
        guard let location,
              let separator = location.firstIndex(of: ":") else { return nil }
        let kind = location[..<separator]
        let path = String(location[location.index(after: separator)...])
        switch kind {
        case "group": return groupBase.appending(path: path)
        case "container": return containerBase.appending(path: path)
        case "absolute": return URL(filePath: path)
        default: return nil
        }
    }
}

private final class SchemeTestActionConfigurationParser: NSObject, XMLParserDelegate {
    private(set) var buildConfiguration: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "TestAction" {
            buildConfiguration = attributeDict["buildConfiguration"]
        }
    }
}

struct IntentLabDeviceDestination: Codable, Equatable, Identifiable, Sendable {
    var id: String { identifier }
    var identifier: String
    var name: String
    var operatingSystemVersion: String?
    var available: Bool
}

struct XcodeDiscoveredProduct: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(projectPath ?? "")#\(targetID ?? targetName)" }
    var targetName: String
    var bundleIdentifier: String
    var productType: String
    var isApplication: Bool
    var isUITestBundle: Bool
    var projectPath: String? = nil
    var targetID: String? = nil
    var harnessVersion: String? = nil
    var harnessCapabilities: [String] = []
    var signingConfigured: Bool = false
}

struct XcodeConnectionDiscovery: Codable, Equatable, Sendable {
    var schemes: [String]
    var applications: [XcodeDiscoveredProduct]
    var uiTestBundles: [XcodeDiscoveredProduct]

    var automaticallySelectedScheme: String? {
        if schemes.count == 1 { return schemes[0] }
        guard applications.count == 1 else { return nil }
        return schemes.first { $0 == applications[0].targetName }
    }
}

enum XcodeConnectionDiscoveryError: LocalizedError, Sendable {
    case invalidContainer
    case commandFailed(String)
    case invalidOutput(String)
    case noSchemes
    case noApplication
    case noUITestTarget

    var errorDescription: String? {
        switch self {
        case .invalidContainer: "Choose an existing .xcodeproj or .xcworkspace."
        case .commandFailed(let detail): "Xcode project discovery failed: \(detail)"
        case .invalidOutput(let detail): "Xcode returned invalid discovery data: \(detail)"
        case .noSchemes: "The selected container has no shared schemes."
        case .noApplication: "No iOS application target was found."
        case .noUITestTarget: "No signed UI-test target was found. Add the Intent Lab harness to a UI-test target first."
        }
    }
}

struct XcodeConnectionDiscoveryService: Sendable {
    var xcodebuildPath = "/usr/bin/xcodebuild"
    var xcdevicePath = "/usr/bin/xcrun"

    func discoverProject(container: URL, configuration: String = "Debug") throws -> XcodeConnectionDiscovery {
        guard FileManager.default.fileExists(atPath: container.path),
              ["xcodeproj", "xcworkspace"].contains(container.pathExtension) else {
            throw XcodeConnectionDiscoveryError.invalidContainer
        }
        let selector = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let listingData = try run(
            executable: xcodebuildPath,
            arguments: [selector, container.path, "-list", "-json"]
        )
        let listing = try Self.parseListing(listingData)
        guard !listing.schemes.isEmpty else { throw XcodeConnectionDiscoveryError.noSchemes }

        var products: [XcodeDiscoveredProduct] = []
        if container.pathExtension == "xcworkspace" {
            // Workspaces do not expose a target list. Schemes identify app products,
            // while their referenced projects provide the UI-test target metadata.
            for scheme in listing.schemes {
                let data = try run(
                    executable: xcodebuildPath,
                    arguments: [selector, container.path, "-scheme", scheme, "-configuration", configuration, "-showBuildSettings", "-json"]
                )
                products.append(contentsOf: try Self.parseBuildSettings(data))
            }
            for project in try Self.workspaceProjectURLs(workspace: container) {
                let projectListingData = try run(
                    executable: xcodebuildPath,
                    arguments: ["-project", project.path, "-list", "-json"]
                )
                let projectListing = try Self.parseListing(projectListingData)
                products.append(contentsOf: try productsForTargets(
                    projectListing.targets,
                    selector: "-project",
                    container: project,
                    configuration: configuration
                ))
            }
        } else {
            products.append(contentsOf: try productsForTargets(
                listing.targets,
                selector: selector,
                container: container,
                configuration: configuration
            ))
        }
        // Scheme settings may repeat products obtained from the owning project. Prefer
        // the project-scoped identity; never merge equal display names from two projects.
        let identified = products.filter { $0.projectPath != nil }
        let uniqueProducts = identified.isEmpty
            ? Array(Dictionary(grouping: products, by: \.id).compactMap(\.value.first))
            : Array(Dictionary(grouping: identified, by: \.id).compactMap(\.value.first))
        let applications = uniqueProducts.filter(\.isApplication).sorted { $0.targetName < $1.targetName }
        let uiTests = uniqueProducts.filter(\.isUITestBundle).sorted { $0.targetName < $1.targetName }
        guard !applications.isEmpty else { throw XcodeConnectionDiscoveryError.noApplication }
        return .init(schemes: listing.schemes, applications: applications, uiTestBundles: uiTests)
    }

    /// Reads the configuration Xcode uses for the selected scheme's Test action.
    /// A workspace can contain same-named project schemes; require an owner when
    /// their configurations differ rather than choosing an arbitrary project.
    static func testActionBuildConfiguration(
        container: URL,
        scheme: String,
        preferredProjectPath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard !scheme.isEmpty, !scheme.contains("/"), !scheme.contains("\\") else { return nil }
        let container = container.standardizedFileURL
        let relativePath = "xcshareddata/xcschemes/\(scheme).xcscheme"
        var candidates: [URL] = []
        if container.pathExtension == "xcworkspace" {
            let workspaceScheme = container.appending(path: relativePath)
            if fileManager.fileExists(atPath: workspaceScheme.path) {
                candidates.append(workspaceScheme)
            }
            for project in try workspaceProjectURLs(workspace: container, fileManager: fileManager) {
                let projectScheme = project.appending(path: relativePath)
                if fileManager.fileExists(atPath: projectScheme.path) {
                    candidates.append(projectScheme)
                }
            }
        } else if container.pathExtension == "xcodeproj" {
            let projectScheme = container.appending(path: relativePath)
            if fileManager.fileExists(atPath: projectScheme.path) {
                candidates.append(projectScheme)
            }
        }
        guard !candidates.isEmpty else { return nil }
        if let preferredProjectPath {
            let owner = URL(filePath: preferredProjectPath).standardizedFileURL
            let owned = candidates.filter {
                $0.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().standardizedFileURL.path == owner.path
            }
            if !owned.isEmpty { candidates = owned }
        }
        let configurations = try candidates.map { schemeURL -> String? in
            guard let parser = XMLParser(contentsOf: schemeURL) else {
                throw XcodeConnectionDiscoveryError.invalidOutput("the selected scheme cannot be read")
            }
            let collector = SchemeTestActionConfigurationParser()
            parser.delegate = collector
            guard parser.parse() else {
                throw XcodeConnectionDiscoveryError.invalidOutput(
                    parser.parserError?.localizedDescription ?? "malformed scheme XML"
                )
            }
            return collector.buildConfiguration?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let available = Set(configurations.compactMap { value in
            value.flatMap { $0.isEmpty ? nil : $0 }
        })
        if available.count > 1 || configurations.contains(where: { $0 == nil || $0?.isEmpty == true }) && !available.isEmpty {
            throw XcodeConnectionDiscoveryError.invalidOutput(
                "multiple schemes named \(scheme) use different Test build configurations; choose the owning app project or enter a configuration manually"
            )
        }
        return available.first
    }

    func discoverDevices() throws -> [IntentLabDeviceDestination] {
        let data = try run(executable: xcdevicePath, arguments: ["xcdevice", "list", "--timeout", "3"])
        return try Self.parseDevices(data)
    }

    static func parseListing(_ data: Data) throws -> (schemes: [String], targets: [String]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = (root["project"] ?? root["workspace"]) as? [String: Any] else {
            throw XcodeConnectionDiscoveryError.invalidOutput("missing project or workspace listing")
        }
        return (
            (container["schemes"] as? [String] ?? []).sorted(),
            (container["targets"] as? [String] ?? []).sorted()
        )
    }

    static func parseBuildSettings(_ data: Data, project: URL? = nil) throws -> [XcodeDiscoveredProduct] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XcodeConnectionDiscoveryError.invalidOutput("build settings are not an array")
        }
        let targetIDs = project.flatMap { try? targetIdentifiers(in: $0) } ?? [:]
        return entries.compactMap { entry in
            guard let settings = entry["buildSettings"] as? [String: Any],
                  let target = entry["target"] as? String else { return nil }
            let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String ?? ""
            let productType = settings["PRODUCT_TYPE"] as? String ?? settings["PRODUCT_TYPE_IDENTIFIER"] as? String ?? ""
            let wrapperExtension = settings["WRAPPER_EXTENSION"] as? String ?? ""
            let isUITest = productType.contains("ui-testing") || settings["UITEST_TARGET_APP_PATH"] != nil
            let isApp = productType == "com.apple.product-type.application"
                || (wrapperExtension == "app" && !target.hasSuffix("UITests-Runner"))
            guard isApp || isUITest else { return nil }
            return .init(
                targetName: target,
                bundleIdentifier: bundleID,
                productType: productType,
                isApplication: isApp,
                isUITestBundle: isUITest,
                projectPath: project?.standardizedFileURL.path,
                targetID: targetIDs[target],
                harnessVersion: settings["INTENT_LAB_HARNESS_VERSION"] as? String,
                harnessCapabilities: ((settings["INTENT_LAB_HARNESS_CAPABILITIES"] as? String) ?? "")
                    .split(whereSeparator: { $0 == " " || $0 == "," })
                    .map(String.init),
                signingConfigured: ((settings["CODE_SIGNING_ALLOWED"] as? String) ?? "YES") != "NO"
                    && !((settings["DEVELOPMENT_TEAM"] as? String) ?? "").isEmpty
            )
        }
    }

    private static func targetIdentifiers(in project: URL) throws -> [String: String] {
        let data = try Data(contentsOf: project.appending(path: "project.pbxproj"))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]] else { return [:] }
        let pairs: [(String, String)] = objects.compactMap { id, object in
            guard object["isa"] as? String == "PBXNativeTarget",
                  let name = object["name"] as? String else { return nil }
            return (name, id)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    static func workspaceProjectURLs(workspace: URL, fileManager: FileManager = .default) throws -> [URL] {
        let contents = workspace.appending(path: "contents.xcworkspacedata")
        guard let parser = XMLParser(contentsOf: contents) else {
            throw XcodeConnectionDiscoveryError.invalidOutput("the workspace has no readable contents.xcworkspacedata")
        }
        let delegate = WorkspaceProjectReferenceParser(workspace: workspace, fileManager: fileManager)
        parser.delegate = delegate
        guard parser.parse() else {
            throw XcodeConnectionDiscoveryError.invalidOutput(parser.parserError?.localizedDescription ?? "malformed workspace XML")
        }
        return Array(Set(delegate.projects)).sorted { $0.path < $1.path }
    }

    static func parseDevices(_ data: Data) throws -> [IntentLabDeviceDestination] {
        guard let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XcodeConnectionDiscoveryError.invalidOutput("device list is not an array")
        }
        return devices.compactMap { device in
            guard (device["simulator"] as? Bool) == false,
                  device["platform"] as? String == "com.apple.platform.iphoneos",
                  let identifier = device["identifier"] as? String,
                  let name = device["name"] as? String else { return nil }
            return .init(
                identifier: identifier,
                name: name,
                operatingSystemVersion: device["operatingSystemVersion"] as? String,
                available: (device["available"] as? Bool) == true && (device["ignored"] as? Bool) != true
            )
        }.sorted { ($0.available ? 0 : 1, $0.name) < ($1.available ? 0 : 1, $1.name) }
    }

    private func productsForTargets(
        _ targets: [String],
        selector: String,
        container: URL,
        configuration: String
    ) throws -> [XcodeDiscoveredProduct] {
        var products: [XcodeDiscoveredProduct] = []
        for target in targets {
            let data = try run(
                executable: xcodebuildPath,
                arguments: [selector, container.path, "-target", target, "-configuration", configuration, "-showBuildSettings", "-json"]
            )
            products.append(contentsOf: try Self.parseBuildSettings(data, project: container))
        }
        return products
    }

    private func run(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabDiscovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "stdout")
        let errorURL = directory.appending(path: "stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            throw XcodeConnectionDiscoveryError.commandFailed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw XcodeConnectionDiscoveryError.commandFailed("the inspection timed out after 120 seconds")
        }
        try output.close()
        try error.close()
        let data = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw XcodeConnectionDiscoveryError.commandFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        return data
    }
}
