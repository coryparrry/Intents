#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeUIFixComparisonProposal: Sendable {
    let baseline: AutomationFrozenCase
    let candidate: AutomationFrozenCase
    let beforeApproval: RunApproval
    let afterApproval: RunApproval
    var beforeCapabilities = CapabilityProfile()
    var afterCapabilities = CapabilityProfile()
    var attemptsPerBuild = 3
    var limits: AutomationCampaignLimits {
        var value = AutomationCampaignLimits()
        value.attempts = attemptsPerBuild; value.subjectOperations = attemptsPerBuild
        value.uiActions = 30 * attemptsPerBuild; value.controllerCalls = 0; value.wallClockSeconds = 180 * attemptsPerBuild
        value.subjectOperations = value.uiActions
        return value
    }
    static func compile(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                        before: AutomationApplicationSubject, after: AutomationApplicationSubject,
                        runID: String, disposable: Bool) throws -> Self {
        let reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: frozen, original: original,
            subject: before, runID: runID + ".before", disposable: disposable)
        guard before.app.productDigest != nil, before.target == after.target else { throw AutomationContractError.conflictingOperation }
        var baseline = frozen
        switch (before, after) {
        case (.installedUI, .installedUI):
            guard frozen.plan.provenance["ui.preparedHostDigest"] == nil,
                  frozen.plan.preparedSimulatorBuildArtifacts == nil, frozen.plan.preparedMacBuildArtifacts == nil else { throw AutomationContractError.conflictingOperation }
        case (.prepared(let retained), .prepared(let candidate)):
            try validatePreparedCandidate(before: retained, after: candidate)
            if frozen.plan.preparedSimulatorBuildArtifacts == nil, retained.host.target.kind == .simulator {
                // Admission above uses the unchanged legacy case and its original exact failure.
                // The new comparison runs both populations afresh under this linked definition.
                var plan = frozen.plan
                plan.id = "comparison." + frozen.digest; plan.revision = 1
                plan.provenance["comparison.sourceCaseDigest"] = frozen.digest
                try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: retained)
                baseline = try AutomationFrozenCase(plan: plan)
            }
        default: throw AutomationContractError.invalidPlan("Compare two installed builds or two prepared source builds")
        }
        let candidate: AutomationFrozenCase
        if case .prepared(let prepared) = after {
            candidate = try AutomationFixContract.candidate(from: baseline, prepared: prepared)
        } else { candidate = try AutomationFixContract.candidate(from: baseline, app: after.app) }
        let afterCapabilities: CapabilityProfile
        if case .prepared(let prepared) = after { afterCapabilities = AutomationPreparedCapabilities.base(prepared) }
        else { afterCapabilities = .init() }
        let beforeApproval = RunApproval(runID: runID + ".before", app: before.app, target: before.target,
            environmentID: baseline.plan.environmentID, effects: reproduction.approval.effects, maximumActions: 30,
            disposable: disposable, approvedCaseDigest: baseline.digest)
        let afterApproval = RunApproval(runID: runID + ".after", app: after.app, target: after.target,
            environmentID: candidate.plan.environmentID, effects: reproduction.approval.effects, maximumActions: 30,
            disposable: disposable, approvedCaseDigest: candidate.digest)
        try PlanValidator.validate(baseline.plan, approval: beforeApproval, capabilities: reproduction.capabilities, purpose: .review)
        try PlanValidator.validate(candidate.plan, approval: afterApproval, capabilities: afterCapabilities, purpose: .review)
        return .init(baseline: baseline, candidate: candidate, beforeApproval: beforeApproval, afterApproval: afterApproval, beforeCapabilities: reproduction.capabilities, afterCapabilities: afterCapabilities)
    }
    @concurrent func execute(before: AutomationApplicationSubject, after: AutomationApplicationSubject,
                 support: URL, developerDirectory: URL,
                 onProgress: AutomationFixComparisonProgressHandler? = nil) async throws -> AutomationFixComparisonReport {
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: support,
            developerDirectory: developerDirectory)
        var verified = self
        verified.beforeCapabilities = try await runner.capabilitiesForExecution(subject: before, plan: baseline.plan,
            capabilities: beforeCapabilities, approval: beforeApproval)
        verified.afterCapabilities = try await runner.capabilitiesForExecution(subject: after, plan: candidate.plan,
            capabilities: afterCapabilities, approval: afterApproval)
        return try await verified.runCampaign(cases: cases,
            beforeExecutor: Self.executor(subject: before, runner: runner, capabilities: verified.beforeCapabilities),
            afterExecutor: Self.executor(subject: after, runner: runner, capabilities: verified.afterCapabilities),
            onProgress: onProgress)
    }
    func runCampaign(cases: AutomationCaseStore, beforeExecutor: any AutomationCampaignAttemptExecutor,
                     afterExecutor: any AutomationCampaignAttemptExecutor,
                     onProgress: AutomationFixComparisonProgressHandler? = nil) async throws -> AutomationFixComparisonReport {
        try await AutomationFixComparison(cases: cases).run(baseline: baseline, candidate: candidate,
            attemptsPerBuild: attemptsPerBuild, beforeApproval: beforeApproval, afterApproval: afterApproval,
            beforeCapabilities: beforeCapabilities, afterCapabilities: afterCapabilities, limits: limits,
            beforeExecutor: beforeExecutor, afterExecutor: afterExecutor, onProgress: onProgress)
    }
    static func validatePreparedCandidate(before: AutomationPreparedApplication, after: AutomationPreparedApplication) throws {
        let a = before.host.app, b = after.host.app
        guard a.logicalID == b.logicalID, a.bundleID == b.bundleID, a.platform == b.platform,
              a.architecture == b.architecture, a.configuration == b.configuration, a.owningModule == b.owningModule,
              a.productDigest != nil, b.productDigest != nil, a.productDigest != b.productDigest,
              a.sourceManifestDigest == (try before.source.digest), b.sourceManifestDigest == (try after.source.digest),
              a.sourceManifestDigest != b.sourceManifestDigest, before.source.sourceRoot == after.source.sourceRoot,
              before.catalog.app == a, after.catalog.app == b, before.host.target == after.host.target,
              before.generatedHost.configuration == a.configuration, after.generatedHost.configuration == b.configuration,
              before.generatedHost.templateDigest == after.generatedHost.templateDigest else {
            throw AutomationContractError.missingEvidence("Prepare changed source for the same app, configuration, destination and host template; retain both original products")
        }
    }
    typealias ExecutorFactory = @Sendable (AutomationApplicationSubject, CapabilityProfile, Bool) -> any AutomationCampaignAttemptExecutor
    static func executor(subject: AutomationApplicationSubject, runner: AutomationApplicationRunner,
                         capabilities: CapabilityProfile,
                         factory: ExecutorFactory? = nil) throws -> any AutomationCampaignAttemptExecutor {
        guard subject.target.kind != .physical else {
            throw AutomationContractError.missingEvidence("Unreadable installed apps cannot establish an exact-build comparison")
        }
        let install = subject.target.kind == .simulator
        if let factory { return factory(subject, capabilities, install) }
        return AutomationSubjectCampaignExecutor(runner: runner, subject: subject, capabilities: capabilities,
            allowBootAndInstall: install)
    }
}
typealias AutomationNativeFixComparisonExecutor = @Sendable (AutomationNativeUIFixComparisonProposal, AutomationApplicationSubject, AutomationApplicationSubject, URL) async throws -> AutomationFixComparisonReport
#endif
