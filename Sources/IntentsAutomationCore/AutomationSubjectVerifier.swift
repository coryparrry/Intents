import Foundation

public protocol AutomationSubjectVerifier: Sendable {
    func verify(app: AppIdentity, target: TargetIdentity) async throws
}

#if os(macOS)
/// Uses actual installed simulator bytes for strong identity; physical unreadable builds stay weak.
public struct AutomationInstalledSubjectVerifier: AutomationSubjectVerifier {
    public var developerDirectory: URL
    public var workspace: URL
    public init(developerDirectory: URL, workspace: URL) {
        self.developerDirectory = developerDirectory; self.workspace = workspace
    }
    public func verify(app: AppIdentity, target: TargetIdentity) async throws {
        guard !app.bundleID.isEmpty, app.platform == (target.kind == .nativeMac ? "macos" : "ios") else { throw AutomationContractError.invalidIdentity }
        // Exact backend/app selection still runs on every capture. Unknown bytes cannot claim a build digest.
        guard let expectedDigest = app.productDigest else {
            guard target.kind != .physical else { throw AutomationContractError.missingEvidence("Physical apps require positive installed-bundle presence evidence") }
            return
        }
        let bundle: URL
        if target.kind == .nativeMac {
            guard let path = app.canonicalBundlePath else { throw AutomationContractError.invalidIdentity }
            bundle = URL(fileURLWithPath: path)
        } else {
            guard target.kind == .simulator, target.id.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil,
                  app.bundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil else {
                throw AutomationContractError.missingEvidence("Installed product bytes unavailable for this target")
            }
            let developer = try AutomationPath.canonical(developerDirectory)
            let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "get_app_container", target.id, app.bundleID, "app"], directory: workspace,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path, "HOME": workspace.path, "TMPDIR": workspace.path], timeout: .seconds(15))
            guard result.exitStatus == 0, !result.logsTruncated, result.stdout.count <= 4096,
                  let path = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  path.hasPrefix("/"), !path.contains("\n") else { throw AutomationContractError.missingEvidence("Installed product identity unavailable") }
            bundle = URL(fileURLWithPath: path)
        }
        let root = try AutomationPath.canonical(bundle)
        let infoPath = target.kind == .nativeMac ? "Contents/Info.plist" : "Info.plist"
        guard try AutomationProductDigest.compute(bundle: root, version: app.productDigestVersion) == expectedDigest,
              let values = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: root, relativePath: infoPath, maximumBytes: 1_048_576, version: app.productDigestVersion, expectedDigest: app.productDigest), format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == app.bundleID,
              !expectedDigest.isEmpty else { throw AutomationContractError.conflictingOperation }
    }
}
#endif
