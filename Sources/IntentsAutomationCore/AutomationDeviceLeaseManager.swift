import Foundation

public actor AutomationDeviceLeaseManager {
    public struct Lease: Codable, Equatable, Sendable {
        public var runID: String
        public var target: TargetIdentity
        public var generation: Int
        public var control: Control
        public enum Control: String, Codable, Sendable { case ui, system }
    }
    public struct Dispatch: Codable, Equatable, Sendable {
        public var scope: AutomationScope
        public var operationID: String
        public var payloadDigest: String
        public init(scope: AutomationScope, operationID: String, payloadDigest: String) {
            self.scope = scope; self.operationID = operationID; self.payloadDigest = payloadDigest
        }
    }
    public struct RecoveryRecord: Equatable, Sendable {
        public var runID: String
        public var target: TargetIdentity
        public var generation: Int
        public var owner: AutomationProcessIdentity
        public var ownerToken: String
        public var control: Lease.Control?
        public var lastDispatch: Dispatch?
        public var runners: [OwnedRunner]
        public var privatePayload: PrivatePayload?
    }
    /// Exact owned derivative and byte commitments; contains no user payload bytes.
    public struct PrivatePayload: Codable, Equatable, Sendable {
        public let scope: AutomationScope
        public let path: String
        public let frozenDigest: String
        public let cleanDigest: String
        func validate() throws {
            try scope.validate()
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\u{0}"),
                  !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  url.pathExtension == "xctestrun",
                  [frozenDigest, cleanDigest].allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
                throw AutomationContractError.invalidIdentity
            }
        }
        var stagingName: String { "." + URL(fileURLWithPath: path).lastPathComponent + ".payload.tmp" }
        var stagingURL: URL { URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(stagingName) }
        /// Recovery observes only. It never creates directories, removes or rewrites a serialized path.
        func verifyClean() throws {
            try validate()
            let file = try AutomationDurableFile(url: URL(fileURLWithPath: path), maximumBytes: 4_194_304, existingParentOnly: true)
            guard file.url.path == path else { throw AutomationContractError.invalidIdentity }
            let staged = try AutomationDurableFile(url: stagingURL, maximumBytes: 4_194_304, existingParentOnly: true)
            guard try staged.read() == nil else { throw AutomationContractError.conflictingOperation }
            if let data = try file.read(), AutomationArtifactRegistry.digest(data) != cleanDigest {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
    public struct OwnedRunner: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case sidecar, appleHost, nativeCommand, uiWorker }
        public var scope: AutomationScope
        public var process: AutomationProcessIdentity
        public var role: Role
        public var executablePath: String
        public init(scope: AutomationScope, process: AutomationProcessIdentity, role: Role, executablePath: String) {
            self.scope = scope; self.process = process; self.role = role; self.executablePath = executablePath
        }
    }
    private let owner: AutomationProcessIdentity
    private let ownerToken = UUID().uuidString
    private let store: AutomationLeaseStore?
    private let diagnosticRoot: URL?
    private var state = AutomationLeaseState()
    private var nativeInputFences: [AutomationNativeInputLeaseFence] = []
    /// Ephemeral arrangement for isolated contract tests. Application execution must supply storeURL.
    public init() {
        owner = (try? .current()) ?? .init(pid: 0, startIdentity: "unknown")
        store = nil
        diagnosticRoot = nil
    }
    public init(storeURL: URL) throws {
        owner = try .current(); store = try AutomationLeaseStore(url: storeURL)
        diagnosticRoot = try AutomationPath.canonical(storeURL.deletingLastPathComponent())
        _ = try store?.read()
    }
    public var isDurable: Bool { store != nil }
    func campaignAbsent(target: TargetIdentity) throws -> Bool { try read().campaigns[target.leaseKey] == nil }
    func reserveCampaign(runID: String, target: TargetIdentity) throws {
        guard !runID.isEmpty, runID.utf8.count <= 256, !target.id.isEmpty, target.id.utf8.count <= 256,
              target.kind != .nativeMac || target.loginSession?.isEmpty == false else { throw AutomationContractError.invalidIdentity }
        try mutate { state in
            let key = target.leaseKey, previous = state.generations[target.leaseKey] ?? 0
            // CoreDevice UUID and Xcode UDID can name the same device. Until canonical
            // alias evidence is available, serialize physical campaigns across both.
            guard target.kind != .physical || !state.campaigns.values.contains(where: { $0.target.kind == .physical }) else { throw AutomationContractError.targetBusy }
            guard state.campaigns[key] == nil else { throw AutomationContractError.targetBusy }
            guard previous < Int.max - 1 else { throw AutomationContractError.invalidIdentity }
            // Reserve idle ownership without admitting a retained earlier campaign.
            // No command or controller is created by this reservation.
            state.campaigns[key] = .init(runID: runID, target: target, owner: owner, ownerToken: ownerToken)
            state.generations[key] = previous + 1
        }
    }
    public func isCurrent(_ lease: Lease) -> Bool {
        guard let state = try? read(), let campaign = state.campaigns[lease.target.leaseKey] else { return false }
        return owns(campaign) && campaign.lease == lease
    }
    func nativeInputFence(for lease: Lease) throws -> AutomationNativeInputLeaseFence {
        guard lease.control == .ui, isCurrent(lease), nativeInputFences.count < 64 else { throw AutomationContractError.unknownLease }
        let check: (@Sendable () -> Bool)?
        if let store {
            let owner = self.owner, token = ownerToken
            check = {
                guard let campaign = try? store.read().campaigns[lease.target.leaseKey] else { return false }
                return campaign.owner == owner && campaign.ownerToken == token && campaign.lease == lease
            }
        } else { check = nil }
        let fence = AutomationNativeInputLeaseFence(lease: lease, persisted: check)
        nativeInputFences.append(fence); return fence
    }
    public func acquire(runID: String, target: TargetIdentity, control: Lease.Control) throws -> Lease {
        guard !runID.isEmpty, runID.utf8.count <= 256, !target.id.isEmpty, target.id.utf8.count <= 256,
              target.kind != .nativeMac || target.loginSession?.isEmpty == false else { throw AutomationContractError.invalidIdentity }
        return try mutate { state in
            let key = target.leaseKey
            guard target.kind != .physical || !state.campaigns.values.contains(where: { $0.target.kind == .physical && $0.target.leaseKey != key }) else { throw AutomationContractError.targetBusy }
            if let prior = state.campaigns[key] {
                guard owns(prior), prior.runID == runID, prior.target == target, prior.lease == nil else { throw AutomationContractError.targetBusy }
            }
            let previous = state.generations[key] ?? 0
            guard previous < Int.max - 1 else { throw AutomationContractError.invalidIdentity }
            let lease = Lease(runID: runID, target: target, generation: previous + 1, control: control)
            var campaign = state.campaigns[key] ?? .init(runID: runID, target: target, owner: owner, ownerToken: ownerToken)
            campaign.lease = lease; state.campaigns[key] = campaign; state.generations[key] = lease.generation
            return lease
        }
    }
    public func validate(_ lease: Lease) throws {
        guard isCurrent(lease) else { throw AutomationContractError.unknownLease }
    }
    public func recordDispatch(_ dispatch: Dispatch, lease: Lease) throws {
        try dispatch.scope.validate()
        guard dispatch.scope.runId == lease.runID, dispatch.scope.leaseGeneration == lease.generation,
              !dispatch.operationID.isEmpty, dispatch.operationID.utf8.count <= 1024,
              dispatch.payloadDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            if let previous = campaign.lastDispatch, previous.scope.leaseGeneration == lease.generation, previous != dispatch {
                throw AutomationContractError.conflictingOperation
            }
            campaign.lastDispatch = dispatch; state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    /// Persist authority before the first write, including acquisitions that fail before control exists.
    func recordPrivatePayload(_ payload: AutomationAppleHostPayloadFile, lease: Lease) throws {
        let reference = payload.recoveryReference
        try reference.validate()
        guard reference.scope.runId == lease.runID, reference.scope.leaseGeneration == lease.generation else {
            throw AutomationContractError.unknownLease
        }
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            guard campaign.privatePayload == nil || campaign.privatePayload == reference else {
                throw AutomationContractError.conflictingOperation
            }
            campaign.privatePayload = reference; state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    func retirePrivatePayload(_ payload: AutomationAppleHostPayloadFile, lease: Lease) throws {
        let reference = payload.recoveryReference
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            guard campaign.privatePayload == nil || campaign.privatePayload == reference else { throw AutomationContractError.unknownLease }
            try reference.verifyClean()
            campaign.privatePayload = nil; state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    public func release(_ lease: Lease, commandsDrained: Bool, ownedRunnerTerminated: Bool) throws {
        if !commandsDrained || !ownedRunnerTerminated {
            if let state = try? read(), let campaign = try? ownedCampaign(lease, state: state) {
                AutomationLeaseReleaseDiagnostics.save(root: diagnosticRoot, lease: lease, campaign: campaign,
                    commandsDrained: commandsDrained, ownedRunnerTerminated: ownedRunnerTerminated,
                    gate: commandsDrained ? "controllerTermination" : "commandsPending")
            }
            throw commandsDrained ? AutomationContractError.terminationUnverified : AutomationContractError.commandsPending
        }
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            let readings = campaign.runners.map { AutomationLeaseReleaseDiagnostics.Runner(runner: $0, presence: AutomationLeaseReleaseDiagnostics.describe($0.process.presence())) }
            guard readings.allSatisfy({ ["absent", "replaced"].contains($0.presence) }) else {
                AutomationLeaseReleaseDiagnostics.save(root: diagnosticRoot, lease: lease, campaign: campaign,
                    commandsDrained: commandsDrained, ownedRunnerTerminated: ownedRunnerTerminated,
                    gate: "runnerPresence", runners: readings)
                throw AutomationContractError.terminationUnverified
            }
            try campaign.privatePayload?.verifyClean()
            campaign.privatePayload = nil
            campaign.lease = nil; campaign.runners = []; state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    public func releaseCampaign(runID: String, target: TargetIdentity) throws {
        try mutate { state in
            guard let campaign = state.campaigns[target.leaseKey], owns(campaign), campaign.runID == runID,
                  campaign.target == target, campaign.lease == nil else { throw AutomationContractError.targetBusy }
            state.campaigns.removeValue(forKey: target.leaseKey)
        }
    }
    public func recordRunner(_ runner: OwnedRunner, lease: Lease) throws {
        try runner.scope.validate()
        guard runner.scope.runId == lease.runID, runner.scope.leaseGeneration == lease.generation,
              runner.process.presence() == .matching, runner.executablePath.hasPrefix("/") else { throw AutomationContractError.invalidIdentity }
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            guard campaign.runners.count < 16, !campaign.runners.contains(where: { $0.process == runner.process }) else {
                throw AutomationContractError.conflictingOperation
            }
            campaign.runners.append(runner); state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    public func retireNativeCommand(_ runner: OwnedRunner, lease: Lease) throws {
        guard runner.role == .nativeCommand, runner.scope.runId == lease.runID,
              runner.scope.leaseGeneration == lease.generation,
              [.absent, .replaced].contains(runner.process.presence()) else { throw AutomationContractError.terminationUnverified }
        try mutate { state in
            var campaign = try ownedCampaign(lease, state: state)
            guard let index = campaign.runners.firstIndex(of: runner) else { throw AutomationContractError.invalidIdentity }
            campaign.runners.remove(at: index)
            state.campaigns[lease.target.leaseKey] = campaign
        }
    }
    public func recoveryRecords() throws -> [RecoveryRecord] {
        let state = try read()
        return state.campaigns.values.filter { !owns($0) }.map { campaign in
            .init(runID: campaign.runID, target: campaign.target, generation: state.generations[campaign.target.leaseKey]!,
                  owner: campaign.owner, ownerToken: campaign.ownerToken, control: campaign.lease?.control, lastDispatch: campaign.lastDispatch, runners: campaign.runners, privatePayload: campaign.privatePayload)
        }.sorted { $0.target.leaseKey < $1.target.leaseKey }
    }
    /// Read-only snapshot for checking the frozen dispatch before this owner's release.
    public func currentRecord(_ lease: Lease) throws -> RecoveryRecord {
        let state = try read(), campaign = try ownedCampaign(lease, state: state)
        return .init(runID: campaign.runID, target: campaign.target, generation: lease.generation,
            owner: campaign.owner, ownerToken: campaign.ownerToken, control: campaign.lease?.control,
            lastDispatch: campaign.lastDispatch, runners: campaign.runners, privatePayload: campaign.privatePayload)
    }
    /// Tracks read-only recovery work without transferring ownership or authorising dispatch.
    public func recordRecoveryInspector(_ runner: OwnedRunner, record: RecoveryRecord) throws -> RecoveryRecord {
        try runner.scope.validate()
        guard record.target.kind == .physical, record.control == .system,
              runner.scope == record.lastDispatch?.scope, runner.scope.runId == record.runID,
              runner.scope.leaseGeneration == record.generation, runner.role == .nativeCommand,
              runner.executablePath == "/usr/bin/xcrun", runner.process.presence() == .matching else {
            throw AutomationContractError.invalidIdentity
        }
        return try mutate { state in
            guard let stored = state.campaigns[record.target.leaseKey], !owns(stored),
                  stored.runID == record.runID, stored.target == record.target, stored.owner == record.owner,
                  stored.ownerToken == record.ownerToken, stored.lease?.control == record.control,
                  stored.lastDispatch == record.lastDispatch, stored.runners == record.runners,
                  stored.privatePayload == record.privatePayload,
                  state.generations[record.target.leaseKey] == record.generation else {
                throw AutomationContractError.unknownLease
            }
            guard [.absent, .replaced].contains(stored.owner.presence()) else { throw AutomationContractError.targetBusy }
            guard stored.runners.count < 16, !stored.runners.contains(where: { $0.process == runner.process }) else {
                throw AutomationContractError.conflictingOperation
            }
            var campaign = stored, updated = record
            campaign.runners.append(runner); updated.runners = campaign.runners
            state.campaigns[record.target.leaseKey] = campaign
            return updated
        }
    }
    /// Reconciliation frees control only; it never clears the dispatch journal or authorises repetition.
    public func reconcile(_ record: RecoveryRecord, commandsDrained: Bool, ownedRunnerTerminated: Bool) throws {
        guard commandsDrained else { throw AutomationContractError.commandsPending }
        guard ownedRunnerTerminated else { throw AutomationContractError.terminationUnverified }
        switch record.owner.presence() {
        case .absent, .replaced: break
        case .matching, .unknown: throw AutomationContractError.targetBusy
        }
        guard record.runners.allSatisfy({ [.absent, .replaced].contains($0.process.presence()) }) else {
            throw AutomationContractError.terminationUnverified
        }
        try mutate { state in
            guard let campaign = state.campaigns[record.target.leaseKey], !owns(campaign),
                  campaign.runID == record.runID, campaign.target == record.target, campaign.owner == record.owner,
                  campaign.ownerToken == record.ownerToken, campaign.lease?.control == record.control,
                  campaign.lastDispatch == record.lastDispatch, campaign.runners == record.runners,
                  campaign.privatePayload == record.privatePayload,
                  state.generations[record.target.leaseKey] == record.generation else {
                throw AutomationContractError.unknownLease
            }
            try campaign.privatePayload?.verifyClean()
            state.campaigns.removeValue(forKey: record.target.leaseKey)
        }
    }
    private func owns(_ campaign: AutomationLeaseState.Campaign) -> Bool { campaign.owner == owner && campaign.ownerToken == ownerToken }
    private func ownedCampaign(_ lease: Lease, state: AutomationLeaseState) throws -> AutomationLeaseState.Campaign {
        guard let campaign = state.campaigns[lease.target.leaseKey], owns(campaign), campaign.lease == lease else {
            throw AutomationContractError.unknownLease
        }
        return campaign
    }
    private func invalidateNativeInputFences(_ value: AutomationLeaseState) {
        nativeInputFences.removeAll { fence in
            guard let campaign = value.campaigns[fence.lease.target.leaseKey], owns(campaign), campaign.lease == fence.lease else {
                fence.invalidate(); return true
            }
            return false
        }
    }
    private func read() throws -> AutomationLeaseState { try store?.read() ?? state }
    private func mutate<T>(_ body: (inout AutomationLeaseState) throws -> T) throws -> T {
        if let store {
            var committed: AutomationLeaseState?
            let result = try store.transaction { next in
                let result = try body(&next); committed = next; return result
            }
            if let committed { invalidateNativeInputFences(committed) }
            return result
        }
        var next = state; let result = try body(&next); try next.validate(); state = next
        invalidateNativeInputFences(next); return result
    }
}
