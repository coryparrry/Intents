import AppKit
import CryptoKit
import Foundation
import Security

/// The editable settings used by both automatic setup and the native test runners.
public struct SiriStudioSetupConfiguration: Equatable, Sendable {
    public var developerDirectory: String
    public var teamIdentifier: String
    public var signingIdentity: String

    /// Creates a settings snapshot so discovery cannot overwrite edits made while it runs.
    public init(developerDirectory: String = "", teamIdentifier: String = "", signingIdentity: String = "") {
        self.developerDirectory = developerDirectory
        self.teamIdentifier = teamIdentifier
        self.signingIdentity = signingIdentity
    }
}

/// A compatible Xcode installation discovered from its bundle and developer framework.
public struct SiriStudioXcode: Equatable, Sendable {
    public let developerDirectory: String
    public let version: String

    /// Records a developer directory whose version and SiriEvaluations framework were checked.
    public init(developerDirectory: String, version: String) {
        self.developerDirectory = developerDirectory
        self.version = version
    }
}

/// A valid development signing identity, matched to its certificate's actual team rather than its display name.
public struct SiriStudioSigningIdentity: Equatable, Sendable {
    public let fingerprint: String
    public let name: String
    public let team: String

    /// Stores the exact certificate fingerprint that codesign can select unambiguously.
    public init(fingerprint: String, name: String, team: String) {
        self.fingerprint = fingerprint
        self.name = name
        self.team = team
    }
}

/// A local prerequisite snapshot; Siri AI readiness remains an explicit user confirmation.
public struct SiriStudioSetupReport: Sendable {
    public let osSupported: Bool
    public let osVersion: String
    public let xcodes: [SiriStudioXcode]
    public let xcodeReady: Bool
    public let identities: [SiriStudioSigningIdentity]
    public let applicationTeam: String?
    public let registered: Bool
    public let registeredApplicationPath: String?
    public let running: Bool
    public let xcodegen: String?
    public let configuration: SiriStudioSetupConfiguration

    /// Creates a report without claiming that Siri AI or its downloaded models can be detected publicly.
    public init(osSupported: Bool, osVersion: String, xcodes: [SiriStudioXcode], xcodeReady: Bool = true,
                identities: [SiriStudioSigningIdentity], applicationTeam: String?, registered: Bool,
                running: Bool, xcodegen: String?, configuration: SiriStudioSetupConfiguration, registeredApplicationPath: String? = nil) {
        self.osSupported = osSupported; self.osVersion = osVersion; self.xcodes = xcodes; self.xcodeReady = xcodeReady
        self.identities = identities; self.applicationTeam = applicationTeam
        self.registered = registered; self.registeredApplicationPath = registeredApplicationPath
        self.running = running; self.xcodegen = xcodegen
        self.configuration = configuration
    }
}

/// Owns bounded, read-only prerequisite commands and retains their process ownership across rechecks.
@MainActor public final class SiriStudioSetupDiscovery {
    private let command = MacIntentOwnedCommand()

    /// Creates a discovery session; it never installs Xcode, changes xcode-select, or re-signs the subject app.
    public init() {}

    /// Finds compatible Xcodes and a valid development identity from the subject's own signing team.
    public func detect(appURL: URL, preferred: SiriStudioSetupConfiguration) async throws -> SiriStudioSetupReport {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "siri-setup-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let selected = try await output("/usr/bin/xcode-select", ["-p"], in: directory).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = [URL(filePath: "/Applications"), files.homeDirectoryForCurrentUser.appending(path: "Applications")]
        let candidates = roots.flatMap { (try? files.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "app" }.map { $0.appending(path: "Contents/Developer").path }
            + [preferred.developerDirectory, ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "", selected]
        let xcodes = Self.compatibleXcodes(candidates)
        let developer = Self.chooseXcode(xcodes, preferred: preferred.developerDirectory, selected: selected)
        var xcodeReady = false
        if let developer {
            xcodeReady = try await output(developer.developerDirectory + "/usr/bin/xcodebuild",
                ["-checkFirstLaunchStatus"], in: directory, developer: developer.developerDirectory).status == 0
        }
        let signature = try await output("/usr/bin/codesign", ["-d", "--verbose=4", appURL.path], in: directory)
        let rawTeam = signature.status == 0 ? MacIntentRunner.signingTeam(in: signature.text) : nil
        let team = rawTeam.flatMap { $0.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil ? $0 : nil }
        var identities: [SiriStudioSigningIdentity] = []
        if team != nil {
            let valid = try await output("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], in: directory)
            let certificates = try await output("/usr/bin/security", ["find-certificate", "-a", "-p"], in: directory)
            if valid.status == 0, certificates.status == 0 {
                identities = Self.developmentIdentities(validOutput: valid.text, pem: certificates.text)
            }
        }
        let identity = Self.chooseIdentity(identities, team: team, preferred: preferred.signingIdentity)
        let bundle = (try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let identifier = bundle?["CFBundleIdentifier"] as? String
        let installed = identifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let registered = installed.map { MacIntentRunner.sameApplicationPath($0, appURL) } ?? false
        let running = identifier.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return .init(osSupported: os.majorVersion > 27 || (os.majorVersion == 27 && os.minorVersion >= 3),
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", xcodes: xcodes, xcodeReady: xcodeReady,
            identities: identities, applicationTeam: team, registered: registered, running: running,
            xcodegen: ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first { files.isExecutableFile(atPath: $0) },
            configuration: .init(developerDirectory: developer?.developerDirectory ?? preferred.developerDirectory,
                teamIdentifier: team ?? preferred.teamIdentifier, signingIdentity: identity?.fingerprint ?? preferred.signingIdentity),
            registeredApplicationPath: installed?.path)
    }

    /// Captures bounded command output privately, honoring cancellation before publishing any discovery result.
    private func output(_ executable: String, _ arguments: [String], in directory: URL, developer: String? = nil) async throws -> (status: Int32, text: String) {
        try Task.checkCancellation()
        let url = directory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var environment = ProcessInfo.processInfo.environment
        if let developer { environment["DEVELOPER_DIR"] = developer }
        let status = try await command.execute(executable: URL(filePath: executable), arguments: arguments,
            directory: directory, environment: environment, log: handle, timeout: 15)
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw MacIntentTestingError("Setup information is too large to inspect. Choose signing settings manually.") }
        return (status, String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    /// Inspects actual Xcode bundle versions and frameworks, deduplicating resolved developer directories.
    static func compatibleXcodes(_ candidates: [String], trusted: @MainActor (URL) -> Bool = { trustedXcode($0) }) -> [SiriStudioXcode] {
        let files = FileManager.default
        return Set(candidates.filter { $0.hasPrefix("/") }.map { URL(filePath: $0).resolvingSymlinksInPath().path })
            .compactMap { path -> SiriStudioXcode? in
                let developer = URL(filePath: path)
                let versionURL = developer.deletingLastPathComponent().appending(path: "version.plist")
                guard files.isExecutableFile(atPath: developer.appending(path: "usr/bin/xcodebuild").path),
                      files.fileExists(atPath: developer.appending(path: "Platforms/MacOSX.platform/Developer/Library/Frameworks/SiriEvaluations.framework").path),
                      let data = try? Data(contentsOf: versionURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let version = plist["CFBundleShortVersionString"] as? String,
                      SiriStudioRunner.supportedXcode("Xcode \(version)"), trusted(developer.appending(path: "usr/bin/xcodebuild")) else { return nil }
                return .init(developerDirectory: path, version: version)
            }.sorted {
                let order = $0.version.compare($1.version, options: .numeric)
                return order == .orderedSame ? $0.developerDirectory < $1.developerDirectory : order == .orderedDescending
            }
    }

    /// Verifies the actual tool is Apple's xcodebuild before automatic discovery can execute it.
    private static func trustedXcode(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"com.apple.dt.xcodebuild\" and anchor apple" as CFString,
                  [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    /// Preserves a compatible explicit choice, then the selected toolchain, before choosing the newest compatible Xcode.
    static func chooseXcode(_ xcodes: [SiriStudioXcode], preferred: String, selected: String) -> SiriStudioXcode? {
        for path in [preferred, selected] where !path.isEmpty {
            let resolved = URL(filePath: path).resolvingSymlinksInPath().path
            if let xcode = xcodes.first(where: { $0.developerDirectory == resolved }) { return xcode }
        }
        return xcodes.first
    }

    /// Filters public certificates through security's valid identity list and reads their team from the subject OU.
    static func developmentIdentities(validOutput: String, pem: String) -> [SiriStudioSigningIdentity] {
        var result: [SiriStudioSigningIdentity] = []
        for chunk in pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            let encoded = chunk.components(separatedBy: "-----END CERTIFICATE-----")[0]
            guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  let certificate = SecCertificateCreateWithData(nil, bytes as CFData),
                  let name = SecCertificateCopySubjectSummary(certificate) as String?, name.hasPrefix("Apple Development:"),
                  let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  let entries = subject[kSecPropertyKeyValue as String] as? [[String: Any]],
                  let team = entries.first(where: { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String) })?[kSecPropertyKeyValue as String] as? String else { continue }
            let fingerprint = Insecure.SHA1.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
            guard validOutput.split(whereSeparator: \.isNewline).contains(where: { line in
                line.split(whereSeparator: \.isWhitespace).contains(Substring(fingerprint))
            }) else { continue }
            result.append(.init(fingerprint: fingerprint, name: name, team: team))
        }
        return result.sorted { $0.fingerprint < $1.fingerprint }
    }

    /// Selects only identities belonging to the app's team, preserving a valid explicit fingerprint or unique name.
    static func chooseIdentity(_ identities: [SiriStudioSigningIdentity], team: String?, preferred: String) -> SiriStudioSigningIdentity? {
        guard let team else { return nil }
        let matching = identities.filter { $0.team == team }
        if let exact = matching.first(where: { $0.fingerprint.caseInsensitiveCompare(preferred) == .orderedSame }) { return exact }
        let named = matching.filter { $0.name == preferred }
        return named.count == 1 ? named[0] : matching.first
    }
}
