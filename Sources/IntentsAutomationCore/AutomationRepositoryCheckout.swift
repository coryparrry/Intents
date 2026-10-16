#if os(macOS)
import Foundation

/// Fetching source does not run its build, hooks, submodules, or credential helpers.
public enum AutomationRepositoryCheckout {
    public struct Result: Codable, Sendable {
        public let address: String
        public let directory: URL
        public let revision: String
    }
    public static func validatedURL(_ address: String) throws -> URL {
        guard address.utf8.count <= 4096, let url = URL(string: address),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.isEmpty, components.path != "/",
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AutomationContractError.invalidPlan("Enter an HTTPS repository URL without credentials, query parameters or fragments. For private repositories, choose an existing authorised checkout.")
        }
        return url
    }
    static func arguments(url: URL, destination: URL) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
         "-c", "submodule.recurse=false", "clone", "--no-local", "--depth", "1", "--single-branch", "--no-tags", "--", url.absoluteString, destination.path]
    }
    public static func fetch(_ address: String, supportRoot: URL) async throws -> Result {
        let url = try validatedURL(address)
        let root = supportRoot.appendingPathComponent("ImportedSources").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        let repository = root.appendingPathComponent("repository"), command = AutomationOwnedCommand()
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "XDG_CONFIG_HOME": root.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
            "GIT_LFS_SKIP_SMUDGE": "1", "TMPDIR": root.path]
        let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments(url: url, destination: repository),
            directory: root, environment: environment, timeout: .seconds(120))
        try AutomationDurableFile(url: root.appendingPathComponent("fetch.log"), maximumBytes: 2_097_152).write(result.stderr + result.stdout)
        guard result.exitStatus == 0, !result.logsTruncated else {
            throw AutomationContractError.missingEvidence("The repository could not be fetched. Check the URL and network, or choose an existing authorised checkout. Fetch details are retained in " + root.path)
        }
        try Task.checkCancellation()
        let revisionResult = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["rev-parse", "--verify", "HEAD"],
            directory: repository, environment: environment, timeout: .seconds(10))
        let revision = String(decoding: revisionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard revisionResult.exitStatus == 0, !revisionResult.logsTruncated,
              revision.range(of: #"^[a-f0-9]{40}([a-f0-9]{24})?$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        let checkout = Result(address: url.absoluteString, directory: repository, revision: revision)
        try AutomationDurableFile(url: root.appendingPathComponent("checkout.json"), maximumBytes: 16_384).write(JSONEncoder().encode(checkout))
        return checkout
    }
}
#endif
