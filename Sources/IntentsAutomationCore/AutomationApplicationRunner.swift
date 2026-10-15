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
    private var servingJavaScript = false
    private var failedPreparation: (attemptID: String, planDigest: String, runID: String, report: AutomationAttemptReport)?
    private var liveRecipeEvidence: AutomationLiveRecipeEvidence?
    private var lastSetupCapture: AutomationControllerSetupCapture?
    private var liveFixtureEvidence: [AutomationLiveRecipeEvidence] = []
    private var latestFreshFixtureAttemptID: String?
    private let simulatorInventory: @Sendable (URL, URL) async throws -> [AutomationSimulator]
    private let physicalAliasReader: (@Sendable (URL, URL) async throws -> [String: String])?
    /// Explicit internal simulation seam; public construction always uses owned authority.
    private let nativeCodecResolver: (@Sendable (CapabilityProfile, AutomationPreparedApplication, AutomationCase) async throws -> CapabilityProfile)?
    public init(supportRoot: URL, developerDirectory: URL) throws {
        self.supportRoot = supportRoot; self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        simulatorInventory = { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) }
        physicalAliasReader = nil
        nativeCodecResolver = nil
    }
    init(supportRoot: URL, developerDirectory: URL,
         simulatorInventory: @escaping @Sendable (URL, URL) async throws -> [AutomationSimulator],
         nativeCodecResolver: (@Sendable (CapabilityProfile, AutomationPreparedApplication, AutomationCase) async throws -> CapabilityProfile)? = nil,
         physicalAliasReader: (@Sendable (URL, URL) async throws -> [String: String])? = nil) throws {
        let developer = try AutomationPath.canonical(developerDirectory)
        self.supportRoot = supportRoot; self.developerDirectory = developer
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        leases = manager
        self.simulatorInventory = simulatorInventory; self.nativeCodecResolver = nativeCodecResolver
        self.physicalAliasReader = physicalAliasReader

    }
    /// Resolve independently qualified codecs before a campaign's preflight.
    /// The runner repeats this verification before every actual attempt.
    public func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                         capabilities: CapabilityProfile) async throws -> CapabilityProfile {
        try await capabilitiesForExecution(subject: subject, plan: plan, capabilities: capabilities, approval: nil)
    }

    public func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                         capabilities: CapabilityProfile, approval: RunApproval?) async throws -> CapabilityProfile {
        try validatePreparedToolchain(subject.prepared)
        guard !running, !servingJavaScript, subject.app == plan.app, subject.target == plan.target else {
            throw AutomationContractError.invalidIdentity
        }
        running = true; defer { running = false }
        try subject.validate(plan: plan)
        if let prepared = subject.prepared, plan.target.kind == .physical {
            let resolved = try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared)
            return try await AutomationSiriCapabilitySnapshot.resolve(prepared: prepared, capabilities: resolved)
        }
        if let prepared = subject.prepared, plan.target.kind == .nativeMac {
            return try await qualifiedNativeCapabilities(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities)
        }
        guard let prepared = subject.prepared, plan.target.kind == .simulator else { return capabilities }
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
        return try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared,
            requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
    }

    /// Review a separate, bounded conversion-only probe before authorizing it.
    public func reviewNativeInputAdapters(prepared: AutomationPreparedApplication, actionID: String,
                                          parameterNames: [String]) throws -> AutomationNativeInputAdapterReview {
        try validatePreparedToolchain(prepared)
        return try AutomationNativeCodecQualification.review(.init(prepared: prepared, actionID: actionID, parameterNames: parameterNames))
    }
    /// Passing a reviewed probe digest authorizes this read-only calibration only.
    /// The selected action is never dispatched; only assigned input members are read.
    public func qualifyNativeInputAdapters(prepared: AutomationPreparedApplication, actionID: String, parameterNames: [String],
                                            reviewedProbeDigest: String, runID: String, attemptID: String) async throws -> AutomationNativeInputAdapterReport {
        try validatePreparedToolchain(prepared)
        guard !running, !servingJavaScript else { throw AutomationContractError.targetBusy }
        running = true; defer { running = false }
        return try await AutomationNativeCodecQualification.qualify(
            plan: .init(prepared: prepared, actionID: actionID, parameterNames: parameterNames), reviewedProbeDigest: reviewedProbeDigest,
            runID: runID, attemptID: attemptID, developer: developerDirectory, root: supportRoot, leases: leases)
    }

    private func resolveNativeCapabilities(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication,
                                           plan: AutomationCase) async throws -> CapabilityProfile {
        if let nativeCodecResolver { return try await nativeCodecResolver(capabilities, prepared, plan) }
        return try await AutomationNativeCodecAuthority.shared.enrich(capabilities, prepared: prepared, plan: plan,
            developer: developerDirectory, workspace: supportRoot)
    }

    /// Shared approved conversion path for direct Run and campaign preflight.
    private func qualifiedNativeCapabilities(prepared: AutomationPreparedApplication, plan: AutomationCase,
                                              approval: RunApproval?, capabilities: CapabilityProfile) async throws -> CapabilityProfile {
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        var nativeCapabilities = try await resolveNativeCapabilities(capabilities, prepared: prepared, plan: plan)
        guard let approval else { return nativeCapabilities }
        let allReviews = try AutomationNativeInputAdapterPlanning.reviews(plan: plan, prepared: prepared, capabilities: nativeCapabilities)
        let reviews = allReviews.filter { review in
            let action = prepared.catalog.systemActions.first { $0.id == review.actionID }
            return action?.parameters.contains { parameter in
                review.parameterNames.contains(parameter.name) && parameter.family.map { !nativeCapabilities.supports(["apple.codec." + $0]) } == true
            } == true
        }
        if !reviews.isEmpty {
            guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) else {
                throw AutomationContractError.missingEvidence("Review this exact workflow before checking its native input conversions")
            }
            try PlanValidator.validate(plan, approval: approval, capabilities: nativeCapabilities, purpose: .review)
            for review in reviews {
                try Task.checkCancellation()
                guard plan.nativeInputAdapterReviews?.filter({ $0.actionID == review.actionID }) == [review] else {
                    throw AutomationContractError.missingEvidence("Review the read-only parameter checks for this native workflow")
                }
                let calibration = try await AutomationNativeCodecQualification.qualify(
                    plan: .init(prepared: prepared, actionID: review.actionID, parameterNames: review.parameterNames),
                    reviewedProbeDigest: review.probeDigest, runID: approval.runID, attemptID: UUID().uuidString,
                    developer: developerDirectory, root: supportRoot, leases: leases)
                guard calibration.resourcesReleased, calibration.failure == nil else {
                    throw AutomationContractError.missingEvidence(calibration.failure ?? "Native parameter checks did not release their host")
                }
            }
            nativeCapabilities = try await resolveNativeCapabilities(nativeCapabilities, prepared: prepared, plan: plan)
        }
        try Task.checkCancellation()
        return nativeCapabilities
    }

    /// Calibrate a narrowly approved record-state workflow through actual Siri and
    /// independent before/after queries. Only direct released passing execution
    /// can create process-local routing authority for this exact frozen case.
    public func qualifySiriWorkflow(prepared: AutomationPreparedApplication, plan: AutomationCase,
                                    approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                                    allowInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil) async throws -> AutomationAttemptReport {
        try validatePreparedToolchain(prepared)
        guard !running, !servingJavaScript, allowInstall else { throw AutomationContractError.conflictingOperation }
        running = true; defer { running = false }
        let conversionOS = await AutomationPhysicalInputAdapterAuthority.shared.osBuild(prepared: prepared, plan: plan)
        guard plan.provenance["siri.repeatableReset"] == nil || conversionOS != nil else {
            throw AutomationContractError.missingEvidence("The exact physical reset conversion qualification has expired or is absent")
        }
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval, calibrationOSBuild: conversionOS)
        try await registerPhysicalAliases(plan.target)
        return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory,
            leases: leases, campaignBudget: campaignBudget, siriAuthority: authority)
    }

    public func qualifyPhysicalSiriResetInputs(prepared: AutomationPreparedApplication, baseline: AutomationCase, actionID: String,
                                               approval: RunApproval, capabilities: CapabilityProfile, attemptID: String, allowInstall: Bool) async throws -> AutomationPhysicalInputAdapterReport {
        guard !running, !servingJavaScript, allowInstall else { throw AutomationContractError.targetBusy }
        try validatePreparedToolchain(prepared)
        running = true; defer { running = false }
        return try await AutomationPhysicalInputAdapterQualification.run(prepared: prepared, baseline: baseline, actionID: actionID,
            approval: approval, capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory, leases: leases)
    }
    public func qualifiedPhysicalSiriResetCapabilities(prepared: AutomationPreparedApplication, baseline: AutomationCase, actionID: String,
                                                      approval: RunApproval, capabilities: CapabilityProfile) async throws -> CapabilityProfile {
        var review = capabilities
        if review.records["apple.intent.invoke"] == nil || review.records["apple.intent.invoke"]?.state == .unknown {
            review.records["apple.intent.invoke"] = .init(state: .available, reason: "Review-only compiled reset definition", probeVersion: "review-only", evidence: [])
        }
        let plan = try AutomationSiriRepeatableQualification.restoring(baseline, catalog: prepared.catalog, actionID: actionID,
            approval: approval, capabilities: review)
        return await AutomationPhysicalInputAdapterAuthority.shared.applying(prepared: prepared, plan: plan, capabilities: capabilities)
    }

    /// Runtime authority is looked up in the owned live registry, never restored from saved data.
    public func qualifiedSiriAuthority(prepared: AutomationPreparedApplication, plan: AutomationCase,
                                       approval: RunApproval) async -> AutomationSiriRouteAuthority? {
        await AutomationSiriQualificationAuthority.shared.admission(prepared: prepared, plan: plan, approval: approval)
    }

    public func runQualifiedSiriWorkflow(prepared: AutomationPreparedApplication, plan: AutomationCase,
                                        approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                                        authority: AutomationSiriRouteAuthority, campaignBudget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        guard !running, !servingJavaScript else { throw AutomationContractError.targetBusy }
        try validatePreparedToolchain(prepared)
        try AutomationSiriRepeatableQualification.validate(plan: plan, approval: approval, authority: authority)
        running = true; defer { running = false }
        guard let live = await qualifiedSiriAuthority(prepared: prepared, plan: plan, approval: approval),
              live.evidenceDigest == authority.evidenceDigest, live.isRepeatableQualification else {
            throw AutomationContractError.missingEvidence("The exact live Siri qualification has expired or was revoked")
        }
        try await registerPhysicalAliases(plan.target)
        return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, root: supportRoot, developer: developerDirectory,
            leases: leases, campaignBudget: campaignBudget, siriAuthority: live)
    }

    public func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        try await run(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID,
            allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget, fixtureTracker: fixtureTracker,
            qualifyingFreshBindings: qualifyingFreshBindings, uiRequestFixtureTracker: nil)
    }
    public func run(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil) async throws -> AutomationAttemptReport {
        try await run(subject: subject, plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID,
            allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget, fixtureTracker: fixtureTracker,
            qualifyingFreshBindings: qualifyingFreshBindings, uiRequestFixtureTracker: nil)
    }

    public func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil, uiRequestFixtureTracker: AutomationUIRequestFixtureTracker?) async throws -> AutomationAttemptReport {
        try await run(subject: .prepared(prepared), plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
            fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings, uiRequestFixtureTracker: uiRequestFixtureTracker)
    }
    public func run(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil, qualifyingFreshBindings: [AutomationFreshFixtureBinding]? = nil, uiRequestFixtureTracker: AutomationUIRequestFixtureTracker?) async throws -> AutomationAttemptReport {
        guard !running, !servingJavaScript else { throw AutomationContractError.targetBusy }
        try validatePreparedToolchain(subject.prepared)
        guard let prepared = subject.prepared, let profile = prepared.servedJavaScriptProfile else {
            guard subject.app.servedJavaScriptDigest == nil else { throw AutomationContractError.invalidIdentity }
            return try await runDirect(subject: subject, plan: plan, approval: approval, capabilities: capabilities,
                attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
                fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings,
                uiRequestFixtureTracker: uiRequestFixtureTracker)
        }
        guard let expected = prepared.servedJavaScriptIdentity, subject.app.servedJavaScriptDigest == (try expected.digest),
              subject.app == plan.app, subject.target == plan.target,
              let path = prepared.servedJavaScriptFrozenRootPath, path.hasPrefix(supportRoot.path + "/"),
              prepared.generatedHost.projectPath.hasPrefix(path + "/"),
              try AutomationPath.canonical(URL(fileURLWithPath: path)).path == path else { throw AutomationContractError.invalidIdentity }
        servingJavaScript = true; defer { servingJavaScript = false }
        try subject.validate(plan: plan)
        var qualifiedCapabilities = capabilities
        let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
        qualifiedCapabilities = try await AutomationSimulatorCodecQualification.enrich(qualifiedCapabilities, prepared: prepared,
            requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
        try PlanValidator.validate(plan, approval: approval, capabilities: qualifiedCapabilities)
        let executionCapabilities = qualifiedCapabilities
        let supervisor = AutomationServedJavaScriptSupervisor()
        return try await supervisor.withSession(profile: profile, manifest: prepared.source,
            app: subject.app, target: subject.target, frozenRoot: URL(fileURLWithPath: path), developerDirectory: developerDirectory,
            supportRoot: supportRoot, expected: expected,
            requiresNativeConsumer: profile.automaticMetro != nil && (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains(where: \.usesUIControl)) { _ in
                try await self.runDirect(subject: subject, plan: plan, approval: approval, capabilities: executionCapabilities,
                    attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
                    fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings,
                    uiRequestFixtureTracker: uiRequestFixtureTracker,
                    javaScriptFinalization: { try await supervisor.finishCurrent(profile: profile, manifest: prepared.source, frozenRoot: URL(fileURLWithPath: path)) },
                    javaScriptResponseEvidence: { await supervisor.responseEvidence() }, codecsQualified: true)
            }
    }
    private func validatePreparedToolchain(_ prepared: AutomationPreparedApplication?) throws {
        if let path = prepared?.selectedDeveloperDirectoryPath, path != developerDirectory.path {
            throw AutomationContractError.missingEvidence("Use the Xcode toolchain selected for this prepared copy (" + path + "), then review the run again.")
        }
    }
    private func runDirect(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget?,
                    fixtureTracker: AutomationFreshFixtureTracker?, qualifyingFreshBindings: [AutomationFreshFixtureBinding]?, uiRequestFixtureTracker: AutomationUIRequestFixtureTracker?,
                    javaScriptFinalization: (@Sendable () async throws -> Void)? = nil,
                    javaScriptResponseEvidence: (@Sendable () async -> [String: String]?)? = nil, codecsQualified: Bool = false) async throws -> AutomationAttemptReport {
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
        if plan.target.kind == .nativeMac, !codecsQualified {
            capabilities = try await qualifiedNativeCapabilities(prepared: prepared, plan: plan,
                approval: approval, capabilities: capabilities)
        } else if plan.target.kind == .simulator, !codecsQualified {
            let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
            capabilities = try await AutomationSimulatorCodecQualification.enrich(capabilities, prepared: prepared,
                requiredCapabilities: required, developerDirectory: developerDirectory, workspace: supportRoot)
        }
        guard fixtureTracker == nil || qualifyingFreshBindings == nil else { throw AutomationContractError.missingEvidence("Fresh query fixtures require their qualified associated host") }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard segments.allSatisfy({ [.ui, .observeOnly, .systemIntent, .systemQuery, .storageRead].contains($0.kind) }) else {
            throw AutomationContractError.missingEvidence("Prepared-app route is not qualified")
        }
        let needsUI = segments.contains { $0.usesUIControl }
        if needsUI || plan.target.kind != .simulator {
            _ = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
                attemptID: attemptID, leaseGeneration: 1)
            guard uiRequestFixtureTracker == nil else {
                throw AutomationContractError.missingEvidence("Repeated UI sessions require an explicit host reset contract")
            }
        }
        let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
            catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
            localeIdentifier: plan.provenance["ui.locale"] ?? "", uiRuntimeManifestDigest: nil)
        if let fixtureTracker { try await fixtureTracker.preflight(context: context, plan: plan, approval: approval) }
        let qualificationFence = try qualifyingFreshBindings.map {
            try AutomationFreshFixtureQualificationFence(bindings: $0, plan: plan, approval: approval,
                capabilities: capabilities, context: context, previous: liveFixtureEvidence)
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
                fixtureTracker: fixtureTracker, qualificationFence: qualificationFence, uiRequestFixtureTracker: uiRequestFixtureTracker)
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
        if let javaScriptFinalization {
            report = await AutomationServedJavaScriptReportFinalization.finish(report, operation: javaScriptFinalization)
            if report.resourcesReleased, let javaScriptResponseEvidence { report.servedJavaScriptResponses = await javaScriptResponseEvidence() }
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
    /// Alias observation affects lease comparisons only; approved targets stay unchanged.
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
    public func retainedAttempt(attemptID: String, plan: AutomationCase, runID: String) throws -> AutomationAttemptReport? {
        guard let failure = failedPreparation, failure.attemptID == attemptID,
              failure.planDigest == (try AutomationFrozenCase.planDigest(plan)), failure.runID == runID else { return nil }
        try AutomationRecordedEvidence.validate(report: failure.report, plan: plan, expectedRunID: runID)
        return failure.report
    }
    public func captureFreshSetup(bindings: [AutomationFreshFixtureBinding]) throws -> AutomationCapturedSetupAttempt {
        guard !running, !servingJavaScript, let live = liveFixtureEvidence.last, let capture = lastSetupCapture else {
            throw AutomationContractError.missingEvidence("No released complete live setup trace")
        }
        return try .init(live: live, capture: capture, bindings: bindings)
    }
    public func qualifyRecipe(_ candidate: AutomationSetupRecipeCandidate) throws -> AutomationQualifiedSetupRecipe {
        guard !running, !servingJavaScript, let liveRecipeEvidence else { throw AutomationContractError.missingEvidence("No complete live recipe qualification in this runner") }
        return try .init(candidate: candidate, live: liveRecipeEvidence)
    }
    public func qualifyFreshFixture(bindings: [AutomationFreshFixtureBinding]) throws -> AutomationQualifiedFreshFixture {
        guard !running, !servingJavaScript else { throw AutomationContractError.targetBusy }
        guard latestFreshFixtureAttemptID == liveFixtureEvidence.last?.report.attemptID,
              latestFreshFixtureAttemptID != nil else { throw AutomationContractError.missingEvidence("No eligible latest live fixture attempt") }
        return try .init(bindings: bindings, evidence: Array(liveFixtureEvidence.suffix(2)))
    }
    public func validateFreshFixtureAttempt(bindings: [AutomationFreshFixtureBinding]) throws {
        guard !running, !servingJavaScript, let live = liveFixtureEvidence.last, latestFreshFixtureAttemptID == live.report.attemptID else {
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
