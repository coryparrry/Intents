import Foundation
import IntentsAutomationCore

/// One window's exact preview and review decision, copied unchanged into its save operation.
struct AutomationCapsuleExportSelection: Identifiable, Sendable {
    let id = UUID()
    let frozen: AutomationFrozenCase
    let attempts: [AutomationAttemptReport]
    let exposure: AutomationEvidenceExposure
    var reviewed = false
    var approval: AutomationCapsuleExportApproval {
        .init(caseDigest: frozen.digest, attemptIDs: Set(attempts.map(\.attemptID)), syntheticDataAndMetadataReviewed: reviewed)
    }
}
