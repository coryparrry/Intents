import Foundation

public struct AutomationApplicationCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case sourceTarget, installedProduct }
    public var id: String
    public var name: String
    public var kind: Kind
    public var containerPath: String
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
            for projectURL in resolved.projects { let assessment = try project(projectURL); candidates += assessment.candidates; gaps += assessment.gaps }
            if candidates.isEmpty { gaps.append("No in-root application target was resolved from this workspace.") }
            return .init(candidates: candidates, gaps: gaps, requiresBuildApproval: true)
        case "xcarchive", "ipa":
            return .init(candidates: [], gaps: ["Archive/export preparation requires an authorised qualified recipe."], requiresBuildApproval: true)
        default:
            let contents = try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: [.isDirectoryKey])
            let projects = contents.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.path < $1.path }
            var candidates: [AutomationApplicationCandidate] = [], gaps: [String] = []
            for entry in projects { let result = try project(entry); candidates += result.candidates; gaps += result.gaps }
            if projects.isEmpty { gaps.append("No top-level Xcode app project found. Select the actual workspace, generated project or packaged app.") }
            return .init(candidates: candidates, gaps: gaps, requiresBuildApproval: true)
        }
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
