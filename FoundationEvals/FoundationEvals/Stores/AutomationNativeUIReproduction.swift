#if os(macOS)
import Foundation
import IntentsAutomationCore

enum AutomationNativeCommandKind: String, Codable, Sendable { case reproduction, fixComparison }
struct AutomationNativeReproductionPreview: Codable, Sendable {
    var digest: String
    var bundleID: String
    var targetID: String
    var environmentID: String
    var caseID: String
    var revision: Int
    var caseDigest: String
    var originalAttemptID: String
    var requestedAttempts: Int
    var installApproved: Bool
    var disposable: Bool
}
struct AutomationNativeReproductionOutcome: Codable, Sendable {
    struct Attempt: Codable, Sendable {
        var attemptID: String
        var result: AttemptResult
        var resourcesReleased: Bool
    }
    var requestedAttempts: Int
    var complete: Bool
    var reproduced: Bool
    var matchingFailures: Int
    var assessedPasses: Int
    var otherFailures: Int
    var unassessed: Int
    var signature: [String]
    var attempts: [Attempt]
    var interruption: AutomationSearchInterruption?
    var stopReason: String?
    var resourcesReleased: Bool { attempts.allSatisfy(\.resourcesReleased) && interruption?.dispatchMayHaveOccurred != true }
    init(_ report: AutomationReproductionReport) throws {
        try report.validate()
        requestedAttempts = report.requestedAttempts; complete = report.complete; reproduced = report.reproduced
        matchingFailures = report.matchingFailures; assessedPasses = report.assessedPasses
        otherFailures = report.otherFailures; unassessed = report.unassessed; signature = report.signature
        attempts = report.attempts.map { .init(attemptID: $0.attemptID, result: $0.result, resourcesReleased: $0.resourcesReleased) }
        interruption = report.interruption; stopReason = report.stopReason
    }
}
struct AutomationNativeReproductionRequest: Sendable {
    var proposal: AutomationNativeUIReproductionProposal
    var subject: AutomationApplicationSubject
    var runtime: AutomationUIRuntime?
    var installApproved: Bool
    var digest: String
}

struct AutomationNativeUIReproductionProposal: Sendable {
    let frozen: AutomationFrozenCase
    let originalAttemptID: String
    let approval: RunApproval
    var capabilities = CapabilityProfile()
    var usesFreshFixture: Bool { (try? AutomationFreshEntityPlanner.bindings(plan: frozen.plan)) != nil }
    var limits: AutomationCampaignLimits {
        var value = AutomationCampaignLimits.firstCampaign
        value.attempts = 5; value.subjectOperations = 5
        value.uiActions = 150; value.controllerCalls = 60; value.wallClockSeconds = 900
        return value
    }
    static func compile(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                        subject: AutomationApplicationSubject, runtime: AutomationNativeUIRuntime,
                        runID: String, disposable: Bool) throws -> Self {
        try frozen.validate()
        try AutomationRecordedEvidence.validate(report: original, plan: frozen.plan)
        let plan = frozen.plan
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        let freshBindings = try? AutomationFreshEntityPlanner.bindings(plan: plan)
        let capabilities: CapabilityProfile
        if freshBindings != nil, case .prepared(let prepared) = subject { capabilities = AutomationNativeFreshFixtures.capabilities(prepared) }
        else { capabilities = .init() }
        let permitted = freshBindings != nil && disposable && segments.allSatisfy {
            [.ui, .systemIntent, .systemQuery].contains($0.kind) && $0.effects.isSubset(of: [.observe, .navigate, .fixtureWrite])
        }
        guard plan.app == subject.app, plan.target == subject.target,
              plan.environmentID == "selected-simulator:" + subject.target.id,
              plan.provenance["ui.runtimeManifestDigest"] == runtime.manifestDigest,
              plan.provenance["ui.runtimeTeamID"] == runtime.runtime.expectedTeamID,
              plan.provenance["ui.locale"] == Locale.current.identifier,
              (permitted || segments.allSatisfy({ $0.kind == .ui && $0.uiProgram != nil && $0.effects.isSubset(of: [.observe, .navigate]) })),
              original.result.summary == .assertionFailed, original.result.assessed, original.result.evidenceComplete,
              original.resourcesReleased, !original.result.subjectDispatchUncertain else {
            throw AutomationContractError.missingEvidence("Select the same app and simulator as an assessed, released UI failure; its prepared host, runtime and locale must still match")
        }
        if case .prepared(let prepared) = subject {
            let fields = try AutomationNativeUIRuntime.preparedProvenance(prepared)
            guard fields.allSatisfy({ plan.provenance[$0.key] == $0.value }) else { throw AutomationContractError.conflictingOperation }
        }
        let approval = RunApproval(runID: runID, app: subject.app, target: subject.target,
            environmentID: plan.environmentID, effects: freshBindings == nil ? [.observe, .navigate] : [.observe, .navigate, .fixtureWrite], maximumActions: 30,
            disposable: disposable, approvedCaseDigest: frozen.digest)
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review)
        if let freshBindings { try AutomationQualifiedFreshFixture.validateProposal(bindings: freshBindings, plan: plan, approval: approval, capabilities: capabilities, purpose: .review) }
        return .init(frozen: frozen, originalAttemptID: original.attemptID, approval: approval, capabilities: capabilities)
    }
    static func compileMac(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                           selected: AutomationInstalledMacUIApplication, runtimeRoot: URL, runID: String) throws -> Self {
        fromMacReview(try AutomationMacSavedWorkflowContract.reproduction(frozen: frozen, original: original,
            selected: selected, runtimeRoot: runtimeRoot, runID: runID))
    }
    static func fromMacReview(_ review: AutomationMacSavedWorkflowContract.Reproduction) -> Self {
        .init(frozen: review.frozen, originalAttemptID: review.originalAttemptID, approval: review.approval, capabilities: review.capabilities)
    }
    static func compilePreparedMac(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                   prepared: AutomationPreparedApplication, runtimeRoot: URL, runID: String, disposable: Bool) throws -> Self {
        fromMacReview(try AutomationMacSavedWorkflowContract.reproduction(frozen: frozen, original: original,
            prepared: prepared, runtimeRoot: runtimeRoot, runID: runID, disposable: disposable))
    }
    func execute(subject: AutomationApplicationSubject, runtime: AutomationUIRuntime?,
                 support: URL, developerDirectory: URL, allowBootAndInstall: Bool) async throws -> AutomationReproductionReport {
        if case .installedMacUI = subject {
            guard runtime == nil, !allowBootAndInstall else { throw AutomationContractError.conflictingOperation }
        }
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: support,
            developerDirectory: developerDirectory)
        var verified = self
        verified.capabilities = try await runner.capabilitiesForExecution(subject: subject, plan: frozen.plan,
            capabilities: capabilities)
        var fixture: AutomationQualifiedFreshFixture?
        if usesFreshFixture {
            guard let runtime, case .prepared(let prepared) = subject else { throw AutomationContractError.invalidIdentity }
            fixture = try await AutomationNativeFreshFixtures.qualify(frozen: frozen, prepared: prepared, approval: approval, capabilities: verified.capabilities, runner: runner, runtime: runtime, installApproved: allowBootAndInstall)
        }
        guard subject.target.kind == .nativeMac || runtime != nil else {
            throw AutomationContractError.missingEvidence("Saved simulator campaigns require the reviewed UI runtime")
        }
        guard subject.target.kind != .physical else {
            throw AutomationContractError.missingEvidence("Physical installed-app execution is not qualified")
        }
        let executor = AutomationSubjectCampaignExecutor(runner: runner, subject: subject, capabilities: verified.capabilities,
            allowBootAndInstall: allowBootAndInstall, uiRuntime: runtime)
        return try await verified.runCampaign(cases: cases, executor: executor, fixture: fixture)
    }
    func runCampaign(cases: AutomationCaseStore, executor: any AutomationCampaignAttemptExecutor,
                     fixture: AutomationQualifiedFreshFixture?) async throws -> AutomationReproductionReport {
        try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: originalAttemptID,
            approval: approval, capabilities: capabilities, limits: limits, executor: executor, fixture: fixture)
    }

}
typealias AutomationNativeReproductionExecutor = @Sendable (AutomationNativeUIReproductionProposal, AutomationApplicationSubject, AutomationUIRuntime?, URL, Bool) async throws -> AutomationReproductionReport
#endif
