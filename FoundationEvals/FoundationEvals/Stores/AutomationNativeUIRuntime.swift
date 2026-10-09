#if os(macOS)
import Foundation
import Security
import IntentsAutomationCore

struct AutomationNativeUIRuntime: Sendable {
    let runtime: AutomationUIRuntime
    let manifestDigest: String
    static func attachPreparedEvidence(to plan: inout AutomationCase, prepared: AutomationPreparedApplication) throws {
        if prepared.host.target.kind == .nativeMac {
            plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        } else { plan.provenance.merge(try preparedProvenance(prepared)) { _, value in value } }
    }
    static func preparedEvidenceMatches(plan: AutomationCase, prepared: AutomationPreparedApplication) -> Bool {
        guard plan.app == prepared.host.app else { return false }
        if let artifacts = plan.preparedMacBuildArtifacts { return artifacts == (try? .init(prepared: prepared)) }
        return (try? preparedProvenance(prepared))?.allSatisfy { plan.provenance[$0.key] == $0.value } == true
    }
    static func preparedProvenance(_ prepared: AutomationPreparedApplication) throws -> [String: String] {
        ["ui.preparedHostDigest": prepared.host.hostProductDigest,
         "ui.preparedXctestrunDigest": prepared.host.xctestrunDigest,
         "ui.preparedCatalogDigest": try AutomationRecipeContext.catalogDigest(prepared.catalog),
         "ui.hostTemplateDigest": prepared.generatedHost.templateDigest]
    }
    static func bundled(stateDirectory: URL) throws -> Self {
        let bundle = Bundle.main.bundleURL
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any], let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.missingEvidence("This app build has no signed UI runtime")
        }
        let digest = try AutomationRuntimeBundle.verifiedManifestDigest(bundleURL: bundle, stateDirectory: stateDirectory, expectedTeamID: team)
        return .init(runtime: .init(bundleURL: bundle, expectedTeamID: team), manifestDigest: digest)
    }
}

#endif
