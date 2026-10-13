#if os(macOS)
import Foundation

public struct AutomationPreparationPersistenceFailure: Error {
    public let preparationError: any Error
    public let persistenceError: any Error
}

/// Local diagnostics only: false drain flags mean proof was not retained, not that a resource is live.
struct AutomationPreparationCommandDiagnostic: Codable {
    let schemaVersion: Int
    let scope: AutomationScope
    let operation: String
    let errorDescription: String
    let exitStatus: Int32
    let ownedIdentity: AutomationProcessIdentity?
    let directChildReaped: Bool
    let pipesDrained: Bool
    let callbacksDrained: Bool
    let logsTruncated: Bool
    let stdout: Data
    let stderr: Data

    static func save(result: AutomationOwnedCommand.Result, scope: AutomationScope, operation: String,
                     error: any Error, root: URL) throws -> URL {
        try scope.validate()
        let logLimit = 1_048_576
        let record = Self(schemaVersion: 1, scope: scope, operation: operation,
            errorDescription: String(String(describing: error).prefix(8192)), exitStatus: result.exitStatus,
            ownedIdentity: result.ownedIdentity, directChildReaped: result.directChildReaped,
            pipesDrained: result.pipesDrained, callbacksDrained: result.callbacksDrained,
            logsTruncated: result.logsTruncated || result.stdout.count > logLimit || result.stderr.count > logLimit,
            stdout: Data(result.stdout.prefix(logLimit)), stderr: Data(result.stderr.prefix(logLimit)))
        let path = root.appendingPathComponent("preparation-command-failures").appendingPathComponent(UUID().uuidString + ".json")
        let file = try AutomationDurableFile(url: path, maximumBytes: 4_194_304)
        try file.write(JSONEncoder().encode(record))
        return file.url
    }
}

/// The willStart callback runs only after OwnedCommand resets this invocation's retained state.
actor AutomationPreparationCommandInvocation {
    private var entered = false
    func enter() { entered = true }
    func saveFailure(command: AutomationOwnedCommand, completed: AutomationOwnedCommand.Result? = nil,
                     scope: AutomationScope, operation: String, error: any Error, root: URL) async throws -> URL? {
        guard entered else { return nil }
        let retained = await command.retainedLogs()
        return try AutomationPreparationCommandDiagnostic.save(result: completed ?? retained,
            scope: scope, operation: operation, error: error, root: root)
    }
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
    private let simulatorInventory: @Sendable (URL, URL) async throws -> [AutomationSimulator]
    private let physicalAliasReader: (@Sendable (URL, URL) async throws -> [String: String])?
    public init(supportRoot: URL, developerDirectory: URL) throws {
        self.supportRoot = supportRoot; self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        simulatorInventory = { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) }
        physicalAliasReader = nil
    }
    init(supportRoot: URL, developerDirectory: URL,
         simulatorInventory: @escaping @Sendable (URL, URL) async throws -> [AutomationSimulator],
         physicalAliasReader: (@Sendable (URL, URL) async throws -> [String: String])? = nil) throws {
        let developer = try AutomationPath.canonical(developerDirectory)
        self.supportRoot = supportRoot; self.developerDirectory = developer
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        leases = manager
        self.physicalAliasReader = physicalAliasReader
        self.simulatorInventory = simulatorInventory

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
        try await registerPhysicalAliases(plan.target)
        return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory,
            leases: leases, campaignBudget: campaignBudget, siriAuthority: authority)
    }

    public func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        try await run(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
            fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings)
    }
    public func run(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        guard !running, subject.app == plan.app, subject.target == plan.target,
              attemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        failedPreparation = nil
        lastSetupCapture = nil
        latestFreshFixtureAttemptID = nil
        try subject.validate(plan: plan)
        guard let prepared = subject.prepared else {
            throw AutomationContractError.missingEvidence("Prepare the source app and its XCUITest host before running this workflow")
        }
        if plan.target.kind == .physical {
            guard allowBootAndInstall else {
                throw AutomationContractError.missingEvidence("Approve installation on the selected physical device before running its prepared host")
            }
            try await registerPhysicalAliases(plan.target)
        }
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        running = true; defer { running = false }
        var capabilities = capabilities
        if plan.target.kind == .simulator {
            let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
            capabilities = try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared,
                requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
        }
        guard fixtureTracker == nil || qualifyingFreshBindings == nil else { throw AutomationContractError.missingEvidence("Fresh query fixtures require their qualified associated host") }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard segments.allSatisfy({ [.ui, .observeOnly, .systemIntent, .systemQuery].contains($0.kind) }) else {
            throw AutomationContractError.missingEvidence("Prepared-app route is not qualified")
        }
        let needsUI = segments.contains { $0.usesUIControl }
        if needsUI || plan.target.kind != .simulator {
            _ = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
                attemptID: attemptID, leaseGeneration: 1)
        }
        // Check the qualified execution context before boot, install, or fixture actions.
        if let fixtureTracker {
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: plan.provenance["ui.locale"] ?? "", uiRuntimeManifestDigest: nil)
            try await fixtureTracker.preflight(context: context, plan: plan, approval: approval)
        }
        var qualificationFence: AutomationFreshFixtureQualificationFence?
        if let qualifyingFreshBindings {
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: plan.provenance["ui.locale"] ?? "", uiRuntimeManifestDigest: nil)
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
        var ownedBootCleanupAttempted = false
        var executionStarted = false
        var reservedCampaign = false
        do {
        try await leases.reserveCampaign(runID: approval.runID, target: approval.target)
        reservedCampaign = true
        if plan.target.kind == .simulator {
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
            try await release.prepare(target: plan.target, controllerBundleIDs: [prepared.host.hostBundleID])
            // Never install bytes that differ from the frozen prepared subject.
            guard let productPath = subject.productPath,
                  try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: productPath), version: plan.app.productDigestVersion) == plan.app.productDigest else { throw AutomationContractError.conflictingOperation }
            try await mutate(arguments: ["simctl", "install", plan.target.id, productPath], operation: "install", approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, maximumDuration: .seconds(120), campaignBudget: campaignBudget)
        } else {
            guard simulator.state == "Booted" else { throw AutomationContractError.missingEvidence("Starting the selected simulator requires approval") }
        }
        }
        executionStarted = true
        var report: AutomationAttemptReport
        if needsUI || plan.target.kind != .simulator {
            report = try await AutomationXCUITestCampaign.run(prepared: prepared.host, plan: plan,
                approval: approval, capabilities: capabilities, attemptID: attemptID, root: root,
                developerDirectory: developerDirectory, leases: leases, journal: journal,
                artifacts: artifacts, releaseVerifier: plan.target.kind == .simulator ? release : nil,
                campaignBudget: campaignBudget, releaseCampaignOnCompletion: !ownsBoot,
                fixtureTracker: fixtureTracker, qualificationFence: qualificationFence)
        } else {
            let apple = try AutomationAppleRouteDriver(prepared: prepared.host, approval: approval,
                developerDirectory: developerDirectory, stateDirectory: root.appendingPathComponent("apple"),
                leases: leases, artifacts: artifacts, subjectVerifier: verifier, releaseVerifier: release,
                campaignBudget: campaignBudget, capabilities: capabilities)
            report = try await AutomationCoordinator(leases: leases, journal: journal, cleanupTimeout: .seconds(90),
                releaseCampaignOnCompletion: !ownsBoot).run(plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, driver: apple,
                fixtureTracker: fixtureTracker, qualificationFence: qualificationFence)
        }
        if ownsBoot && report.resourcesReleased {
            ownedBootCleanupAttempted = true
            let shutDown = await Task.detached { await self.shutDownOwnedSimulator(approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget) }.value
            if shutDown { ownsBoot = false; reservedCampaign = false }
            else {
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
           let locale = plan.provenance["ui.locale"],
           approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) {
            let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: locale, uiRuntimeManifestDigest: nil)
            let live = AutomationLiveRecipeEvidence(context: context, plan: plan, approval: approval, report: report)
            if report.executionSucceeded { liveRecipeEvidence = live }
            liveFixtureEvidence.append(live)
            latestFreshFixtureAttemptID = attemptID
            if liveFixtureEvidence.count > 10 { liveFixtureEvidence.removeFirst() }
        }
        return report
        } catch {
            var bootReleased = !ownsBoot
            if ownsBoot && !ownedBootCleanupAttempted {
                ownedBootCleanupAttempted = true
                bootReleased = await Task.detached { await self.shutDownOwnedSimulator(approval: approval, attemptID: attemptID, root: root, journal: journal, release: release, campaignBudget: campaignBudget) }.value
                if bootReleased { ownsBoot = false; reservedCampaign = false }
            }
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
    /// Resolve aliases for comparison while preserving the frozen approved target.
    private func registerPhysicalAliases(_ target: TargetIdentity) async throws {
        guard target.kind == .physical else { return }
        var aliases: [String: String]
        if let physicalAliasReader { aliases = try await physicalAliasReader(developerDirectory, supportRoot) }
        else { aliases = try await AutomationPhysicalDeviceInventory.leaseAliases(developerDirectory: developerDirectory, workspace: supportRoot) }
        if let identifier = target.physicalDeviceIdentifier { aliases[target.id] = identifier }
        try await leases.registerPhysicalDeviceAliases(aliases)
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
    static func canReleaseBootCommand(arguments: [String], operation: String, target: TargetIdentity,
                                      result: AutomationOwnedCommand.Result) -> Bool {
        guard target.kind == .simulator, UUID(uuidString: target.id) != nil,
              operation == "boot", arguments == ["simctl", "boot", target.id],
              result.exitStatus == 0, !result.logsTruncated,
              result.directChildReaped, result.pipesDrained, result.callbacksDrained,
              let identity = result.ownedIdentity else { return false }
        return [.absent, .replaced].contains(identity.presence())
    }

    private func mutate(arguments: [String], operation: String, approval: RunApproval, attemptID: String, root: URL,
                        journal: AutomationJournal, release: AutomationSimulatorReleaseVerifier, targetWillBeShutdown: Bool = false,
                        maximumDuration: Duration = .seconds(60), campaignBudget: AutomationCampaignBudget? = nil) async throws {
        let lease = try await leases.acquire(runID: approval.runID, target: approval.target, control: .system)
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: "prepare." + operation, leaseGeneration: lease.generation)
        let digest = AutomationArtifactRegistry.digest(try JSONEncoder().encode(arguments)), key = attemptID + ".prepare." + operation
        var completedCommand: AutomationOwnedCommand.Result?
        let invocation = AutomationPreparationCommandInvocation()
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
                    await invocation.enter()
                    try await leases.validate(lease)
                    if !targetWillBeShutdown { try await campaignBudget?.available() }
                },
                didStart: { [leases] process in try await leases.recordRunner(.init(scope: scope, process: process, role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease) })
            completedCommand = result
            try await journal.complete(operationID: key, digest: digest, response: .integer(String(result.exitStatus)))
            let released: Bool
            if Self.canReleaseBootCommand(arguments: arguments, operation: operation, target: approval.target, result: result) {
                // Boot starts only the approved simulator. Keep the campaign reserved while
                // bootstatus waits for services, before asking launchctl for controller proof.
                // Lease release still verifies every recorded process and private payload.
                released = true
            } else if targetWillBeShutdown && result.exitStatus == 0 {
                let inventory = try await AutomationSimulatorInventory.read(developerDirectory: developerDirectory, workspace: root)
                released = inventory.contains { $0.id == approval.target.id && $0.state == "Shutdown" }
            } else { released = await release.verifyReleased(target: approval.target, controllerBundleIDs: []) }
            try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: released)
            guard result.exitStatus == 0 else { throw AutomationContractError.missingEvidence("Approved simulator " + operation + " did not complete") }
        } catch {
            _ = try? await invocation.saveFailure(command: command, completed: completedCommand,
                scope: scope, operation: operation, error: error, root: root)
            let drained = await Task.detached { await self.command.stopOwned() }.value
            let released = await release.verifyReleased(target: approval.target, controllerBundleIDs: [])
            try? await leases.release(lease, commandsDrained: drained, ownedRunnerTerminated: released)
            throw error
        }
    }
}
#endif
