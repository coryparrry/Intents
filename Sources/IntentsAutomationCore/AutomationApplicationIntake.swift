import Foundation

public struct AutomationApplicationCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case sourceTarget, installedProduct }
    public var id: String
    public var name: String
    public var kind: Kind
    public var containerPath: String
    public var workspacePath: String? = nil
    public var targetID: String?
    public var bundleID: String?
    public var platform: String?
    public var architectures: [String]
    public var configurations: [String] = []
    public var app: AppIdentity?
}

public struct AutomationIntakeAssessment: Codable, Equatable, Sendable {
    public var candidates: [AutomationApplicationCandidate]
    public var gaps: [String]
    public var requiresBuildApproval: Bool
}

/// Pure intake: discovering a source target never runs Xcode, resolves packages or approves scripts.
public enum AutomationApplicationIntake {
    public static func assess(_ input: URL) throws -> AutomationIntakeAssessment {
        let canonical = try AutomationPath.canonical(input)
        guard canonical.path == input.path else { throw AutomationContractError.invalidIdentity }
        switch canonical.pathExtension.lowercased() {
        case "app": return try product(canonical)
        case "xcodeproj": return try project(canonical)
        case "xcworkspace":
            let resolved = try AutomationWorkspaceProjects.resolve(canonical)
            var candidates: [AutomationApplicationCandidate] = [], gaps = resolved.gaps
            for projectURL in resolved.projects { let assessment = try project(projectURL); candidates += assessment.candidates.map { inWorkspace($0, canonical) }; gaps += assessment.gaps }
            if candidates.isEmpty { gaps.append("No in-root application target was resolved from this workspace.") }
            return .init(candidates: candidates, gaps: gaps, requiresBuildApproval: true)
        case "xcarchive": return try archive(canonical)
        case "ipa":
            return .init(candidates: [], gaps: ["Select this IPA in App automation to inspect and extract it into a private app copy. Device installation eligibility is checked separately."], requiresBuildApproval: false)
        default:
            return try folder(canonical)
        }
    }
    private static func folder(_ root: URL) throws -> AutomationIntakeAssessment {
        let entries = try AutomationSourceEntryPoints.discover(root)
        var projects = Set(entries.projects), gaps = entries.gaps
        var contexts: [URL: [URL]] = [:]
        for workspace in entries.workspaces {
            guard projects.count < 256 else { gaps.append("Repository project inspection reached its limit. Select a more specific app folder."); break }
            do {
                let resolved = try AutomationWorkspaceProjects.resolve(workspace, authorizedRoot: root)
                for project in resolved.projects where AutomationSourceEntryPoints.isPrimary(project, under: root) {
                    guard projects.count < 256 else { gaps.append("Repository project inspection reached its limit. Select a more specific app folder."); break }
                    projects.insert(project)
                    contexts[project, default: []].append(workspace)
                }
                gaps += resolved.gaps
            } catch { gaps.append("Could not inspect workspace " + workspace.lastPathComponent + ". Other app projects remain available.") }
        }
        var candidates: [AutomationApplicationCandidate] = []
        for entry in projects.sorted(by: { $0.path < $1.path }) {
            do {
                let result = try project(entry)
                if let workspaces = contexts[entry], !workspaces.isEmpty {
                    candidates += workspaces.sorted { $0.path < $1.path }.flatMap { workspace in
                        result.candidates.map { inWorkspace($0, workspace) }
                    }
                } else { candidates += result.candidates }
                gaps += result.gaps
            }
            catch { gaps.append("Could not inspect project " + entry.lastPathComponent + ". Other app projects remain available.") }
        }
        if candidates.isEmpty { gaps.append("No application target was resolved. Select a workspace, app project or packaged app, or review the discovery details.") }
        return .init(candidates: candidates.sorted { $0.id < $1.id }, gaps: Array(Set(gaps)).sorted(), requiresBuildApproval: true)
    }
    static func inWorkspace(_ candidate: AutomationApplicationCandidate, _ workspace: URL) -> AutomationApplicationCandidate {
        var value = candidate
        value.workspacePath = workspace.path
        value.id = workspace.path + "::" + candidate.id
        return value
    }
    private static func archive(_ archive: URL) throws -> AutomationIntakeAssessment {
        let products = archive.appendingPathComponent("Products/Applications")
        guard try AutomationPath.canonical(products).path == products.path else { throw AutomationContractError.invalidIdentity }
        let entries = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
        guard entries.count <= 64 else { throw AutomationContractError.invalidPlan("The archive contains too many application entries") }
        var candidates: [AutomationApplicationCandidate] = [], gaps: [String] = []
        for entry in entries.filter({ $0.pathExtension.lowercased() == "app" }).sorted(by: { $0.path < $1.path }) {
            do {
                guard try AutomationPath.canonical(entry).path == entry.path else { throw AutomationContractError.invalidIdentity }
                let result = try product(entry); candidates += result.candidates; gaps += result.gaps
            } catch { gaps.append("Could not validate archived app " + entry.lastPathComponent + ". It cannot be selected for execution.") }
        }
        if candidates.isEmpty { gaps.append("No eligible app product was found in the archive.") }
        gaps.append("Archived products retain their original signing. Device installation and system-action eligibility are checked separately.")
        return .init(candidates: candidates, gaps: Array(Set(gaps)).sorted(), requiresBuildApproval: false)
    }
    private static func project(_ url: URL) throws -> AutomationIntakeAssessment {
        guard try AutomationPath.canonical(url).path == url.path,
              let plist = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(root: url, relativePath: "project.pbxproj", maximumBytes: 16 * 1024 * 1024), format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { throw AutomationContractError.invalidIdentity }
        let candidates = objects.compactMap { id, object -> AutomationApplicationCandidate? in
            guard object["isa"] as? String == "PBXNativeTarget", object["productType"] as? String == "com.apple.product-type.application",
                  let name = object["name"] as? String, !name.isEmpty else { return nil }
            let configurations = (object["buildConfigurationList"] as? String).flatMap { objects[$0]?["buildConfigurations"] as? [String] } ?? []
            return .init(id: url.path + "#" + id, name: name, kind: .sourceTarget, containerPath: url.path, targetID: id,
                         bundleID: nil, platform: nil, architectures: [], configurations: configurations.compactMap { objects[$0]?["name"] as? String }.sorted(), app: nil)
        }.sorted { $0.id < $1.id }
        return .init(candidates: candidates, gaps: ["Build configuration, dependencies, signing and registered system interfaces require approved Xcode discovery."], requiresBuildApproval: true)
    }
    private static func product(_ url: URL) throws -> AutomationIntakeAssessment {
        let isMac = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        let infoPath = isMac ? "Contents/Info.plist" : "Info.plist"
        let digest = try AutomationProductDigest.compute(bundle: url, version: isMac ? 2 : nil)
        guard let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: url, relativePath: infoPath, maximumBytes: 1_048_576, version: isMac ? 2 : nil, expectedDigest: digest), format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL", let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw AutomationContractError.invalidIdentity
        }
        let executablePath = isMac ? "Contents/MacOS/" + executable : executable
        let binary = try AutomationProductDigest.readFile(bundle: url, relativePath: executablePath, maximumBytes: 512 * 1024 * 1024, version: isMac ? 2 : nil, expectedDigest: digest)
        let architectures = try AutomationMachOIdentity.architectures(binary)
        let declaredPlatforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let platform = isMac ? "macos" : "ios"
        guard isMac || declaredPlatforms.contains("iPhoneSimulator") || declaredPlatforms.contains("iPhoneOS") else {
            throw AutomationContractError.invalidPlan("Product platform is not qualified for intake")
        }
        var app = AppIdentity(logicalID: url.path, bundleID: bundleID, platform: platform, productDigest: digest)
        app.productDigestVersion = isMac ? 2 : nil
        app.canonicalBundlePath = url.path; app.architecture = architectures.joined(separator: ",")
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        return .init(candidates: [.init(id: url.path, name: name, kind: .installedProduct, containerPath: url.path, targetID: nil,
                                      bundleID: bundleID, platform: platform, architectures: architectures, app: app)],
                     gaps: ["Target eligibility, code signature and registered system interfaces must be checked before execution."], requiresBuildApproval: false)
    }
}

enum AutomationMachOIdentity {
    static func architectures(_ data: Data) throws -> [String] {
        guard data.count >= 12 else { throw AutomationContractError.invalidIdentity }
        func integer(_ offset: Int, big: Bool) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw AutomationContractError.invalidIdentity }
            let bytes = Array(data[offset..<offset + 4])
            return (big ? bytes : bytes.reversed()).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32) throws -> String {
            switch cpu { case 0x0100000c: return "arm64"; case 0x01000007: return "x86_64"; default: throw AutomationContractError.invalidPlan("Unqualified CPU architecture") }
        }
        let magic = try integer(0, big: true)
        if magic == 0xcffaedfe || magic == 0xfeedfacf {
            return [try name(integer(4, big: magic == 0xfeedfacf))]
        }
        guard magic == 0xcafebabe || magic == 0xbebafeca || magic == 0xcafebabf || magic == 0xbfbafeca else { throw AutomationContractError.invalidIdentity }
        let big = magic == 0xcafebabe || magic == 0xcafebabf
        let count = Int(try integer(4, big: big)), stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
        guard (1...16).contains(count), 8 + count * stride <= data.count else { throw AutomationContractError.invalidIdentity }
        let result = try (0..<count).map { try name(integer(8 + $0 * stride, big: big)) }
        guard Set(result).count == result.count else { throw AutomationContractError.invalidIdentity }
        return result.sorted()
    }
}
