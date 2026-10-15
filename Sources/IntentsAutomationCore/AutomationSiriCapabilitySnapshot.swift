#if os(macOS)
import Foundation

/// Compilation establishes the submission API only, never Siri routing or business outcomes.
public enum AutomationSiriCapabilitySnapshot {
    public static func resolve(prepared: AutomationPreparedApplication, capabilities: CapabilityProfile = .init(),
                               plan: AutomationCase? = nil, approval: RunApproval? = nil, authority: AutomationSiriRouteAuthority? = nil) async throws -> CapabilityProfile {
        var result = capabilities
        let key = "siri.recognizedText.api"
        if result.records[key]?.state == .available {
            result.records[key] = .init(state: .unknown, reason: "Cached API compilation evidence requires matching prepared files", probeVersion: "siri-api-compilation-v1", evidence: [])
        }
        if result.records["siri.actualRoute"]?.state == .available {
            result.records["siri.actualRoute"] = .init(state: .unknown, reason: "Cached routing availability has no exact live qualification authority", probeVersion: "siri-route-v1", evidence: [])
        }
        guard prepared.host.target.kind == .physical, prepared.generatedHost.includesSiri == true else { return result }
        try Task.checkCancellation()
        try AutomationPreparedCodecAuthority.verify(prepared)
        if result.records[key] == nil || result.records[key]?.state == .unknown {
            result.records[key] = .init(state: .available, reason: "This exact physical host compiled against XCTest's recognised-text submission API. Device submission and Siri routing are unverified.",
                probeVersion: "siri-api-compilation-v1", evidence: [prepared.generatedHost.templateDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest])
        }
        if result.records["siri.actualRoute"] == nil {
            result.records["siri.actualRoute"] = .init(state: .unknown, reason: "No live independent Siri routing or app-outcome evidence", probeVersion: "siri-route-v1", evidence: [])
        }
        if let plan {
            result = await AutomationPhysicalInputAdapterAuthority.shared.applying(prepared: prepared, plan: plan, capabilities: result)
        }
        if let plan, let approval, let authority, !authority.isQualification,
           result.records["siri.actualRoute"]?.state == .unknown,
           let evidence = authority.evidenceDigest {
            try authority.validate(plan: plan, approval: approval)
            result.records["siri.actualRoute"] = .init(state: .available,
                reason: authority.isRepeatableQualification ? "Live exact recognised-text submission channel, verified restoration, same-record observation and release qualified this frozen phrase; business correctness and intended app/action invocation are assessed separately." : "Live Siri submission, independent record-state transition and release qualified only this frozen workflow; remote installed bytes remain unverified.",
                probeVersion: "siri-exact-case-v1", evidence: [evidence, prepared.host.xctestrunDigest])
        }
        return result
    }
}
#endif
