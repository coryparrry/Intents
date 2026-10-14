#if os(macOS)
import Foundation

/// Validate the exact prepared files before the optional input diagnostic.
enum AutomationMacAppleRuntimeSnapshot {
    static func validatePreparedArtifacts(_ host: AutomationPreparedAppleHost) throws {
        let subject = URL(fileURLWithPath: host.subjectProductPath), test = URL(fileURLWithPath: host.xctestrunPath)
        guard try AutomationPath.canonical(subject) == subject,
              try AutomationProductDigest.compute(bundle: subject, version: 2) == host.app.productDigest,
              try AutomationPath.canonical(test) == test,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(test, maximumBytes: 4_194_304)) == host.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
        _ = try AutomationMacAssociatedHostReleaseVerifier.profile(host)
    }
}
#endif
