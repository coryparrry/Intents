#if os(macOS)
import Foundation

/// Internal composition only; ordinary product construction has no Mac qualification dependency.
actor AutomationMacUIQualification {
    struct DriverContext: Sendable {
        let receiptSHA256: String
        let inputCapabilities: AutomationMacInputCapabilities
        let state: URL
        let approval: RunApproval
        let leases: AutomationDeviceLeaseManager
        let artifacts: AutomationArtifactRegistry
        let campaignBudget: AutomationCampaignBudget?
    }
    struct AppleDriverContext: Sendable {
        let capabilities: CapabilityProfile
        let host: AutomationPreparedAppleHost
        let state: URL
        let approval: RunApproval
        let leases: AutomationDeviceLeaseManager
        let artifacts: AutomationArtifactRegistry
        let campaignBudget: AutomationCampaignBudget?
    }
    struct Dependencies: Sendable {
        let runtimeRoot: URL
        var verifyRuntime: @Sendable (URL) throws -> String
        var driver: @Sendable (DriverContext) throws -> any AutomationRouteDriver
        var validateTarget: @Sendable (TargetIdentity) throws -> Void = { _ in }
        // Owned construction leaves this nil until actual XCTest child closure is qualified.
        var appleDriver: (@Sendable (AppleDriverContext) throws -> any AutomationRouteDriver)? = nil
        static func owned(runtimeRoot: URL, developerDirectory: URL) -> Self {
            .init(runtimeRoot: runtimeRoot, verifyRuntime: { root in
                let unit = try AutomationPrivateMacDaemonUnit.load(root: root)
                guard AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: unit.evidence.receiptSHA256) != nil else {
                    throw AutomationContractError.missingEvidence("Mac programs require the frozen program runtime")
                }
                return unit.evidence.receiptSHA256
            }, driver: { context in
                var dependencies = AutomationMacOwnedDaemonSession.Dependencies.owned(workspace: context.state, developerDirectory: developerDirectory)
                dependencies.unit = { root in
                    let unit = try AutomationPrivateMacDaemonUnit.load(root: root)
                    guard unit.evidence.receiptSHA256 == context.receiptSHA256, unit.inputCapabilities == context.inputCapabilities else { throw AutomationContractError.conflictingOperation }
                    return unit
                }
                let selectedDependencies = dependencies
                return try AutomationMacUIRouteDriver(state: context.state, approval: context.approval, leases: context.leases,
                    artifacts: context.artifacts, subject: dependencies.subject, campaignBudget: context.campaignBudget, inputCapabilities: context.inputCapabilities,
                    factory: { selected in
                        try await AutomationMacOwnedDaemonSession(unitRoot: runtimeRoot, app: selected.app, target: selected.target,
                            scope: selected.scope, lease: selected.lease, leases: context.leases, state: selected.state,
                            authorize: selected.authorize, dependencies: selectedDependencies, review: selected.review, revalidate: selected.revalidate)
                    })
            }, validateTarget: { try AutomationMacGUIIdentity.validate($0) })
        }
    }
    private let root: URL, leases: AutomationDeviceLeaseManager, dependencies: Dependencies
    private var busy = false
    private var lastFreshEvidence: AutomationLiveRecipeEvidence?
    private var lastRuntimeContext: AutomationLiveAppleRuntimeContext?
    init(root: URL, leases: AutomationDeviceLeaseManager, dependencies: Dependencies) {
        self.root = root; self.leases = leases; self.dependencies = dependencies
    }
    func run(selected: AutomationInstalledMacUIApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, campaignBudget: AutomationCampaignBudget?) async throws -> AutomationAttemptReport {
        try AutomationApplicationSubject.installedMacUI(selected).validate(plan: plan)
        return try await run(plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID,
                             campaignBudget: campaignBudget, prepared: nil)
    }
    func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, campaignBudget: AutomationCampaignBudget?,
             fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil,
             previousFreshEvidence: [AutomationLiveRecipeEvidence] = []) async throws -> AutomationAttemptReport {
        guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) else {
            throw AutomationContractError.invalidPlan("Prepared Mac execution requires this exact reviewed case")
        }
        try AutomationPreparedMacBuildArtifacts.validateSelection(prepared, plan: plan)
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        return try await run(plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID,
                             campaignBudget: campaignBudget, prepared: prepared, fixtureTracker: fixtureTracker,
                             qualifyingFreshBindings: qualifyingFreshBindings, previousFreshEvidence: previousFreshEvidence)
    }
    func freshEvidence(attemptID: String) -> AutomationLiveRecipeEvidence? {
        lastFreshEvidence?.report.attemptID == attemptID ? lastFreshEvidence : nil
    }
    func runtimeContext(report: AutomationAttemptReport, plan: AutomationCase, host: AutomationPreparedAppleHost) -> AutomationLiveAppleRuntimeContext? {
        guard let context = lastRuntimeContext, (try? context.matches(report: report, plan: plan, host: host)) == true else { return nil }
        return context
    }
    private func run(plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                     campaignBudget: AutomationCampaignBudget?, prepared: AutomationPreparedApplication?,
                     fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil,
                     previousFreshEvidence: [AutomationLiveRecipeEvidence] = []) async throws -> AutomationAttemptReport {
        guard !busy, attemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        busy = true; defer { busy = false }
        lastFreshEvidence = nil
        lastRuntimeContext = nil
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        guard fixtureTracker == nil || qualifyingFreshBindings == nil,
              prepared != nil || (fixtureTracker == nil && qualifyingFreshBindings == nil) else {
            throw AutomationContractError.missingEvidence("Fresh Mac fixtures require one qualified associated-host authority")
        }
        try dependencies.validateTarget(plan.target)
        try campaignBudget?.validateDeadline()
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        let hasUI = segments.contains { $0.kind == .ui }, hasApple = segments.contains { $0.kind == .systemIntent || $0.kind == .systemQuery }
        guard segments.allSatisfy({ $0.kind == .ui || $0.kind == .systemIntent || $0.kind == .systemQuery }) else { throw AutomationContractError.invalidPlan("Unsupported Mac route") }
        if hasApple {
            guard let prepared, dependencies.appleDriver != nil else {
                throw AutomationContractError.missingEvidence("Prepared Mac system execution requires qualified associated-host child closure")
            }
            if plan.preparedMacBuildArtifacts == nil {
                guard plan.provenance["apple.macHostProductDigest"] == prepared.host.hostProductDigest,
                      plan.provenance["apple.macXctestrunDigest"] == prepared.host.xctestrunDigest else { throw AutomationContractError.conflictingOperation }
            }
        }
        let receipt = hasUI ? try dependencies.verifyRuntime(dependencies.runtimeRoot) : ""
        let inputs = hasUI ? AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: receipt) : .tapOnly
        guard let inputs, !hasUI || plan.provenance["ui.privateMacReceiptSHA256"] == receipt else { throw AutomationContractError.conflictingOperation }
        for segment in segments {
            if segment.kind == .ui {
                try AutomationMacUIProgramPreflight.validateDeferred(segment, capabilities: inputs, attemptID: attemptID)
            }
            else { guard segment.uiProgram == nil, segment.hostProgram != nil else { throw AutomationContractError.invalidPlan("Mac system route requires a typed associated-host program") } }
        }
        var context: AutomationRecipeContext?
        if let prepared, let locale = plan.provenance["ui.locale"] {
            // The shared fixture context's runtime slot binds the whole sealed Mac receipt.
            context = .init(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: locale, uiRuntimeManifestDigest: hasUI ? receipt : nil)
        }
        var qualificationFence: AutomationFreshFixtureQualificationFence?
        if let fixtureTracker {
            guard let context else { throw AutomationFixtureFreshnessError.invalidFixture }
            try await fixtureTracker.preflight(context: context, plan: plan, approval: approval)
        }
        if let qualifyingFreshBindings {
            guard let context else { throw AutomationFixtureFreshnessError.invalidFixture }
            qualificationFence = try .init(bindings: qualifyingFreshBindings, plan: plan, approval: approval,
                capabilities: capabilities, context: context, previous: previousFreshEvidence)
        }
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases")), frozen = try await cases.freeze(plan)
        let state = root.appendingPathComponent(attemptID)
        guard !FileManager.default.fileExists(atPath: state.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = try AutomationJournal(url: state.appendingPathComponent("journal.json"))
        let artifacts = try AutomationArtifactRegistry(root: state.appendingPathComponent("artifacts"), secretEvidenceRoot: root.appendingPathComponent("secret-evidence"))
        var reserved = false, started = false
        do {
            try campaignBudget?.validateDeadline()
            try await leases.reserveCampaign(runID: approval.runID, target: approval.target)
            reserved = true
            let ui = hasUI ? try dependencies.driver(.init(receiptSHA256: receipt, inputCapabilities: inputs, state: state.appendingPathComponent("ui"), approval: approval,
                leases: leases, artifacts: artifacts, campaignBudget: campaignBudget)) : nil
            let apple: (any AutomationRouteDriver)?
            if hasApple {
                guard let prepared, let factory = dependencies.appleDriver else { throw AutomationContractError.missingEvidence("No qualified Mac system owner") }
                apple = try factory(.init(capabilities: capabilities, host: prepared.host, state: state.appendingPathComponent("apple"), approval: approval,
                    leases: leases, artifacts: artifacts, campaignBudget: campaignBudget))
            } else { apple = nil }
            let driver: any AutomationRouteDriver
            if let ui, let apple { driver = AutomationMixedRouteDriver(ui: ui, apple: apple) }
            else if let ui { driver = ui }
            else if let apple { driver = apple }
            else { throw AutomationContractError.missingEvidence("No qualified Mac route owner") }
            started = true
            let coordinator = try AutomationCoordinator(leases: leases, journal: journal, cleanupTimeout: .seconds(90), campaignDeadline: campaignBudget?.deadline)
            let report = try await coordinator.run(plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID,
                driver: driver, fixtureTracker: fixtureTracker, qualificationFence: qualificationFence)
            try persist(report, state: state)
            try await cases.saveAttempt(report, for: frozen)
            if let owner = apple as? AutomationPrivateMacAppleRouteDriver {
                lastRuntimeContext = await owner.runtimeContext(report: report, plan: plan)
            }
            if let context, report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
               [.passed, .assertionFailed, .executedUnassessed].contains(report.result.summary),
               approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) {
                lastFreshEvidence = .init(context: context, plan: plan, approval: approval, report: report)
            }
            return report
        } catch {
            guard !started else { throw error }
            if reserved { try? await leases.releaseCampaign(runID: approval.runID, target: approval.target) }
            let absent = (try? await leases.campaignAbsent(target: approval.target)) == true
            let report = AutomationAttemptReport(attemptID: attemptID,
                result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false,
                    subjectCompleted: false, observations: [], termination: absent ? .infrastructureFailed : .unresolved),
                receipts: [], resourcesReleased: absent)
            do { try persist(report, state: state); try await cases.saveAttempt(report, for: frozen) }
            catch let persistence { throw AutomationPreparationPersistenceFailure(preparationError: error, persistenceError: persistence) }
            return report
        }
    }
    private func persist(_ report: AutomationAttemptReport, state: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = try AutomationDurableFile(url: state.appendingPathComponent("report.json"), maximumBytes: 16_777_216)
        try file.withLock { try file.write(try encoder.encode(report)) }
    }
}
#endif
