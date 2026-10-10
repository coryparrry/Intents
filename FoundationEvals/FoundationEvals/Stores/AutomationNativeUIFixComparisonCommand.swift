#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeFixComparisonPreview: Codable, Sendable {
    var digest: String
    var bundleID: String
    var targetID: String
    var environmentID: String
    var caseID: String
    var revision: Int
    var caseDigest: String
    var candidateCaseDigest: String
    var beforeProductDigest: String
    var afterProductDigest: String
    var originalAttemptID: String
    var requestedAttemptsPerBuild: Int
    var installApproved: Bool
    var disposable: Bool
}
struct AutomationNativeFixComparisonOutcome: Codable, Sendable {
    typealias Attempt = AutomationNativeReproductionOutcome.Attempt
    var requestedAttemptsPerBuild: Int
    var complete: Bool
    var contractDigest: String
    var oracleDigest: String
    var candidateCaseDigest: String
    var beforeProductDigest: String
    var afterProductDigest: String
    var before: [Attempt]
    var after: [Attempt]
    var beforeCounters: ScopeCounters
    var afterCounters: ScopeCounters
    var interruption: AutomationSearchInterruption?
    var stopReason: String?
    var environmentQualificationComplete: Bool
    var resourcesReleased: Bool { (before + after).allSatisfy(\.resourcesReleased) && interruption?.dispatchMayHaveOccurred != true }
    init(_ report: AutomationFixComparisonReport, originalAttemptID: String) throws {
        try report.validate()
        guard !(report.before + report.after).contains(where: { $0.attemptID == originalAttemptID }),
              report.interruption?.attemptID != originalAttemptID,
              let beforeDigest = report.baseline.plan.app.productDigest, let afterDigest = report.candidate.plan.app.productDigest else {
            throw AutomationContractError.conflictingOperation
        }
        requestedAttemptsPerBuild = report.requestedAttemptsPerBuild; complete = report.complete
        contractDigest = report.contractDigest; oracleDigest = report.baseline.oracleDigest; candidateCaseDigest = report.candidate.digest
        beforeProductDigest = beforeDigest; afterProductDigest = afterDigest
        before = report.before.map { .init(attemptID: $0.attemptID, result: $0.result, resourcesReleased: $0.resourcesReleased) }
        after = report.after.map { .init(attemptID: $0.attemptID, result: $0.result, resourcesReleased: $0.resourcesReleased) }
        beforeCounters = report.beforeCounters; afterCounters = report.afterCounters
        interruption = report.interruption; stopReason = report.stopReason; environmentQualificationComplete = report.environmentQualificationComplete
    }
}
struct AutomationNativeFixComparisonRequest: Sendable {
    var proposal: AutomationNativeUIFixComparisonProposal
    var before: AutomationApplicationSubject
    var after: AutomationApplicationSubject
    var runtime: AutomationUIRuntime?
    var digest: String
    var originalAttemptID: String
}
#endif
