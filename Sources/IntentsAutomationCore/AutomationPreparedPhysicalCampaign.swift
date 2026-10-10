#if os(macOS)
import Foundation

/// Correlates selected local bytes with acknowledged installation and bundle presence.
/// Remote bytes remain unreadable; this path is ineligible for exact-build comparisons.
struct AutomationPreparedPhysicalSubjectVerifier: AutomationSubjectVerifier {
    let selected: AutomationInstalledUIApplication
    let installed: AutomationPhysicalInstalledUIApplication
    let verifier: AutomationPhysicalInstalledSubjectVerifier
    func verify(app: AppIdentity, target: TargetIdentity) async throws {
        guard app == selected.app, target == selected.target, target == installed.target,
              app.bundleID == installed.app.bundleID else { throw AutomationContractError.invalidIdentity }
        try selected.verifySelectedProduct()
        try await verifier.verify(app: installed.app, target: installed.target)
    }
}

/// Every segment checks all campaign controllers, including the generated Apple runner.
/// This avoids transferring the device while a different interface still owns a controller.
actor AutomationPhysicalCampaignRelease: AutomationDeviceReleaseVerifier {
    let verifier: AutomationPhysicalDeviceReleaseVerifier
    let identifiers: [String]
    init(verifier: AutomationPhysicalDeviceReleaseVerifier, identifiers: [String]) { self.verifier = verifier; self.identifiers = identifiers }
    func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {
        guard Set(controllerBundleIDs).isSubset(of: Set(identifiers)), Set(controllerBundleIDs).count == controllerBundleIDs.count else { throw AutomationContractError.invalidIdentity }
        try await verifier.prepare(target: target, controllerBundleIDs: identifiers)
    }
    func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
        guard Set(controllerBundleIDs).isSubset(of: Set(identifiers)), Set(controllerBundleIDs).count == controllerBundleIDs.count else { return false }
        return await verifier.verifyReleased(target: target, controllerBundleIDs: identifiers)
    }
}

enum AutomationPreparedPhysicalCampaign {
    struct Components: Sendable {
        var deviceRelease: @Sendable (URL, URL, [AutomationPhysicalRunnerVerifier.Controller]) throws -> AutomationPhysicalDeviceReleaseVerifier
        var installer: @Sendable (URL, URL) throws -> AutomationPhysicalApplicationInstaller
        static let owned = Components(
            deviceRelease: { try AutomationPhysicalDeviceReleaseVerifier(workspace: $0, developerDirectory: $1, controllers: $2) },
            installer: { try AutomationPhysicalApplicationInstaller(workspace: $0, developerDirectory: $1) })
    }
    static func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                    capabilities: CapabilityProfile, attemptID: String, root: URL, developer: URL,
                    leases: AutomationDeviceLeaseManager, runtime: AutomationUIRuntime?,
                    campaignBudget: AutomationCampaignBudget?, siriAuthority: AutomationSiriRouteAuthority? = nil,
                    components: Components = .owned) async throws -> AutomationAttemptReport {
        guard attemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil,
              plan.app == prepared.host.app, plan.target == prepared.host.target, plan.target.kind == .physical,
              prepared.generatedHost.includesSiri == true, approval.disposable else { throw AutomationContractError.invalidIdentity }
        var authority = siriAuthority
        if authority == nil { authority = await AutomationSiriQualificationAuthority.shared.admission(prepared: prepared, plan: plan, approval: approval) }
        let capabilities = try await AutomationSiriCapabilitySnapshot.resolve(prepared: prepared, capabilities: capabilities,
            plan: plan, approval: approval, authority: authority)
        guard await AutomationPreparedCodecAuthority.shared.contains(prepared) else { throw AutomationContractError.missingEvidence("Prepare the exact physical host in this process before running") }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: authority)
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard segments.allSatisfy({ [.ui, .systemIntent, .systemQuery, .siriText].contains($0.kind) }),
              segments.filter({ $0.kind == .siriText }).allSatisfy({ $0.id == plan.execution.id }) else { throw AutomationContractError.invalidPlan("Siri may run only as the frozen subject") }
        let needsUI = segments.contains { $0.kind == .ui }
        guard !needsUI || runtime != nil else { throw AutomationContractError.missingEvidence("Mixed physical checks require the signed UI runtime") }
        let selected = try AutomationInstalledUIApplication.preparedPhysicalProduct(prepared)
        let state = root.appendingPathComponent(attemptID)
        guard !FileManager.default.fileExists(atPath: state.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let runtime {
            _ = try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: runtime.bundleURL,
                stateDirectory: state.appendingPathComponent("ui"), expectedTeamID: runtime.expectedTeamID)
            let digest = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: runtime.bundleURL,
                relativePath: "Contents/Resources/Automation/runtime-manifest.json", maximumBytes: 4_194_304))
            guard plan.provenance["ui.runtimeManifestDigest"].map({ $0 == digest }) ?? true,
                  plan.provenance["ui.runtimeTeamID"].map({ $0 == runtime.expectedTeamID }) ?? true else { throw AutomationContractError.conflictingOperation }
        } else {
            guard plan.provenance["ui.runtimeManifestDigest"] == nil, plan.provenance["ui.runtimeTeamID"] == nil else { throw AutomationContractError.conflictingOperation }
        }
        let journal = try AutomationJournal(url: state.appendingPathComponent("journal.json"))
        let artifacts = try AutomationArtifactRegistry(root: state.appendingPathComponent("artifacts"), secretEvidenceRoot: root.appendingPathComponent("secret-evidence"))
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases")), frozen = try await cases.freeze(plan)
        let info = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(root: URL(fileURLWithPath: prepared.host.hostBundlePath), relativePath: "Info.plist", maximumBytes: 1_048_576), format: nil) as? [String: Any]
        guard let executable = info?["CFBundleExecutable"] as? String else { throw AutomationContractError.invalidIdentity }
        var controllers = [AutomationPhysicalRunnerVerifier.Controller(bundleID: prepared.host.hostBundleID, executableName: executable)]
        if needsUI { controllers += AutomationPhysicalUIQualification.controllers }
        let deviceRelease = try components.deviceRelease(state, developer, controllers)
        let release = AutomationPhysicalCampaignRelease(verifier: deviceRelease, identifiers: controllers.map(\.bundleID))
        let installer = try components.installer(state, developer)
        var held: AutomationDeviceLeaseManager.Lease?
        var executionStarted = false
        try await leases.reserveCampaign(runID: approval.runID, target: plan.target)
        do {
            let lease = try await leases.acquire(runID: approval.runID, target: plan.target, control: .system); held = lease
            let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: "prepare.install", leaseGeneration: lease.generation)
            try await release.prepare(target: plan.target, controllerBundleIDs: [])
            let device = try await deviceRelease.preparedDevice(target: plan.target)
            try await campaignBudget?.reserveOperations(id: attemptID + ".prepare.install", phase: .setup, count: 1)
            let installation = try await installer.install(selected: selected, approval: approval, lease: lease, scope: scope,
                leases: leases, journal: journal, allowInstall: true, expectedDeviceIdentifier: device, campaignBudget: campaignBudget)
            try persist(JSONEncoder().encode(installation), state.appendingPathComponent("owned-installation.json"))
            let installed = try AutomationPhysicalInstalledUIApplication(installation: installation, selected: selected)
            try await deviceRelease.bindDevice(installed.deviceIdentifier)
            let drained = await installer.drain()
            let absent = await release.verifyReleased(target: plan.target, controllerBundleIDs: [])
            try await leases.release(lease, commandsDrained: drained, ownedRunnerTerminated: absent); held = nil
            let positive = try AutomationPhysicalInstalledSubjectVerifier(selected: installed, workspace: state, developerDirectory: developer)
            let subject = AutomationPreparedPhysicalSubjectVerifier(selected: selected, installed: installed, verifier: positive)
            let apple = try AutomationAppleRouteDriver(prepared: prepared.host, approval: approval, developerDirectory: developer,
                stateDirectory: state.appendingPathComponent("apple"), leases: leases, artifacts: artifacts,
                subjectVerifier: subject, releaseVerifier: release, campaignBudget: campaignBudget, capabilities: capabilities, siriAuthority: authority)
            let siri = try AutomationSiriRouteDriver(prepared: prepared, approval: approval, capabilities: capabilities,
                developerDirectory: developer, stateDirectory: state.appendingPathComponent("siri"), leases: leases,
                artifacts: artifacts, subjectVerifier: subject, releaseVerifier: release, campaignBudget: campaignBudget, siriAuthority: authority)
            let driver: any AutomationRouteDriver
            if needsUI, let runtime {
                let ui = try AutomationSidecarRouteDriver(bundleURL: runtime.bundleURL, expectedTeamID: runtime.expectedTeamID,
                    stateDirectory: state.appendingPathComponent("ui"), approval: approval, leases: leases, artifacts: artifacts,
                    subjectVerifier: subject, releaseVerifier: release, campaignBudget: campaignBudget, developerDirectory: developer,
                    controllerBundleIDs: AutomationPhysicalUIQualification.controllers.map(\.bundleID))
                driver = AutomationMixedRouteDriver(ui: ui, apple: apple, siri: siri)
            } else { driver = AutomationMixedRouteDriver(ui: apple, apple: apple, siri: siri) }
            executionStarted = true
            let report = try await AutomationCoordinator(leases: leases, journal: journal).run(plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, driver: driver, siriAuthority: authority)
            try persist(JSONEncoder().encode(report), state.appendingPathComponent("report.json"))
            try await cases.saveAttempt(report, for: frozen)
            if report.result.summary != .passed {
                await AutomationSiriQualificationAuthority.shared.revoke(prepared: prepared, plan: plan)
            }
            if authority?.isQualification == true, report.result.summary == .passed,
               let submission = await siri.qualificationSubmission() {
                try await AutomationSiriQualificationAuthority.shared.record(prepared: prepared, plan: plan,
                    approval: approval, report: report, submission: submission)
            }
            return report
        } catch {
            await AutomationSiriQualificationAuthority.shared.revoke(prepared: prepared, plan: plan)
            if executionStarted { throw error }
            let drained = await installer.drain()
            let absent = await release.verifyReleased(target: plan.target, controllerBundleIDs: [])
            var released = drained && absent
            if let held {
                do { try await leases.release(held, commandsDrained: drained, ownedRunnerTerminated: absent) }
                catch { released = false }
            }
            if released { do { try await leases.releaseCampaign(runID: approval.runID, target: plan.target) } catch { released = false } }
            let report = AutomationAttemptReport(attemptID: attemptID,
                result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false, subjectCompleted: false,
                    observations: [], termination: released ? .infrastructureFailed : .unresolved), receipts: [], resourcesReleased: released)
            do { try persist(JSONEncoder().encode(report), state.appendingPathComponent("report.json")); try await cases.saveAttempt(report, for: frozen) }
            catch let persistence { throw AutomationPreparationPersistenceFailure(preparationError: error, persistenceError: persistence) }
            return report
        }
    }
    private static func persist(_ data: Data, _ url: URL) throws {
        let file = try AutomationDurableFile(url: url, maximumBytes: 16_777_216)
        try file.withLock { try file.write(data) }
    }
}
#endif
