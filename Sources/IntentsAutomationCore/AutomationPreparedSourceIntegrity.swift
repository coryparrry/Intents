import Foundation

/// Checks the captured bytes used by source discovery around an authorized build.
/// This is a current-byte check, not a receipt of bytes read by the compiler.
enum AutomationPreparedSourceIntegrity {
    static func verify(graph: AutomationSourceGraph, manifest: AutomationSourceManifest, frozenRoot: URL) throws {
        try manifest.validateCaptureLayout()
        guard graph.sourceManifestDigest == (try manifest.digest), graph.inputs.count <= 10_000, manifest.files.count <= 100_000 else {
            throw AutomationContractError.conflictingOperation
        }
        let captured = Dictionary(grouping: manifest.files, by: \.relativePath)
        guard graph.synchronizedMembershipVersion == nil || graph.synchronizedMembershipVersion == 1,
              graph.synchronizedMembershipVersion == 1 || !graph.inputs.contains(where: { $0.role == "synchronizedSwiftMembership" }) else { throw AutomationContractError.conflictingOperation }
        let roles: Set<String> = ["explicitSwiftMembership", "packageSwiftMembership", "synchronizedSwiftMembership", "inactiveSwiftMembership",
                                  "unresolvedSwiftMembership", "packageManifest", "buildConfiguration"]
        var verified: Set<String> = []
        var totalBytes = 0
        for input in graph.inputs where roles.contains(input.role) {
            try Task.checkCancellation()
            guard let matches = captured[input.relativePath], matches.count == 1, let file = matches.first,
                  file.symbolicLink == nil, file.sha256 == input.sha256, file.bytes >= 0, file.bytes <= 16 * 1024 * 1024 else {
                throw AutomationContractError.conflictingOperation
            }
            if !verified.insert(input.relativePath).inserted { continue }
            totalBytes += file.bytes
            guard totalBytes <= 64 * 1024 * 1024 else { throw AutomationContractError.conflictingOperation }
            let data = try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: input.relativePath, maximumBytes: 16 * 1024 * 1024)
            guard data.count == file.bytes, AutomationArtifactRegistry.digest(data) == file.sha256 else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
}
