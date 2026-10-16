#if os(macOS)
import Foundation

/// Base capabilities shared by the app and command-line runner. Typed conversion
/// support is resolved from the retained build by capabilitiesForExecution.
public enum AutomationPreparedCapabilities {
    public static func base(_ prepared: AutomationPreparedApplication) -> CapabilityProfile {
        var value = AutomationEntityQuery.capabilities(prepared)
        value.records["apple.intent.invoke"] = .init(state: .available,
            reason: "Associated Apple host; registration is checked by invocation",
            probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])
        if prepared.host.target.kind == .physical, prepared.generatedHost.includesSiri == true {
            value.records["siri.recognizedText.api"] = .init(state: .available,
                reason: "Prepared host implements recognised-text submission; outcomes require independent observations",
                probeVersion: "prepared-host-siri-v1", evidence: [prepared.host.xctestrunDigest])
        }
        return value
    }
    public static func resolving(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication) throws -> CapabilityProfile {
        try Task.checkCancellation()
        try AutomationPreparedArtifactIntegrity.verify(prepared)
        var result = capabilities
        for family in AutomationCodecRegistry.parameterFamilies {
            let key = "apple.codec." + family
            guard result.records[key] == nil || result.records[key]?.state == .unknown else { continue }
            result.records[key] = .init(state: .available,
                reason: "Prepared host implements this conversion and its saved files match",
                probeVersion: "prepared-host-codecs-v1",
                evidence: [prepared.generatedHost.templateDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest])
        }
        if result.records["siri.actualRoute"]?.state == .available {
            result.records["siri.actualRoute"] = .init(state: .unknown,
                reason: "Siri routing is assessed from each run's independent app observations",
                probeVersion: "observed-siri-outcomes-v1", evidence: [])
        }
        let siri = "siri.recognizedText.api"
        if let record = base(prepared).records[siri], result.records[siri] == nil || result.records[siri]?.state == .unknown {
            result.records[siri] = record
        }
        return result
    }
}
#endif
