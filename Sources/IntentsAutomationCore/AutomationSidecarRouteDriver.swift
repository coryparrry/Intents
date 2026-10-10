#if os(macOS)
import Foundation

/// Process surface the UI route driver controls; the packaged child process is the production conformer.
protocol AutomationSidecarRouteProcess: Sendable {
    var rpc: AutomationRPC { get async }
    var processIdentity: AutomationProcessIdentity? { get async }
    func start() async throws
    func handshake() async throws -> AutomationJSON
    func stop() async -> Bool
}
extension AutomationSidecarProcess: AutomationSidecarRouteProcess {}

struct AutomationSidecarRouteLauncher: Sendable {
    var configure: @Sendable (_ bundleURL: URL, _ stateDirectory: URL, _ teamID: String, _ developerDirectory: URL?) throws -> AutomationSidecarProcess.Configuration
    var spawn: @Sendable (AutomationSidecarProcess.Configuration, @escaping AutomationRPC.ReverseHandler) throws -> any AutomationSidecarRouteProcess
    static let packaged = Self(
        configure: { try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: $0, stateDirectory: $1, expectedTeamID: $2, developerDirectory: $3) },
        spawn: { try AutomationSidecarProcess(configuration: $0, reverse: $1) })
}

/// Concrete native UI driver. The native coordinator retains assertions and verdicts.
public actor AutomationSidecarRouteDriver: AutomationRouteDriver {
    private struct Control: Sendable {
        var scope: AutomationScope
        var lease: AutomationDeviceLeaseManager.Lease
        var segment: AutomationSegment
        var process: any AutomationSidecarRouteProcess
        var executing = false
        var acquired = false
    }
    private let bundleURL: URL
    private let teamID: String
    private let root: URL
    private let approval: RunApproval
    private let leases: AutomationDeviceLeaseManager
    private let campaignBudget: AutomationCampaignBudget?
    private let authority: AutomationRunAuthority
    private let artifacts: AutomationArtifactRegistry
    private let subjectVerifier: any AutomationSubjectVerifier
    private let releaseVerifier: any AutomationDeviceReleaseVerifier
    private let developerDirectory: URL?
    private let controllerBundleIDs: [String]
    private let launcher: AutomationSidecarRouteLauncher
    private var control: Control?
    private var releasing = false
    private var acquiringScope: AutomationScope?
    private var revokedGenerations: Set<Int> = []
    private var subjectInspectionUnreleased = false
    private var releaseDiagnosticCount = 0
    private var pendingSetupCapture: AutomationControllerSetupCapture?
    private var releasedSetupCaptures: [AutomationControllerSetupCapture] = []
    public init(bundleURL: URL, expectedTeamID: String, stateDirectory: URL, approval: RunApproval,
                leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, subjectVerifier: any AutomationSubjectVerifier, releaseVerifier: any AutomationDeviceReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil,
                developerDirectory: URL? = nil, controllerBundleIDs: [String] = []) throws {
        try self.init(bundleURL: bundleURL, expectedTeamID: expectedTeamID, stateDirectory: stateDirectory, approval: approval, leases: leases, artifacts: artifacts,
                      subjectVerifier: subjectVerifier, releaseVerifier: releaseVerifier, campaignBudget: campaignBudget, developerDirectory: developerDirectory,
                      controllerBundleIDs: controllerBundleIDs, launcher: .packaged)
    }
    init(bundleURL: URL, expectedTeamID: String, stateDirectory: URL, approval: RunApproval,
         leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, subjectVerifier: any AutomationSubjectVerifier, releaseVerifier: any AutomationDeviceReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil,
         developerDirectory: URL? = nil, controllerBundleIDs: [String] = [], launcher: AutomationSidecarRouteLauncher) throws {
        guard !approval.runID.isEmpty else { throw AutomationContractError.invalidIdentity }
        try Self.validateControllerScope(target: approval.target, bundleIDs: controllerBundleIDs, developerDirectory: developerDirectory)
        let selectedDeveloper = try developerDirectory.map(AutomationPath.canonical)
        if let selectedDeveloper {
            guard try FileManager.default.attributesOfItem(atPath: selectedDeveloper.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw AutomationContractError.invalidIdentity
            }
        }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.bundleURL = try AutomationPath.canonical(bundleURL); teamID = expectedTeamID
        root = try AutomationPath.canonical(stateDirectory); self.approval = approval; self.leases = leases; self.artifacts = artifacts
        self.campaignBudget = campaignBudget
        authority = AutomationRunAuthority(approval: approval, leases: leases, artifacts: artifacts, campaignBudget: campaignBudget)
        self.subjectVerifier = subjectVerifier; self.releaseVerifier = releaseVerifier
        self.developerDirectory = selectedDeveloper
        self.controllerBundleIDs = controllerBundleIDs
        self.launcher = launcher
    }
    public func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws {
        guard control == nil, acquiringScope == nil, !releasing, !revokedGenerations.contains(lease.generation),
              segment.kind == .ui, lease.control == .ui, lease.target == approval.target, lease.runID == approval.runID,
              scope.runId == approval.runID, scope.leaseGeneration == lease.generation, scope.segmentId == segment.id, segment.lifecycle == .persistedStateAcrossSegments,
              plan.app == approval.app, plan.target == approval.target, plan.environmentID == approval.environmentID,
              let program = segment.uiProgram else { throw AutomationContractError.invalidPlan("No frozen UI program for this route") }
        try program.validate(phase: segment.phase)
        _ = try program.payload(scope: scope, phase: segment.phase, operationID: "\(scope.attemptId):\(scope.segmentId)")
        acquiringScope = scope; defer { if acquiringScope == scope { acquiringScope = nil } }
        try await verifySubject(plan)
        do { try await releaseVerifier.prepare(target: plan.target, controllerBundleIDs: controllerBundleIDs) }
        catch {
            if error as? AutomationContractError == .terminationUnverified { subjectInspectionUnreleased = true }
            throw error
        }
        guard acquiringScope == scope, !revokedGenerations.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        let directory = root.appendingPathComponent("control-\(lease.generation)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
        let configuration = try launcher.configure(bundleURL, directory, teamID, developerDirectory)
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: program.approvedActions(), maximumControllerCalls: plan.budget.controllerCalls, maximumUIActions: plan.budget.uiActions)
        let approvedLeaseCurrent = await leases.isCurrent(lease)
        guard approvedLeaseCurrent, !revokedGenerations.contains(lease.generation), acquiringScope == scope else {
            try? await authority.revoke(scope: scope); throw AutomationContractError.unknownLease
        }
        let authority = self.authority
        let process = try launcher.spawn(configuration, { method, input in
            await authority.review(method: method, params: input)
        })
        control = .init(scope: scope, lease: lease, segment: segment, process: process)
        try await process.start(); _ = try await process.handshake()
        guard let identity = await process.processIdentity else { throw AutomationContractError.invalidIdentity }
        try await leases.recordRunner(.init(scope: scope, process: identity, role: .sidecar, executablePath: configuration.node.path), lease: lease)
        let acquiredLeaseCurrent = await leases.isCurrent(lease)
        guard acquiredLeaseCurrent, !releasing, !revokedGenerations.contains(lease.generation), control?.scope == scope else { throw AutomationContractError.unknownLease }
        let target: AutomationJSON = .object(["id": .string(plan.target.id), "kind": .string(plan.target.kind.rawValue),
            "platform": .string(plan.target.kind == .nativeMac ? "macos" : "ios"), "bundleId": .string(plan.app.bundleID),
            "bundlePath": plan.target.kind == .nativeMac ? plan.app.canonicalBundlePath.map(AutomationJSON.string) ?? .null : .null,
            "loginSession": plan.target.loginSession.map(AutomationJSON.string) ?? .null])
        _ = try await process.rpc.request(.acquire, params: .object(["scope": try scopeJSON(scope), "target": target,
            "lifecycle": .string(segment.lifecycle.rawValue)]), timeout: .seconds(120))
        guard control?.scope == scope, !releasing, !revokedGenerations.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        control?.acquired = true
    }
    public func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard let active = control, active.scope == scope, active.lease == lease, active.segment == segment,
              active.acquired, !active.executing, !releasing, let program = segment.uiProgram,
              plan.app == approval.app, plan.target == approval.target, plan.environmentID == approval.environmentID else {
            throw AutomationContractError.unknownLease
        }
        let current = await leases.isCurrent(lease)
        guard current, control?.scope == scope, control?.segment == segment, control?.executing == false,
              !releasing, !revokedGenerations.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        control?.executing = true
        defer { if control?.scope == scope { control?.executing = false } }
        try await verifySubject(plan)
        guard control?.scope == scope, !releasing, !revokedGenerations.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        let operationID = "\(scope.attemptId):\(scope.segmentId)"
        let payload = try program.payload(scope: scope, phase: segment.phase, operationID: operationID)
        let remaining = try await campaignBudget?.remainingDuration() ?? .milliseconds(program.timeoutMilliseconds + 5_000)
        let receipt = try await active.process.rpc.request(.runSegment, params: payload, timeout: min(remaining, .milliseconds(program.timeoutMilliseconds + 5_000)))
        try await campaignBudget?.available()
        try await verifySubject(plan)
        guard let fields = receipt.object, Set(fields.keys) == ["schemaVersion", "scope", "operationId", "complete", "outputs"],
              fields["schemaVersion"] == .number(1), fields["scope"] == (try scopeJSON(scope)),
              fields["operationId"] == .string(operationID), fields["complete"] == .bool(true), let outputs = fields["outputs"]?.object else {
            throw AutomationContractError.ambiguousDispatch
        }
        let expectedOutputs = Set(program.operations.filter { [.readProperty, .locate, .observeProperty].contains($0.kind) }.map(\.id))
        guard Set(outputs.keys) == expectedOutputs else { throw AutomationContractError.missingEvidence("UI output scope mismatch") }
        let (verified, artifact) = try await AutomationUIReadback.storeVerified(receipt: receipt, outputs: outputs, program: program,
            app: plan.app, target: plan.target, scope: scope, artifacts: artifacts, name: "ui-\(lease.generation).json")
        var observations: [AutomationObservation] = []
        if segment.phase == .observe && !verified.isEmpty {
            var observation = AutomationObservation(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: scope.attemptId, stepID: segment.id, route: .ui, proof: .visibleState, value: .object(verified))
            observation.artifact = artifact.handle; observations = [observation]
        }
        if segment.phase == .setup { pendingSetupCapture = await authority.capturedSetup(scope: scope) }
        // Legacy scalar reads are retained only as artifacts. They lack capture provenance.
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
                     dispatched: true, completed: true, observations: observations, artifact: artifact.handle, verifiedOutputs: verified, environmentID: plan.environmentID)
    }
    public func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        revokedGenerations.insert(lease.generation)
        guard let active = control else { return .init(commandsDrained: acquiringScope == nil, runnerTerminated: acquiringScope == nil && !subjectInspectionUnreleased) }
        guard active.scope == scope, active.lease == lease, !releasing else { return .init(commandsDrained: false, runnerTerminated: false) }
        releasing = true; defer { releasing = false }
        try? await authority.revoke(scope: scope)
        var shutdown: AutomationJSON?
        var shutdownErrorType: String?
        var shutdownErrorCode: String?
        do { shutdown = try await AutomationSidecarShutdown.request(await active.process.rpc) }
        catch {
            shutdownErrorType = String(reflecting: type(of: error))
            shutdownErrorCode = AutomationSidecarReleaseDiagnostics.errorCode(error)
        }
        let stopped = await active.process.stop()
        let deviceReleased = await releaseVerifier.verifyReleased(target: approval.target, controllerBundleIDs: controllerBundleIDs)
        let released = deviceReleased && shutdown?.object?["resourcesReleased"] == .bool(true) && !subjectInspectionUnreleased
        let drained = control?.executing == false
        if releaseDiagnosticCount < 32 {
            releaseDiagnosticCount += 1
            let record = AutomationSidecarReleaseDiagnostics(scope: scope, shutdown: shutdown, errorType: shutdownErrorType, errorCode: shutdownErrorCode,
                stopped: stopped, deviceReleased: deviceReleased, subjectInspectionUnreleased: subjectInspectionUnreleased, drained: drained)
            if let data = try? JSONEncoder().encode(record) {
                _ = try? await artifacts.store(data: data, name: "sidecar-release-\(lease.generation)-\(releaseDiagnosticCount).json", scope: scope)
            }
        }
        if released && stopped && drained {
            if let capture = pendingSetupCapture, capture.scope == scope { releasedSetupCaptures.append(capture) }
            control = nil
        }
        pendingSetupCapture = nil
        return .init(commandsDrained: drained, runnerTerminated: released && stopped)
    }
    func releasedSetupCapture(scope: AutomationScope) -> AutomationControllerSetupCapture? {
        AutomationControllerSetupCapture.unique(releasedSetupCaptures, scope: scope)
    }
    private func scopeJSON(_ scope: AutomationScope) throws -> AutomationJSON {
        try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope))
    }
    static func validateControllerScope(target: TargetIdentity, bundleIDs: [String], developerDirectory: URL?) throws {
        guard bundleIDs.count <= 10, Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.allSatisfy({ $0.utf8.count <= 256 && $0.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil }),
              target.kind != .physical || (Set(AutomationSimulatorReleaseVerifier.runnerBundleIDs).isSubset(of: Set(bundleIDs)) && developerDirectory != nil) else { throw AutomationContractError.invalidIdentity }
    }
    private func verifySubject(_ plan: AutomationCase) async throws {
        do { try await subjectVerifier.verify(app: plan.app, target: plan.target) }
        catch {
            if error as? AutomationContractError == .terminationUnverified { subjectInspectionUnreleased = true }
            throw error
        }
    }
}
#endif
