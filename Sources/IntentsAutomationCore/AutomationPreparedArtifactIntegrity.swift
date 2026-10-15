#if os(macOS)
import Foundation

/// Verifies the actual retained source, products and test configuration on every use.
public enum AutomationPreparedArtifactIntegrity {

    public static func verify(_ prepared: AutomationPreparedApplication) throws {
        try AutomationHostGenerator.verifyGeneratedSources(prepared.generatedHost,
            sessionRoot: URL(fileURLWithPath: prepared.buildLogPath).deletingLastPathComponent())
        guard let subjectDigest = prepared.host.app.productDigest,
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.subjectProductPath),
                  version: prepared.host.app.productDigestVersion) == subjectDigest,
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.hostBundlePath),
                  version: prepared.host.hostProductDigestVersion) == prepared.host.hostProductDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: prepared.host.xctestrunPath),
                  maximumBytes: 4_194_304)) == prepared.host.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }
}

#endif
