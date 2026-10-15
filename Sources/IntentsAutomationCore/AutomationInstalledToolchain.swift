#if os(macOS)
import Foundation

/// Installed Xcodes only. Discovery never installs software or accepts Command Line Tools as Xcode.
public enum AutomationInstalledToolchain {
    public struct Candidate: Equatable, Sendable {
        public var directory: URL
        public var version: [Int]
        public var preference: Int
        public init(directory: URL, version: [Int], preference: Int) {
            self.directory = directory; self.version = version; self.preference = preference
        }
    }
    public struct Metadata: Equatable, Sendable {
        public let version: String
        public let build: String
        public let digest: String
    }
    public static func metadata(directory: URL) throws -> Metadata {
        guard try AutomationPath.canonical(directory) == directory else { throw AutomationContractError.invalidIdentity }
        let contents = directory.deletingLastPathComponent()
        let infoData = try AutomationReadOnlyFile.read(contents.appendingPathComponent("Info.plist"), maximumBytes: 1_048_576)
        let versionData = try AutomationReadOnlyFile.read(contents.appendingPathComponent("version.plist"), maximumBytes: 1_048_576)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
              let version = info["CFBundleShortVersionString"] as? String,
              version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil,
              let fields = try PropertyListSerialization.propertyList(from: versionData, format: nil) as? [String: Any],
              let build = fields["ProductBuildVersion"] as? String,
              build.range(of: #"^[A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(version: version, build: build,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(["info": AutomationArtifactRegistry.digest(infoData), "version": AutomationArtifactRegistry.digest(versionData)])))
    }
    public static var selectedDirectory: URL? {
        try? AutomationPath.canonical(URL(fileURLWithPath: "/var/db/xcode_select_link"))
    }
    public static var applicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    public static func developerURL(_ url: URL) -> URL {
        url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer") : url
    }
    public static func candidates(configured: URL?, selected: URL? = selectedDirectory,
                                  applications: [URL] = applicationDirectories) -> [Candidate] {
        var paths: [(URL, Int)] = []
        if let configured { paths.append((developerURL(configured), 0)) }
        if let selected { paths.append((developerURL(selected), 1)) }
        for root in applications {
            let apps = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            paths += apps.filter { $0.pathExtension == "app" }.map { (developerURL($0), 2) }
        }
        var unique: [String: Candidate] = [:]
        for (path, preference) in paths {
            guard let directory = try? AutomationPath.canonical(path), directory.lastPathComponent == "Developer",
                  directory.deletingLastPathComponent().lastPathComponent == "Contents" else { continue }
            let info = directory.deletingLastPathComponent().appendingPathComponent("Info.plist")
            guard let data = try? AutomationReadOnlyFile.read(info, maximumBytes: 1_048_576),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
                  let version = plist["CFBundleShortVersionString"] as? String else { continue }
            let numbers = version.split(separator: ".").compactMap { Int($0) }
            guard !numbers.isEmpty else { continue }
            if unique[directory.path] == nil || preference < unique[directory.path]!.preference {
                unique[directory.path] = Candidate(directory: directory, version: numbers, preference: preference)
            }
        }
        return ranked(Array(unique.values))
    }
    static func ranked(_ candidates: [Candidate], requiredDirectory: URL? = nil) -> [Candidate] {
        candidates.filter { requiredDirectory == nil || $0.directory == requiredDirectory }.sorted {
            if $0.preference != $1.preference { return $0.preference < $1.preference }
            for index in 0..<max($0.version.count, $1.version.count) {
                let a = index < $0.version.count ? $0.version[index] : 0
                let b = index < $1.version.count ? $1.version[index] : 0
                if a != b { return a > b }
            }
            return $0.directory.path < $1.directory.path
        }
    }
    public static func select(candidates: [Candidate], requiredSDK: String, requiredDirectory: URL? = nil,
                              probe: (URL, String) throws -> Bool) throws -> URL {
        for candidate in ranked(candidates, requiredDirectory: requiredDirectory) where try probe(candidate.directory, requiredSDK) { return candidate.directory }
        throw unavailable(requiredSDK)
    }
    public static func diskEligible(_ directory: URL, sdk: String) -> Bool {
        let platform: String
        switch sdk {
        case "macosx": platform = "MacOSX"
        case "iphonesimulator": platform = "iPhoneSimulator"
        case "iphoneos": platform = "iPhoneOS"
        default: return false
        }
        let files = FileManager.default
        guard files.isExecutableFile(atPath: directory.appendingPathComponent("usr/bin/xcodebuild").path),
              files.isExecutableFile(atPath: directory.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc").path) else { return false }
        let root = directory.appendingPathComponent("Platforms/" + platform + ".platform/Developer/SDKs")
        let sdks = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return sdks.contains { $0.pathExtension == "sdk" && files.fileExists(atPath: $0.appendingPathComponent("SDKSettings.plist").path) }
    }
    static func resolve(configured: URL, sdk: String, command: AutomationOwnedCommand, workspace: URL,
                        requireConfiguredDirectory: Bool = false, willStart: @escaping @Sendable () async throws -> Void) async throws -> URL {
        let required = requireConfiguredDirectory ? try AutomationPath.canonical(developerURL(configured)) : nil
        for candidate in ranked(candidates(configured: configured), requiredDirectory: required).prefix(32) where diskEligible(candidate.directory, sdk: sdk) {
            let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": candidate.directory.path]
            var eligible = true
            for arguments in [["xcodebuild", "-version"], ["--sdk", sdk, "--show-sdk-path"], ["swiftc", "--version"]] {
                do {
                    let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments,
                        directory: workspace, environment: environment, timeout: .seconds(15), willStart: willStart)
                    if result.exitStatus != 0 || result.logsTruncated || result.stdout.isEmpty { eligible = false; break }
                } catch {
                    try Task.checkCancellation(); try await willStart()
                    eligible = false; break
                }
            }
            if eligible { return candidate.directory }
        }
        if requireConfiguredDirectory {
            throw AutomationContractError.missingEvidence("The selected Xcode could not provide the required SDK and Swift toolchain. Refresh or choose another installed Xcode, then review the build again.")
        }
        throw unavailable(sdk)
    }
    private static func unavailable(_ sdk: String) -> AutomationContractError {
        .missingEvidence("No eligible installed Xcode provides the \(sdk) SDK and Swift toolchain. Install a compatible Xcode in Applications, open it to complete installation and accept its licence, then retry. An invalid DEVELOPER_DIR can be cleared or set to that Xcode's Contents/Developer folder. App inspection remains available.")
    }
}
struct AutomationReviewedToolchain: Sendable {
    let directory: URL
    let metadataDigest: String
    func validate() throws {
        guard metadataDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              (try? AutomationInstalledToolchain.metadata(directory: directory).digest) == metadataDigest else {
            throw AutomationContractError.missingEvidence("The reviewed Xcode installation changed. Refresh or choose the installed Xcode, then review and prepare a fresh private copy.")
        }
    }
}
#endif
