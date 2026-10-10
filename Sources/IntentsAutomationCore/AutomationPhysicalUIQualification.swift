#if os(macOS)
import Foundation

/// Physical composition under the existing campaign authority. The public product
/// constructor keeps this route unavailable until actual hardware qualification.
actor AutomationPhysicalUIQualification {
    struct Preparation: Sendable {
        let subject: AutomationPhysicalInstalledUIApplication
        let installation: AutomationPhysicalInstallationReceipt
    }
    struct DriverContext: Sendable {
        let runtime: AutomationUIRuntime
        let state: URL
        let approval: RunApproval
        let leases: AutomationDeviceLeaseManager
        let artifacts: AutomationArtifactRegistry
        let developerDirectory: URL
        let campaignBudget: AutomationCampaignBudget?
    }
    struct Dependencies: Sendable {
        var runtimeDigest: @Sendable (AutomationUIRuntime, URL) throws -> String
        var installer: @Sendable (URL, URL) throws -> AutomationPhysicalApplicationInstaller
        var subject: @Sendable (AutomationPhysicalInstalledUIApplication, URL, URL) throws -> AutomationPhysicalInstalledSubjectVerifier
        var release: @Sendable (URL, URL) throws -> AutomationPhysicalDeviceReleaseVerifier
        var driver: @Sendable (DriverContext, AutomationPhysicalInstalledSubjectVerifier, AutomationPhysicalDeviceReleaseVerifier) throws -> any AutomationRouteDriver
        static let owned = Self(runtimeDigest: { runtime, state in
            _ = try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: runtime.bundleURL,
                stateDirectory: state, expectedTeamID: runtime.expectedTeamID)
            return AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: runtime.bundleURL,
                relativePath: "Contents/Resources/Automation/runtime-manifest.json", maximumBytes: 4_194_304))
        }, installer: { try .init(workspace: $0, developerDirectory: $1) },
           subject: { try .init(selected: $0, workspace: $1, developerDirectory: $2) },
           release: { try .init(workspace: $0, developerDirectory: $1, controllers: controllers) },
           driver: { context, subject, release in
            try AutomationSidecarRouteDriver(bundleURL: context.runtime.bundleURL, expectedTeamID: context.runtime.expectedTeamID,
                stateDirectory: context.state, approval: context.approval, leases: context.leases, artifacts: context.artifacts,
                subjectVerifier: subject, releaseVerifier: release, campaignBudget: context.campaignBudget,
                developerDirectory: context.developerDirectory, controllerBundleIDs: controllers.map(\.bundleID))
        })
    }
    // Names from the pinned agent-device 0.21.20 AgentDeviceRunner target graph.
    static let controllers = [
        AutomationPhysicalRunnerVerifier.Controller(bundleID: "com.callstack.agentdevice.runner", executableName: "AgentDeviceRunner"),
        AutomationPhysicalRunnerVerifier.Controller(bundleID: "com.callstack.agentdevice.runner.uitests.xctrunner", executableName: "AgentDeviceRunnerUITests-Runner")
    ]
    private let root: URL
    private let developer: URL
    private let leases: AutomationDeviceLeaseManager
    private let dependencies: Dependencies
    private var busy = false
    init(root: URL, developerDirectory: URL, leases: AutomationDeviceLeaseManager, dependencies: Dependencies) {
        self.root = root; developer = developerDirectory; self.leases = leases; self.dependencies = dependencies
    }
    func prepare(selected: AutomationInstalledUIApplication, approval: RunApproval, attemptID: String,
                 allowInstall: Bool, campaignBudget: AutomationCampaignBudget?) async throws -> Preparation {
        guard !busy, allowInstall, approval.disposable, approval.maximumActions > 0,
              approval.app == selected.app, approval.target == selected.target,
              validAttempt(attemptID) else { throw AutomationContractError.invalidIdentity }
        try AutomationPhysicalExecutable.validateTarget(selected.target); try selected.verifySelectedProduct()
        try Task.checkCancellation()
        try await campaignBudget?.reserveOperations(id: attemptID + ".prepare.install", phase: .setup, count: 1)
        busy = true; defer { busy = false }
        let state = try newDirectory("physical-preparation-" + attemptID)
        let journal = try AutomationJournal(url: state.appendingPathComponent("journal.json"))
        let release = try dependencies.release(state, developer)
        let installer = try dependencies.installer(state, developer)
        var lease: AutomationDeviceLeaseManager.Lease?
        try await leases.reserveCampaign(runID: approval.runID, target: approval.target)
        do {
            lease = try await leases.acquire(runID: approval.runID, target: approval.target, control: .system)
            let held = lease!
            let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: "prepare.install", leaseGeneration: held.generation)
            try await release.prepare(target: selected.target, controllerBundleIDs: Self.controllers.map(\.bundleID))
            let device = try await release.preparedDevice(target: selected.target)
            let receipt = try await installer.install(selected: selected, approval: approval, lease: held, scope: scope,
                leases: leases, journal: journal, allowInstall: allowInstall, expectedDeviceIdentifier: device, campaignBudget: campaignBudget)
            guard receipt.scope == scope, receipt.app == selected.app, receipt.target == selected.target,
                  receipt.developerDirectory == developer.path, !receipt.installedBytesVerified else { throw AutomationContractError.conflictingOperation }
            let installed = try AutomationPhysicalInstalledUIApplication(installation: receipt, selected: selected)
            let (drained, released) = await Task.detached {
                let drained = await installer.drain()
                let released = await release.verifyReleased(target: selected.target, controllerBundleIDs: Self.controllers.map(\.bundleID))
                return (drained, released)
            }.value
            try await leases.release(held, commandsDrained: drained, ownedRunnerTerminated: released)
            lease = nil
            try await leases.releaseCampaign(runID: approval.runID, target: approval.target)
            return .init(subject: installed, installation: receipt)
        } catch {
            let (drained, released) = await Task.detached {
                let drained = await installer.drain()
                let released = await release.verifyReleased(target: selected.target, controllerBundleIDs: Self.controllers.map(\.bundleID))
                return (drained, released)
            }.value
            if let held = lease { try? await leases.release(held, commandsDrained: drained, ownedRunnerTerminated: released) }
            if drained && released { try? await leases.releaseCampaign(runID: approval.runID, target: approval.target) }
            let outcome: AutomationJSON = .object(["subjectDispatched": .bool(false), "installedBytesVerified": .bool(false),
                "commandsDrained": .bool(drained), "controllersAbsent": .bool(released)])
            try? persist(JSONEncoder().encode(outcome), state.appendingPathComponent("failure.json"))
            throw error
        }
    }
    func run(selected: AutomationPhysicalInstalledUIApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, runtime: AutomationUIRuntime,
             campaignBudget: AutomationCampaignBudget?) async throws -> AutomationAttemptReport {
        guard !busy, validAttempt(attemptID), selected.app == plan.app, selected.target == plan.target else { throw AutomationContractError.invalidIdentity }
        try AutomationApplicationSubject.installedPhysicalUI(selected).validate(plan: plan)
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let digest = try dependencies.runtimeDigest(runtime, root.appendingPathComponent(attemptID).appendingPathComponent("ui"))
        guard plan.provenance["ui.runtimeManifestDigest"].map({ $0 == digest }) ?? true,
              plan.provenance["ui.runtimeTeamID"].map({ $0 == runtime.expectedTeamID }) ?? true else { throw AutomationContractError.conflictingOperation }
        busy = true; defer { busy = false }
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases")), frozen = try await cases.freeze(plan)
        let state = try newDirectory(attemptID)
        let journal = try AutomationJournal(url: state.appendingPathComponent("journal.json"))
        let artifacts = try AutomationArtifactRegistry(root: state.appendingPathComponent("artifacts"), secretEvidenceRoot: root.appendingPathComponent("secret-evidence"))
        let subject = try dependencies.subject(selected, state, developer)
        let release = try dependencies.release(state, developer)
        try await release.bindDevice(selected.deviceIdentifier)
        var executionStarted = false
        do {
            try await leases.reserveCampaign(runID: approval.runID, target: approval.target)
            let context = DriverContext(runtime: runtime, state: state.appendingPathComponent("ui"), approval: approval,
                leases: leases, artifacts: artifacts, developerDirectory: developer, campaignBudget: campaignBudget)
            let driver = try dependencies.driver(context, subject, release)
            executionStarted = true
            let report = try await AutomationCoordinator(leases: leases, journal: journal).run(plan: plan, approval: approval,
                capabilities: capabilities, attemptID: attemptID, driver: driver)
            try persist(JSONEncoder().encode(report), state.appendingPathComponent("report.json"))
            try await cases.saveAttempt(report, for: frozen)
            return report
        } catch {
            if executionStarted { throw error }
            let drained = await subject.drain()
            if drained { try? await leases.releaseCampaign(runID: approval.runID, target: approval.target) }
            let absent = (try? await leases.campaignAbsent(target: approval.target)) == true
            let report = AutomationAttemptReport(attemptID: attemptID,
                result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false,
                    subjectCompleted: false, observations: [], termination: drained && absent ? .infrastructureFailed : .unresolved),
                receipts: [], resourcesReleased: drained && absent)
            do {
                try persist(JSONEncoder().encode(report), state.appendingPathComponent("report.json"))
                try await cases.saveAttempt(report, for: frozen)
            } catch let persistenceError {
                throw AutomationPreparationPersistenceFailure(preparationError: error, persistenceError: persistenceError)
            }
            return report
        }
    }
    private func validAttempt(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil }
    private func newDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func persist(_ data: Data, _ url: URL) throws {
        let file = try AutomationDurableFile(url: url, maximumBytes: 16_777_216)
        try file.withLock { try file.write(data) }
    }
}
#endif
