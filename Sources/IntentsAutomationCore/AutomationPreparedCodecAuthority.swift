#if os(macOS)
import Foundation

/// Process-local preparation evidence. Serialized build metadata cannot grant
/// adapter admission in a new process; saved workflows must prepare again.
actor AutomationPreparedCodecAuthority {
    static let shared = AutomationPreparedCodecAuthority()
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
