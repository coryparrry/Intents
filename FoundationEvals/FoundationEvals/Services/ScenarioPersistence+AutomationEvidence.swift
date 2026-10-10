import Foundation
import IntentsAutomationCore

extension ScenarioPersistence {
    /// Additive version-three native evidence. Legacy XCTest import and acceptance stay unchanged.
    func importAutomationEvidence(plan: AutomationCase, report: AutomationAttemptReport, sourceRoot: URL, exposure: AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument {
        let cases = try AutomationCaseStore(readOnlyRoot: sourceRoot.appendingPathComponent("Cases"))
        let frozen = try await cases.load(id: plan.id, revision: plan.revision, digest: AutomationFrozenCase.planDigest(plan))
        guard frozen.plan == plan else { throw AutomationContractError.conflictingOperation }
        let archive = try AutomationNativeEvidenceArchive(root: rootDirectory.appendingPathComponent("Runs/AppAutomation"))
        return try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: sourceRoot, exposure: exposure)
    }
    func loadAutomationEvidence(authority: AutomationEvidenceExposureAuthority) async throws -> AutomationNativeEvidenceSnapshot? {
        let directory = rootDirectory.appendingPathComponent("Runs/AppAutomation")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return try await AutomationNativeEvidenceArchive(root: directory).snapshot(authority: authority)
    }
}
