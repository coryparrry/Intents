import CryptoKit
import Foundation
import IntentsAutomationCore
import IntentLabContracts

struct ScenarioPhysicalRunnerRecord: Codable, Equatable, Sendable {
    var lease: AutomationDeviceLeaseManager.Lease
    var runnerProduct: ScenarioProductIdentity
    var hostProcess: AutomationProcessIdentity? = nil
    var receipt: AutomationLegacyRunnerReceipt? = nil
    var receiptError: String? = nil
    var dispatched = false
    var hostLaunchPrevented = false
    var released = false
    var releaseObservation: AutomationPhysicalRunnerVerifier.Observation? = nil
}

struct ScenarioPhysicalRunnerInspector: Sendable {
    var inspect: @Sendable (TargetIdentity, String, String, Int32?, @escaping @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> AutomationPhysicalRunnerVerifier.Observation
    var drain: @Sendable () async -> Bool
    static func live(workspace: URL) throws -> Self {
        let reader = try AutomationPhysicalRunnerVerifier(workspace: workspace)
        return .init(inspect: { try await reader.inspect(target: $0, runnerBundleID: $1, executableName: $2, ownedPID: $3, didStart: $4) },
                     drain: { await reader.drainInspector() })
    }
}

/// Uses the same durable native target fence as App automation. Old evidence does not mint new ownership.
actor ScenarioPhysicalRunnerLeaseManager {
    private let leases: AutomationDeviceLeaseManager
    private let factory: @Sendable (URL) throws -> ScenarioPhysicalRunnerInspector
    private struct InspectorKey: Hashable { var target: String; var runID: String; var generation: Int }
    private var inspectors: [InspectorKey: ScenarioPhysicalRunnerInspector] = [:]
    init(storeURL: URL, inspectorFactory: @escaping @Sendable (URL) throws -> ScenarioPhysicalRunnerInspector = ScenarioPhysicalRunnerInspector.live) throws {
        leases = try AutomationDeviceLeaseManager(storeURL: storeURL)
        factory = inspectorFactory
    }

    func acquire(invocation: ScenarioInvocationIdentity, runner: ScenarioProductIdentity, workspace: URL) async throws -> ScenarioPhysicalRunnerRecord {
        guard runner.bundleIdentifier.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil,
              runner.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              !runner.executableName.isEmpty, !runner.executableName.contains("/"), !runner.executableName.contains("\0") else {
            throw AutomationContractError.invalidIdentity
        }
        let inspector = try factory(workspace)
        let lease = try await leases.acquire(runID: Self.runID(invocation), target: .init(id: invocation.destinationIdentifier, kind: .physical), control: .system)
        inspectors[Self.key(lease)] = inspector
        return .init(lease: lease, runnerProduct: runner)
    }

    func prepare(_ record: ScenarioPhysicalRunnerRecord) async throws {
        try await leases.validate(record.lease)
        guard let inspector = inspectors[Self.key(record.lease)] else { throw AutomationContractError.terminationUnverified }
        let observed = try await inspector.inspect(record.lease.target, record.runnerProduct.bundleIdentifier, record.runnerProduct.executableName, nil) {
            try await self.recordInspector($0, record: record)
        }
        guard Self.valid(observed, target: record.lease.target), observed.runnerAbsent else { throw AutomationContractError.targetBusy }
    }

    func recordDispatch(_ record: ScenarioPhysicalRunnerRecord, invocation: ScenarioInvocationIdentity) async throws -> ScenarioPhysicalRunnerRecord {
        var record = record
        try await leases.recordDispatch(Self.dispatch(record, invocation: invocation), lease: record.lease)
        record.dispatched = true
        return record
    }

    func recordHost(_ record: ScenarioPhysicalRunnerRecord, process: AutomationProcessIdentity, executable: String) async throws -> ScenarioPhysicalRunnerRecord {
        var record = record; record.hostProcess = process
        if process.presence() == .matching {
            try await leases.recordRunner(.init(scope: Self.scope(record), process: process, role: .nativeCommand, executablePath: executable), lease: record.lease)
        } else if ![.absent, .replaced].contains(process.presence()) { throw AutomationContractError.terminationUnverified }
        return record
    }

    /// Exact remote executable absence is the compatibility fallback for old harnesses with no receipt.
    func finish(_ original: ScenarioPhysicalRunnerRecord, invocation: ScenarioInvocationIdentity, workspace: URL) async throws -> ScenarioPhysicalRunnerRecord {
        var record = original
        guard !record.released else { return record }
        guard record.lease.runID == Self.runID(invocation), record.lease.target == .init(id: invocation.destinationIdentifier, kind: .physical),
              !record.dispatched || (record.hostLaunchPrevented && record.hostProcess == nil)
                || record.hostProcess.map({ [.absent, .replaced].contains($0.presence()) }) == true else {
            throw AutomationContractError.terminationUnverified
        }
        let current = await leases.isCurrent(record.lease)
        let recovery = current ? [try await leases.currentRecord(record.lease)] : try await leases.recoveryRecords().filter {
            $0.runID == record.lease.runID && $0.target == record.lease.target && $0.generation == record.lease.generation
        }
        guard recovery.count == 1, recovery[0].lastDispatch == (record.dispatched ? try Self.dispatch(record, invocation: invocation) : nil),
              recovery[0].runners.allSatisfy({ ($0.process == record.hostProcess || $0.executablePath == "/usr/bin/xcrun") && $0.scope == Self.scope(record) }) else {
            throw AutomationContractError.unknownLease
        }
        let inspector: ScenarioPhysicalRunnerInspector
        if let existing = inspectors[Self.key(record.lease)] { inspector = existing }
        else { inspector = try factory(workspace); inspectors[Self.key(record.lease)] = inspector }
        guard await inspector.drain() else { throw AutomationContractError.commandsPending }
        let recoveryInspectors = RecoveryInspectorRegistration(leases: leases, record: recovery[0])
        if record.dispatched {
            if let receipt = record.receipt { try Self.validate(receipt, invocation: invocation, runner: record.runnerProduct) }
            let inspectionRecord = record
            let observed = try await inspector.inspect(record.lease.target, record.runnerProduct.bundleIdentifier,
                record.runnerProduct.executableName, record.receipt?.processIdentifier) { process in
                    if current { try await self.recordInspector(process, record: inspectionRecord) }
                    else { try await recoveryInspectors.register(process) }
                }
            guard Self.valid(observed, target: record.lease.target), observed.runnerAbsent else { throw AutomationContractError.terminationUnverified }
            record.releaseObservation = observed
        }
        if current {
            try await leases.release(record.lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await leases.releaseCampaign(runID: record.lease.runID, target: record.lease.target)
        } else {
            try await leases.reconcile(recoveryInspectors.snapshot(), commandsDrained: true, ownedRunnerTerminated: true)
        }
        inspectors[Self.key(record.lease)] = nil
        record.released = true
        return record
    }

    static func validate(_ receipt: AutomationLegacyRunnerReceipt, invocation: ScenarioInvocationIdentity, runner: ScenarioProductIdentity) throws {
        guard let test = invocation.testProduct else { throw AutomationContractError.invalidIdentity }
        try receipt.validate(invocationID: invocation.id, nonce: invocation.nonce, destinationIdentifier: invocation.destinationIdentifier,
            scenarioDigest: invocation.scenarioDigest, testBundleIdentifier: test.bundleIdentifier,
            testProductSHA256: test.sha256, executableName: runner.executableName)
    }
    private static func runID(_ invocation: ScenarioInvocationIdentity) -> String { "intent-lab-" + invocation.id.uuidString }
    private actor RecoveryInspectorRegistration {
        let leases: AutomationDeviceLeaseManager
        var record: AutomationDeviceLeaseManager.RecoveryRecord
        init(leases: AutomationDeviceLeaseManager, record: AutomationDeviceLeaseManager.RecoveryRecord) {
            self.leases = leases; self.record = record
        }
        func register(_ process: AutomationProcessIdentity) async throws {
            guard let scope = record.lastDispatch?.scope else { throw AutomationContractError.unknownLease }
            do {
                record = try await leases.recordRecoveryInspector(.init(scope: scope, process: process,
                    role: .nativeCommand, executablePath: "/usr/bin/xcrun"), record: record)
            } catch {
                guard [.absent, .replaced].contains(process.presence()) else { throw error }
            }
        }
        func snapshot() -> AutomationDeviceLeaseManager.RecoveryRecord { record }
    }
    private static func key(_ lease: AutomationDeviceLeaseManager.Lease) -> InspectorKey {
        .init(target: lease.target.leaseKey, runID: lease.runID, generation: lease.generation)
    }
    private func recordInspector(_ process: AutomationProcessIdentity, record: ScenarioPhysicalRunnerRecord) async throws {
        do {
            try await leases.recordRunner(.init(scope: Self.scope(record), process: process, role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: record.lease)
        } catch {
            try await leases.validate(record.lease)
            guard [.absent, .replaced].contains(process.presence()) else { throw error }
        }
    }
    private static func valid(_ observation: AutomationPhysicalRunnerVerifier.Observation, target: TargetIdentity) -> Bool {
        observation.targetID == target.id && UUID(uuidString: observation.deviceIdentifier) != nil
            && [observation.appsSHA256, observation.processesSHA256].allSatisfy { $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    }
    private static func scope(_ record: ScenarioPhysicalRunnerRecord) -> AutomationScope {
        .init(runID: record.lease.runID, attemptID: record.lease.runID, segmentID: "legacy-xctest", leaseGeneration: record.lease.generation)
    }
    private static func dispatch(_ record: ScenarioPhysicalRunnerRecord, invocation: ScenarioInvocationIdentity) throws -> AutomationDeviceLeaseManager.Dispatch {
        struct Payload: Encodable { var invocation: ScenarioInvocationIdentity; var runner: ScenarioProductIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(Payload(invocation: invocation, runner: record.runnerProduct))
        return .init(scope: scope(record), operationID: "legacy-xctest", payloadDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
