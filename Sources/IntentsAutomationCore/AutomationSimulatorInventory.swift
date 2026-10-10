#if os(macOS)
import Foundation

public struct AutomationSimulator: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var runtime: String
    public var state: String
}
public enum AutomationSimulatorInventory {
    public static func read(developerDirectory: URL, workspace: URL) async throws -> [AutomationSimulator] {
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "available", "--json"], directory: workspace,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": try AutomationPath.canonical(developerDirectory).path,
                          "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: .seconds(15))
        guard result.exitStatus == 0, !result.logsTruncated,
              let root = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { throw AutomationContractError.missingEvidence("Simulator inventory is unavailable") }
        var output: [AutomationSimulator] = []
        for (runtime, values) in devices where runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-27-") {
            for value in values {
                guard value["isAvailable"] as? Bool == true, let id = value["udid"] as? String,
                      id.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil,
                      let name = value["name"] as? String, let state = value["state"] as? String else { throw AutomationContractError.invalidIdentity }
                output.append(.init(id: id, name: name, runtime: runtime, state: state))
            }
        }
        return output.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}
#endif
