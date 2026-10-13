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
        return value
    }
}
#endif
