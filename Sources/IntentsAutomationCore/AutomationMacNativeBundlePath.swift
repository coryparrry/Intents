#if os(macOS)
import Foundation

/// Foundation's preferred spelling can differ from POSIX realpath (for example /tmp).
/// The helper ABI uses Foundation; approvals and retained identities use POSIX.
struct AutomationMacNativeBundlePath: Sendable {
    let canonical: URL
    let helper: URL
    init(canonical: URL, helper: URL? = nil) throws {
        guard try AutomationPath.canonical(canonical).path == canonical.path else { throw AutomationContractError.invalidIdentity }
        let preferred = helper ?? canonical.standardizedFileURL.resolvingSymlinksInPath()
        guard try AutomationPath.canonical(preferred).path == canonical.path else { throw AutomationContractError.invalidIdentity }
        self.canonical = canonical; self.helper = preferred
    }
    func forHelper(_ identity: AutomationJSON) throws -> AutomationJSON {
        try replace(identity, from: canonical.path, to: helper.path)
    }
    func forOwner(_ identity: AutomationJSON) throws -> AutomationJSON {
        try replace(identity, from: helper.path, to: canonical.path)
    }
    private func replace(_ identity: AutomationJSON, from: String, to: String) throws -> AutomationJSON {
        guard try AutomationPath.canonical(helper).path == canonical.path,
              var fields = identity.object, fields["canonicalBundlePath"] == .string(from) else {
            throw AutomationContractError.invalidIdentity
        }
        fields["canonicalBundlePath"] = .string(to)
        return .object(fields)
    }
}
#endif
