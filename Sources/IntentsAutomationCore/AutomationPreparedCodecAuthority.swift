#if os(macOS)
import Foundation

/// Generated-host source and product validation survives relaunch. Explicit
/// native/physical qualifications also retain separate process-local evidence.
public enum AutomationPreparedCodecAuthority {
    static let shared = AutomationPreparedCodecRegistry()

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

actor AutomationPreparedCodecRegistry {
    private var preparations: [AutomationPreparedApplication] = []
    func register(_ prepared: AutomationPreparedApplication) {
        preparations.append(prepared)
        if preparations.count > 32 { preparations.removeFirst() }
    }
    func contains(_ prepared: AutomationPreparedApplication) -> Bool {
        preparations.contains(prepared)
    }
}
#endif
