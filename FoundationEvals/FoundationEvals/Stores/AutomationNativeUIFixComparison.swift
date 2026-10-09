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
    var usesFreshFixture: Bool { (try? AutomationFreshEntityPlanner.bindings(plan: baseline.plan)) != nil }
    var attemptsPerBuild: Int { 30 }
    var limits: AutomationCampaignLimits {
        var value = AutomationCampaignLimits()
        value.attempts = 30; value.subjectOperations = 30
        value.uiActions = 900; value.controllerCalls = 360; value.wallClockSeconds = 5400
        return value
    }
    static func compile(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                        before: AutomationApplicationSubject, after: AutomationApplicationSubject,
                        runtime: AutomationNativeUIRuntime, runID: String, disposable: Bool) throws -> Self {
        let reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: frozen, original: original,
            subject: before, runtime: runtime, runID: runID + ".before", disposable: disposable)
        guard before.app.productDigest != nil, before.target == after.target else { throw AutomationContractError.conflictingOperation }
        switch (before, after) {
        case (.installedUI, .installedUI):
            guard frozen.plan.provenance["ui.preparedHostDigest"] == nil else { throw AutomationContractError.conflictingOperation }
        case (.prepared(let baseline), .prepared(let candidate)):
            try validatePreparedCandidate(before: baseline, after: candidate)
        default: throw AutomationContractError.invalidPlan("Compare two installed builds or two prepared source builds")
        }
        let candidate: AutomationFrozenCase
        if frozen.plan.preparedMacBuildArtifacts != nil, case .prepared(let prepared) = after {
            candidate = try AutomationFixContract.candidate(from: frozen, prepared: prepared)
        } else { candidate = try AutomationFixContract.candidate(from: frozen, app: after.app) }
        let afterCapabilities: CapabilityProfile
        if reproduction.usesFreshFixture, case .prepared(let prepared) = after { afterCapabilities = AutomationNativeFreshFixtures.capabilities(prepared) }
        else { afterCapabilities = .init() }
        let beforeApproval = RunApproval(runID: runID + ".before", app: before.app, target: before.target,
            environmentID: frozen.plan.environmentID, effects: reproduction.approval.effects, maximumActions: 30,
            disposable: disposable, approvedCaseDigest: frozen.digest)
        let afterApproval = RunApproval(runID: runID + ".after", app: after.app, target: after.target,
            environmentID: candidate.plan.environmentID, effects: reproduction.approval.effects, maximumActions: 30,
            disposable: disposable, approvedCaseDigest: candidate.digest)
        try PlanValidator.validate(candidate.plan, approval: afterApproval, capabilities: afterCapabilities, purpose: .review)
        return .init(baseline: frozen, candidate: candidate, beforeApproval: beforeApproval, afterApproval: afterApproval, beforeCapabilities: reproduction.capabilities, afterCapabilities: afterCapabilities)
    }
    static func compileMac(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                           before: AutomationInstalledMacUIApplication, after: AutomationInstalledMacUIApplication,
                           runtimeRoot: URL, runID: String) throws -> Self {
        fromMacReview(try AutomationMacSavedWorkflowContract.comparison(frozen: frozen, original: original,
            before: before, after: after, runtimeRoot: runtimeRoot, runID: runID))
    }
    static func fromMacReview(_ review: AutomationMacSavedWorkflowContract.Comparison) -> Self {
        .init(baseline: review.baseline, candidate: review.candidate,
            beforeApproval: review.beforeApproval, afterApproval: review.afterApproval,
            beforeCapabilities: review.beforeCapabilities, afterCapabilities: review.afterCapabilities)
    }
    static func compilePreparedMac(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                                   before: AutomationPreparedApplication, after: AutomationPreparedApplication,
                                   runtimeRoot: URL, runID: String, disposable: Bool) throws -> Self {
        fromMacReview(try AutomationMacSavedWorkflowContract.comparison(frozen: frozen, original: original,
            before: before, after: after, runtimeRoot: runtimeRoot, runID: runID, disposable: disposable))
    }
    func execute(before: AutomationApplicationSubject, after: AutomationApplicationSubject,
                 runtime: AutomationUIRuntime?, support: URL, developerDirectory: URL) async throws -> AutomationFixComparisonReport {
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: support,
            developerDirectory: developerDirectory)
        var verified = self
        verified.beforeCapabilities = try await runner.capabilitiesForExecution(subject: before, plan: baseline.plan,
            capabilities: beforeCapabilities)
        verified.afterCapabilities = try await runner.capabilitiesForExecution(subject: after, plan: candidate.plan,
            capabilities: afterCapabilities)
        var beforeFixture: AutomationQualifiedFreshFixture?, afterFixture: AutomationQualifiedFreshFixture?
        if usesFreshFixture {
            guard let runtime, case .prepared(let a) = before, case .prepared(let b) = after else { throw AutomationContractError.invalidIdentity }
            beforeFixture = try await AutomationNativeFreshFixtures.qualify(frozen: baseline, prepared: a, approval: beforeApproval, capabilities: verified.beforeCapabilities, runner: runner, runtime: runtime, installApproved: true)
            afterFixture = try await AutomationNativeFreshFixtures.qualify(frozen: candidate, prepared: b, approval: afterApproval, capabilities: verified.afterCapabilities, runner: runner, runtime: runtime, installApproved: true)
        }
        return try await verified.runCampaign(cases: cases,
            beforeExecutor: Self.executor(subject: before, runner: runner, runtime: runtime, capabilities: verified.beforeCapabilities),
            afterExecutor: Self.executor(subject: after, runner: runner, runtime: runtime, capabilities: verified.afterCapabilities),
            beforeFixture: beforeFixture, afterFixture: afterFixture)
    }
    func runCampaign(cases: AutomationCaseStore, beforeExecutor: any AutomationCampaignAttemptExecutor,
                     afterExecutor: any AutomationCampaignAttemptExecutor,
                     beforeFixture: AutomationQualifiedFreshFixture?, afterFixture: AutomationQualifiedFreshFixture?) async throws -> AutomationFixComparisonReport {
        try await AutomationFixComparison(cases: cases).run(baseline: baseline, candidate: candidate,
            attemptsPerBuild: attemptsPerBuild, beforeApproval: beforeApproval, afterApproval: afterApproval,
            beforeCapabilities: beforeCapabilities, afterCapabilities: afterCapabilities, limits: limits,
            beforeExecutor: beforeExecutor, afterExecutor: afterExecutor, beforeFixture: beforeFixture, afterFixture: afterFixture)
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
            throw AutomationContractError.missingEvidence("Prepare changed source for the same app, configuration, simulator and host template; retain both original products")
        }
    }
    typealias ExecutorFactory = @Sendable (AutomationApplicationSubject, CapabilityProfile, Bool, AutomationUIRuntime?) -> any AutomationCampaignAttemptExecutor
    static func executor(subject: AutomationApplicationSubject, runner: AutomationApplicationRunner,
                         runtime: AutomationUIRuntime?, capabilities: CapabilityProfile,
                         factory: ExecutorFactory? = nil) throws -> any AutomationCampaignAttemptExecutor {
        guard subject.target.kind == .nativeMac || runtime != nil else {
            throw AutomationContractError.missingEvidence("Saved simulator campaigns require the reviewed UI runtime")
        }
        guard subject.target.kind != .physical else {
            throw AutomationContractError.missingEvidence("Unreadable installed apps cannot establish an exact-build comparison")
        }
        let install = subject.target.kind == .simulator
        if let factory { return factory(subject, capabilities, install, runtime) }
        return AutomationSubjectCampaignExecutor(runner: runner, subject: subject, capabilities: capabilities,
            allowBootAndInstall: install, uiRuntime: runtime)
    }
}
typealias AutomationNativeFixComparisonExecutor = @Sendable (AutomationNativeUIFixComparisonProposal, AutomationApplicationSubject, AutomationApplicationSubject, AutomationUIRuntime?, URL) async throws -> AutomationFixComparisonReport
#endif
