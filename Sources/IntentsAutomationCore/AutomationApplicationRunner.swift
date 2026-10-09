#if os(macOS)
import Foundation

public struct AutomationUIRuntime: Sendable {
    public let bundleURL: URL
    public let expectedTeamID: String
    public init(bundleURL: URL, expectedTeamID: String) { self.bundleURL = bundleURL; self.expectedTeamID = expectedTeamID }
}
public struct AutomationPreparationPersistenceFailure: Error {
    public let preparationError: any Error
    public let persistenceError: any Error
}

/// Product entry point for prepared-app campaigns. All routes share the native target lease store.
public actor AutomationApplicationRunner {
    private let supportRoot: URL
    private let developerDirectory: URL
    private let leases: AutomationDeviceLeaseManager
    private let command = AutomationOwnedCommand()
    private var running = false
    private var failedPreparation: (attemptID: String, planDigest: String, runID: String, report: AutomationAttemptReport)?
    private var liveRecipeEvidence: AutomationLiveRecipeEvidence?
    private var lastSetupCapture: AutomationControllerSetupCapture?
    private var liveFixtureEvidence: [AutomationLiveRecipeEvidence] = []
    private var latestFreshFixtureAttemptID: String?
    private var latestAppleRuntimeContext: AutomationLiveAppleRuntimeContext?
    private let simulatorInventory: @Sendable (URL, URL) async throws -> [AutomationSimulator]
    private let physicalQualification: AutomationPhysicalUIQualification?
    private let macQualification: AutomationMacUIQualification?
    public init(supportRoot: URL, developerDirectory: URL) throws {
        self.supportRoot = supportRoot; self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        simulatorInventory = { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) }
        physicalQualification = nil
        macQualification = nil
    }
    init(supportRoot: URL, developerDirectory: URL,
         simulatorInventory: @escaping @Sendable (URL, URL) async throws -> [AutomationSimulator],
         physicalQualification: AutomationPhysicalUIQualification.Dependencies? = nil,
         macQualification: AutomationMacUIQualification.Dependencies? = nil) throws {
        let developer = try AutomationPath.canonical(developerDirectory)
        self.supportRoot = supportRoot; self.developerDirectory = developer
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        leases = manager
        self.simulatorInventory = simulatorInventory
        self.physicalQualification = physicalQualification.map { .init(root: supportRoot, developerDirectory: developer,
            leases: manager, dependencies: $0) }
        self.macQualification = macQualification.map { .init(root: supportRoot, leases: manager, dependencies: $0) }
    }
    /// Resolve independently qualified codecs before a campaign's preflight.
    /// The runner repeats this verification before every actual attempt.
    public func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                         capabilities: CapabilityProfile) async throws -> CapabilityProfile {
        guard !running, subject.app == plan.app, subject.target == plan.target else {
            throw AutomationContractError.invalidIdentity
        }
        running = true; defer { running = false }
        try subject.validate(plan: plan)
        if let prepared = subject.prepared, plan.target.kind == .physical {
            return try await AutomationSiriCapabilitySnapshot.resolve(prepared: prepared, capabilities: capabilities)
        }
        guard let prepared = subject.prepared, plan.target.kind == .simulator else { return capabilities }
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
        return try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared,
            requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
    }

    /// Calibrate a narrowly approved record-state workflow through actual Siri and
    /// independent before/after queries. Only direct released passing execution
    /// can create process-local routing authority for this exact frozen case.
    public func qualifySiriWorkflow(prepared: AutomationPreparedApplication, plan: AutomationCase,
                                    approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                                    allowInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil) async throws -> AutomationAttemptReport {
        guard !running, allowInstall else { throw AutomationContractError.conflictingOperation }
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval)
        running = true; defer { running = false }
        return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory,
            leases: leases, runtime: nil, campaignBudget: campaignBudget, siriAuthority: authority)
    }

    /// Internal qualification seam; ordinary app intake cannot enable an unproved route.
    func preparePhysicalUI(selected: AutomationInstalledUIApplication, approval: RunApproval, attemptID: String,
                           allowInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil) async throws -> AutomationPhysicalUIQualification.Preparation {
        guard !running, let physicalQualification else { throw AutomationContractError.missingEvidence("Physical UI qualification route is unavailable") }
        running = true; defer { running = false }
        return try await physicalQualification.prepare(selected: selected, approval: approval, attemptID: attemptID,
            allowInstall: allowInstall, campaignBudget: campaignBudget)
    }
    public func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    uiRuntime: AutomationUIRuntime? = nil, fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        try await run(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
            uiRuntime: uiRuntime, fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings)
    }
    public func run(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    uiRuntime: AutomationUIRuntime? = nil, fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        guard !running, subject.app == plan.app, subject.target == plan.target,
              attemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        failedPreparation = nil
        lastSetupCapture = nil
        latestFreshFixtureAttemptID = nil
        latestAppleRuntimeContext = nil
        try subject.validate(plan: plan)
        if case .installedMacUI(let selected) = subject {
            guard let macQualification else { throw AutomationContractError.missingEvidence("Mac UI execution requires a qualified native route") }
            guard !allowBootAndInstall, uiRuntime == nil, fixtureTracker == nil, qualifyingFreshBindings == nil else {
                throw AutomationContractError.invalidPlan("Mac UI requires its separate frozen runtime and campaign")
            }
            running = true; defer { running = false }
            liveRecipeEvidence = nil
            return try await macQualification.run(selected: selected, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, campaignBudget: campaignBudget)
        }
        if case .installedPhysicalUI(let selected) = subject {
            guard let physicalQualification else { throw AutomationContractError.missingEvidence("Physical installed-app UI execution requires a qualified device route") }
            guard !allowBootAndInstall, fixtureTracker == nil, qualifyingFreshBindings == nil, let uiRuntime else {
                throw AutomationContractError.missingEvidence("Physical UI requires separate owned preparation and its signed runtime")
            }
            running = true; defer { running = false }
            liveRecipeEvidence = nil
            return try await physicalQualification.run(selected: selected, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, runtime: uiRuntime, campaignBudget: campaignBudget)
        }
        if let prepared = subject.prepared, plan.target.kind == .physical {
            guard allowBootAndInstall, qualifyingFreshBindings == nil, fixtureTracker == nil else {
                throw AutomationContractError.missingEvidence("Prepared physical execution requires explicit owned installation approval")
            }
            running = true; defer { running = false }
            return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory,
                leases: leases, runtime: uiRuntime, campaignBudget: campaignBudget)
        }
        if let prepared = subject.prepared, plan.target.kind == .nativeMac {
            guard let macQualification else {
                throw AutomationContractError.missingEvidence("Prepared Mac system and mixed execution require a qualified associated-host route")
            }
            guard !allowBootAndInstall, uiRuntime == nil else {
                throw AutomationContractError.missingEvidence("Prepared Mac qualification does not accept installation or simulator runtime")
            }
            running = true; defer { running = false }
            let report = try await macQualification.run(prepared: prepared, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, campaignBudget: campaignBudget, fixtureTracker: fixtureTracker,
                qualifyingFreshBindings: qualifyingFreshBindings, previousFreshEvidence: liveFixtureEvidence)
            latestAppleRuntimeContext = await macQualification.runtimeContext(report: report, plan: plan, host: prepared.host)
            if let live = await macQualification.freshEvidence(attemptID: attemptID) {
                liveFixtureEvidence.append(live); latestFreshFixtureAttemptID = attemptID
                if liveFixtureEvidence.count > 10 { liveFixtureEvidence.removeFirst() }
            }
            return report
        }
        guard plan.target.kind != .nativeMac else {
            throw AutomationContractError.missingEvidence("Prepared Mac system and mixed execution require a qualified associated-host route")
        }
        guard plan.target.kind != .physical else {
            throw AutomationContractError.missingEvidence("Physical execution requires owned installation evidence and its qualified device route")
        }
        let prepared = subject.prepared
        if let prepared { try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog) }
        running = true; defer { running = false }
        var capabilities = capabilities
        if let prepared {
            let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
            capabilities = try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared,
                requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
        }
        guard (prepared != nil || (fixtureTracker == nil && qualifyingFreshBindings == nil)),
              fixtureTracker == nil || qualifyingFreshBindings == nil else { throw AutomationContractError.missingEvidence("Fresh query fixtures require their qualified associated host") }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard segments.allSatisfy({ [.ui, .systemIntent, .systemQuery].contains($0.kind) }) else {
            throw AutomationContractError.missingEvidence("Prepared-app route is not qualified")
        }
        let needsUI = segments.contains { $0.kind == .ui }
        var verifiedRuntimeDigest: String?
        if needsUI {
            guard let uiRuntime else { throw AutomationContractError.missingEvidence("Mixed plans require the signed private UI runtime") }
            // Verify before creating an attempt, booting, or installing any subject bytes.
            _ = try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: uiRuntime.bundleURL,
                stateDirectory: supportRoot.appendingPathComponent(attemptID).appendingPathComponent("ui"), expectedTeamID: uiRuntime.expectedTeamID)
            verifiedRuntimeDigest = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: uiRuntime.bundleURL,
                relativePath: "Contents/Resources/Automation/runtime-manifest.json", maximumBytes: 4_194_304))
        }
        if let declared = plan.provenance["ui.runtimeManifestDigest"] {
            guard declared == verifiedRuntimeDigest else { throw AutomationContractError.conflictingOperation }
        }
        if let declared = plan.provenance["ui.runtimeTeamID"] {
            guard declared == uiRuntime?.expectedTeamID else { throw AutomationContractError.conflictingOperation }
        }
        // Check the qualified execution context before boot, install, or fixture actions.
        if let fixtureTracker {
            guard let prepared else { throw AutomationContractError.invalidIdentity }
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: plan.provenance["ui.locale"] ?? "", uiRuntimeManifestDigest: verifiedRuntimeDigest)
            try await fixtureTracker.preflight(context: context, plan: plan, approval: approval)
        }
        var qualificationFence: AutomationFreshFixtureQualificationFence?
        if let qualifyingFreshBindings {
            guard let prepared else { throw AutomationContractError.invalidIdentity }
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: plan.provenance["ui.locale"] ?? "", uiRuntimeManifestDigest: verifiedRuntimeDigest)
            qualificationFence = try .init(bindings: qualifyingFreshBindings, plan: plan, approval: approval, capabilities: capabilities,
                context: context, previous: liveFixtureEvidence)
        }
        liveRecipeEvidence = nil
        let cases = try AutomationCaseStore(root: supportRoot.appendingPathComponent("Cases"))
        let frozen = try await cases.freeze(plan)
        let root = supportRoot.appendingPathComponent(attemptID)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
        let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"), secretEvidenceRoot: supportRoot.appendingPathComponent("secret-evidence"))
        let release = AutomationSimulatorReleaseVerifier(developerDirectory: developerDirectory, workspace: root)
        let verifier = AutomationInstalledSubjectVerifier(developerDirectory: developerDirectory, workspace: root)
        var ownsBoot = false
        var executionStarted = false
        var reservedCampaign = false
        do {
        try await leases.reserveCampaign(runID: approval.runID, target: approval.target)
        reservedCampaign = true
        let inventory = try await simulatorInventory(developerDirectory, root)
        guard let simulator = inventory.first(where: { $0.id == plan.target.id }) else { throw AutomationContractError.missingEvidence("Selected iOS 27 simulator is unavailable") }
        if allowBootAndInstall {
            if simulator.state != "Booted" {
                guard simulator.state == "Shutdown" else { throw AutomationContractError.targetBusy }
                try await mutate(arguments: ["simctl", "boot", plan.target.id], operation: "boot", approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget)
                ownsBoot = true
            }
            // `simctl boot` returns before installation services are ready.
            // Monitor this already-started device; do not implicitly boot another one.
            try await mutate(arguments: ["simctl", "bootstatus", plan.target.id], operation: "bootReady", approval: approval,
                attemptID: attemptID, root: root, journal: journal, release: release,
                maximumDuration: .seconds(120), campaignBudget: campaignBudget)
            try await release.prepare(target: plan.target, controllerBundleIDs: prepared.map { [$0.host.hostBundleID] } ?? [])
            // Never install bytes that differ from the frozen prepared subject.
            guard let productPath = subject.productPath,
                  try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: productPath), version: plan.app.productDigestVersion) == plan.app.productDigest else { throw AutomationContractError.conflictingOperation }
            try await mutate(arguments: ["simctl", "install", plan.target.id, productPath], operation: "install", approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget)
        } else {
            guard simulator.state == "Booted" else { throw AutomationContractError.missingEvidence("Starting the selected simulator requires approval") }
        }
        let apple: AutomationAppleRouteDriver?
        if let prepared {
            apple = try AutomationAppleRouteDriver(prepared: prepared.host, approval: approval, developerDirectory: developerDirectory,
                stateDirectory: root.appendingPathComponent("apple"), leases: leases, artifacts: artifacts, subjectVerifier: verifier, releaseVerifier: release, campaignBudget: campaignBudget, capabilities: capabilities)
        } else { apple = nil }
        let driver: any AutomationRouteDriver
        var setupDriver: AutomationSidecarRouteDriver?
        if needsUI, let uiRuntime {
            let ui = try AutomationSidecarRouteDriver(bundleURL: uiRuntime.bundleURL, expectedTeamID: uiRuntime.expectedTeamID,
                stateDirectory: root.appendingPathComponent("ui"), approval: approval, leases: leases, artifacts: artifacts,
                subjectVerifier: verifier, releaseVerifier: release, campaignBudget: campaignBudget, developerDirectory: developerDirectory)
            setupDriver = ui
            if let apple { driver = AutomationMixedRouteDriver(ui: ui, apple: apple) }
            else { driver = ui }
        } else if let apple { driver = apple }
        else { throw AutomationContractError.missingEvidence("Installed UI-only checks require the signed UI runtime") }
        executionStarted = true
        var report = try await AutomationCoordinator(leases: leases, journal: journal).run(plan: plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, driver: driver, fixtureTracker: fixtureTracker, qualificationFence: qualificationFence)
        if ownsBoot && report.resourcesReleased {
            let shutDown = await Task.detached { await self.shutDownOwnedSimulator(approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget) }.value
            if !shutDown {
                report.resourcesReleased = false; report.result.summary = .unresolved
                report.result.assessed = false; report.result.evidenceComplete = false
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let store = try AutomationDurableFile(url: root.appendingPathComponent("report.json"), maximumBytes: 16 * 1024 * 1024)
        try store.withLock { try store.write(try encoder.encode(report)) }
        try await cases.saveAttempt(report, for: frozen)
        if report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
           [.passed, .assertionFailed, .executedUnassessed].contains(report.result.summary),
           let prepared, let locale = plan.provenance["ui.locale"],
           approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) {
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: locale, uiRuntimeManifestDigest: verifiedRuntimeDigest)
            let live = AutomationLiveRecipeEvidence(context: context, plan: plan, approval: approval, report: report)
            if report.executionSucceeded { liveRecipeEvidence = live }
            if let segment = plan.setup.last(where: { $0.uiProgram?.operations.first?.kind == .navigateGoal }) {
                let receipts = report.receipts.filter { $0.segmentID == segment.id && $0.route == .ui && $0.completed && $0.dispatched }
                if receipts.count == 1 { lastSetupCapture = await setupDriver?.releasedSetupCapture(scope: receipts[0].scope) }
            }
            liveFixtureEvidence.append(live)
            latestFreshFixtureAttemptID = attemptID
            if liveFixtureEvidence.count > 10 { liveFixtureEvidence.removeFirst() }
        }
        return report
        } catch {
            var bootReleased = !ownsBoot
            if ownsBoot { bootReleased = await Task.detached { await self.shutDownOwnedSimulator(approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget) }.value }
            let uncertain = error as? AutomationContractError == .terminationUnverified
            if reservedCampaign && bootReleased && !uncertain { try? await leases.releaseCampaign(runID: approval.runID, target: approval.target) }
            if !executionStarted {
                // Retain preparation failures. Never manufacture a subject receipt,
                // repeat a mutation, or erase an unresolved preparation lease.
                let absent = (try? await leases.campaignAbsent(target: approval.target)) == true
                let released = bootReleased && absent && !uncertain
                let termination: AttemptResult.Summary = !released ? .unresolved : error is CancellationError ? .cancelled : .infrastructureFailed
                let failure = AutomationAttemptReport(attemptID: attemptID,
                    result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false,
                        subjectCompleted: false, observations: [], termination: termination), receipts: [], resourcesReleased: released)
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let store = try AutomationDurableFile(url: root.appendingPathComponent("report.json"), maximumBytes: 16 * 1024 * 1024)
                    try store.withLock { try store.write(try encoder.encode(failure)) }
                    try await cases.saveAttempt(failure, for: frozen)
                    failedPreparation = (attemptID, frozen.digest, approval.runID, failure)
                } catch let persistenceError {
                    throw AutomationPreparationPersistenceFailure(preparationError: error, persistenceError: persistenceError)
                }
            }
            throw error
        }
    }
    /// Recover only a failure persisted by this runner's current invocation. Empty-receipt
    /// reports cannot independently establish their plan/run scope. No filesystem read,
    /// directory creation or historical attempt can supply this recovery.
    func retainedAttempt(attemptID: String, plan: AutomationCase, runID: String) throws -> AutomationAttemptReport? {
        guard let failure = failedPreparation, failure.attemptID == attemptID,
              failure.planDigest == (try AutomationFrozenCase.planDigest(plan)), failure.runID == runID else { return nil }
        try AutomationRecordedEvidence.validate(report: failure.report, plan: plan, expectedRunID: runID)
        return failure.report
    }
    func appleRuntimeContext(report: AutomationAttemptReport, plan: AutomationCase, host: AutomationPreparedAppleHost) -> AutomationLiveAppleRuntimeContext? {
        guard !running, let context = latestAppleRuntimeContext,
              (try? context.matches(report: report, plan: plan, host: host)) == true else { return nil }
        return context
    }
    public func captureFreshSetup(bindings: [AutomationFreshFixtureBinding]) throws -> AutomationCapturedSetupAttempt {
        guard !running, let live = liveFixtureEvidence.last, let capture = lastSetupCapture else {
            throw AutomationContractError.missingEvidence("No released complete live setup trace")
        }
        return try .init(live: live, capture: capture, bindings: bindings)
    }
    public func qualifyRecipe(_ candidate: AutomationSetupRecipeCandidate) throws -> AutomationQualifiedSetupRecipe {
        guard !running, let liveRecipeEvidence else { throw AutomationContractError.missingEvidence("No complete live recipe qualification in this runner") }
        return try .init(candidate: candidate, live: liveRecipeEvidence)
    }
    public func qualifyFreshFixture(bindings: [AutomationFreshFixtureBinding]) throws -> AutomationQualifiedFreshFixture {
        guard !running else { throw AutomationContractError.targetBusy }
        guard latestFreshFixtureAttemptID == liveFixtureEvidence.last?.report.attemptID,
              latestFreshFixtureAttemptID != nil else { throw AutomationContractError.missingEvidence("No eligible latest live fixture attempt") }
        return try .init(bindings: bindings, evidence: Array(liveFixtureEvidence.suffix(2)))
    }
    public func validateFreshFixtureAttempt(bindings: [AutomationFreshFixtureBinding]) throws {
        guard !running, let live = liveFixtureEvidence.last, latestFreshFixtureAttemptID == live.report.attemptID else {
            throw AutomationContractError.missingEvidence("No eligible latest live fixture attempt")
        }
        try AutomationQualifiedFreshFixture.validateLiveAttempt(bindings: bindings, evidence: live)
    }
    private func shutDownOwnedSimulator(approval: RunApproval, attemptID: String, root: URL,
                                       journal: AutomationJournal, release: AutomationSimulatorReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil) async -> Bool {
        do {
            try await release.prepare(target: approval.target, controllerBundleIDs: [])
            try await mutate(arguments: ["simctl", "shutdown", approval.target.id], operation: "shutdown", approval: approval,
                attemptID: attemptID, root: root, journal: journal, release: release, targetWillBeShutdown: true, campaignBudget: campaignBudget)
            try await leases.releaseCampaign(runID: approval.runID, target: approval.target)
            return true
        } catch { return false }
    }
    private func mutate(arguments: [String], operation: String, approval: RunApproval, attemptID: String, root: URL,
                        journal: AutomationJournal, release: AutomationSimulatorReleaseVerifier, targetWillBeShutdown: Bool = false,
                        maximumDuration: Duration = .seconds(60), campaignBudget: AutomationCampaignBudget? = nil) async throws {
        let lease = try await leases.acquire(runID: approval.runID, target: approval.target, control: .system)
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: "prepare." + operation, leaseGeneration: lease.generation)
        let digest = AutomationArtifactRegistry.digest(try JSONEncoder().encode(arguments)), key = attemptID + ".prepare." + operation
        do {
            if targetWillBeShutdown { try await campaignBudget?.reserveResourceRelease(id: key) }
            else { try await campaignBudget?.reserveOperations(id: key, phase: .setup, count: 1) }
            let timeout = targetWillBeShutdown ? Duration.seconds(60) : min(maximumDuration, try await campaignBudget?.remainingDuration() ?? maximumDuration)
            guard try await journal.begin(operationID: key, digest: digest) == nil else { throw AutomationContractError.ambiguousDispatch }
            try await leases.recordDispatch(.init(scope: scope, operationID: key, payloadDigest: digest), lease: lease)
            let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, directory: root,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path,
                              "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: timeout,
                willStart: { [leases] in
                    try await leases.validate(lease)
                    if !targetWillBeShutdown { try await campaignBudget?.available() }
                },
                didStart: { [leases] process in try await leases.recordRunner(.init(scope: scope, process: process, role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease) })
            try await journal.complete(operationID: key, digest: digest, response: .integer(String(result.exitStatus)))
            let released: Bool
            if targetWillBeShutdown && result.exitStatus == 0 {
                let inventory = try await AutomationSimulatorInventory.read(developerDirectory: developerDirectory, workspace: root)
                released = inventory.contains { $0.id == approval.target.id && $0.state == "Shutdown" }
            } else { released = await release.verifyReleased(target: approval.target, controllerBundleIDs: []) }
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: released)
            guard result.exitStatus == 0 else { throw AutomationContractError.missingEvidence("Approved simulator " + operation + " did not complete") }
        } catch {
            let drained = await Task.detached { await self.command.stopOwned() }.value
            let released = await release.verifyReleased(target: approval.target, controllerBundleIDs: [])
            try? await leases.release(lease, commandsDrained: drained, ownedRunnerTerminated: released)
            throw error
        }
    }
}
#endif
