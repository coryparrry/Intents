#if os(macOS)
import Foundation

/// Device discovery needs a working directory before source capture owns its
/// destination. Keep that temporary work beside the still-absent destination.
enum AutomationPreparationTargetResolution {
    static func resolve(_ target: TargetIdentity, sessionRoot: URL, developerDirectory: URL,
        inventory: @Sendable (TargetIdentity, URL, URL) async throws -> TargetIdentity = {
            try await AutomationPhysicalDeviceInventory.canonicalTarget($0, developerDirectory: $1, workspace: $2)
        }) async throws -> TargetIdentity {
        let parent = sessionRoot.deletingLastPathComponent()
        guard target.kind == .physical, try AutomationPath.canonical(parent).path == parent.path,
              !FileManager.default.fileExists(atPath: sessionRoot.path) else { throw AutomationContractError.invalidIdentity }
        let workspace = parent.appendingPathComponent("device-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        guard try AutomationPath.canonical(workspace).path == workspace.path else { throw AutomationContractError.invalidIdentity }
        let resolved = try await inventory(target, developerDirectory, workspace)
        try Task.checkCancellation()
        return resolved
    }
}
#endif
