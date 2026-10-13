#if os(macOS)
import Foundation

/// The generated host implements these conversions. Optional live canaries diagnose
/// conversion behavior; an environment fingerprint never controls whether a plan may run.
enum AutomationSimulatorCodecQualification {
    static func enrich(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication) async throws -> CapabilityProfile {
        try Task.checkCancellation()
        try AutomationPreparedCodecAuthority.verify(prepared)
        var result = capabilities
        for family in AutomationCodecRegistry.parameterFamilies {
            let key = "apple.codec." + family
            // Preserve a caller's explicit veto and consent requirement.
            guard result.records[key] == nil || result.records[key]?.state == .unknown else { continue }
            result.records[key] = .init(state: .available,
                reason: "Prepared host implements this conversion and its saved files match",
                probeVersion: "prepared-host-codecs-v1",
                evidence: [prepared.generatedHost.templateDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest])
        }
        try Task.checkCancellation()
        return result
    }
}
#endif
