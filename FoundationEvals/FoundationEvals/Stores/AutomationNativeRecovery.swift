#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeRecoveryItem: Identifiable {
    let record: AutomationDeviceLeaseManager.RecoveryRecord
    var id: String { record.target.leaseKey + ":" + record.runID }
    var title: String {
        switch record.target.kind {
        case .nativeMac: "Mac session"
        case .simulator: "Simulator"
        case .physical: "Connected device"
        }
    }
    var detail: String {
        switch record.owner.presence() {
        case .matching: return "The owning Intents process is still running. Finish or cancel the run there, then check again."
        case .unknown: return "Intents cannot verify whether the previous owner has stopped. This target stays reserved."
        case .absent, .replaced: break
        }
        if record.runners.contains(where: { ![.absent, .replaced].contains($0.process.presence()) }) {
            return "An owned runner is still active or its state is unknown. Finish the original run, then check again."
        }
        return "The previous Intents process stopped. Reset device ownership to release this reservation; the saved result remains available."
    }
}

extension AppAutomationStore {
    func refreshRecovery() async {
        await ownershipRecoveryTask?.value
        guard !busy, !recoveryLoading else { return }
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("target-leases.json").path) else {
            recoveryItems = []; recoveryError = nil; await refreshTargets(); return
        }
        recoveryLoading = true
        defer { recoveryLoading = false }
        do {
            let leases = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
            try await reconcileAbandonedOwnership(using: leases)
            let records = try await leases.recoveryRecords()
            recoveryItems = records.filter { !$0.runID.hasPrefix("intent-lab-") }.map { .init(record: $0) }
            recoveryError = nil
        } catch { recoveryError = "Saved ownership could not be checked. Existing reservations remain in force." }
        await refreshTargets()
    }

    func reconcileAbandonedOwnership() async {
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("target-leases.json").path) else { return }
        do {
            let leases = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
            try await reconcileAbandonedOwnership(using: leases)
            recoveryItems = try await leases.recoveryRecords().filter { !$0.runID.hasPrefix("intent-lab-") }.map { .init(record: $0) }
            recoveryError = nil
        } catch { recoveryError = errorText(error) }
    }

    private func reconcileAbandonedOwnership(using leases: AutomationDeviceLeaseManager) async throws {
        var failure: (any Error)?
        for record in try await leases.recoveryRecords() where !record.runID.hasPrefix("intent-lab-") && [.absent, .replaced].contains(record.owner.presence()) {
            // A still-running child keeps its reservation. Reconcile checks the durable
            // snapshot and any pending payload before removing a stopped campaign.
            do { try await leases.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    func clearUnresolvedAttempt() async {
        guard !busy, !closingForOwnershipRecovery else { return }
        await ownershipRecoveryTask?.value
        guard !busy, !closingForOwnershipRecovery else { return }
        progress = "Resetting device ownership…"; recoveryError = nil
        defer { progress = nil }
        do {
            let leases = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
            let records = try await leases.recoveryRecords().filter { !$0.runID.hasPrefix("intent-lab-") }
            let current = try AutomationProcessIdentity.current()
            let eligible = records.filter {
                [.absent, .replaced].contains($0.owner.presence()) ||
                    ($0.owner == current && retainedUnresolvedRequestTargets[$0.runID]?.leaseKey == $0.target.leaseKey)
            }
            guard !eligible.isEmpty || hasUnresolvedActiveAttempt || records.isEmpty else { throw AutomationContractError.targetBusy }
            guard eligible.allSatisfy({ $0.runners.allSatisfy { [.absent, .replaced].contains($0.process.presence()) } }) else {
                throw AutomationContractError.terminationUnverified
            }
            var resetTargets = Array(retainedUnresolvedRequestTargets.values)
            if let target = retainedUnresolvedNormalTarget { resetTargets.append(target) }
            guard !records.contains(where: { record in
                resetTargets.contains(where: { $0.leaseKey == record.target.leaseKey }) && !eligible.contains(record)
            }) else { throw AutomationContractError.targetBusy }
            let simulatorTargets = (eligible.map(\.target) + resetTargets).filter { $0.kind == .simulator }
            for target in Dictionary(grouping: simulatorTargets, by: \.leaseKey).values.compactMap(\.first) {
                try await recoverySimulatorShutdown(target, developerDirectory, support)
            }
            for record in eligible {
                if [.absent, .replaced].contains(record.owner.presence()) {
                    try await leases.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
                } else {
                    try await leases.resetCurrentProcessCampaign(record)
                }
            }
            finishOwnershipReset()
            recoveryItems = try await leases.recoveryRecords().map { .init(record: $0) }
            message = "Device ownership reset. Review the workflow before running again."
        } catch { recoveryError = errorText(error) }
    }

    /// A thrown finished request can retain a reservation without returning a report.
    /// Capture only its own exact run and target; other same-process campaigns remain live.
    func retainUnresolvedReservation(runID: String, target: TargetIdentity) async {
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("target-leases.json").path),
              let leases = try? AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json")),
              let records = try? await leases.recoveryRecords(),
              records.contains(where: { $0.runID == runID && $0.target.leaseKey == target.leaseKey }) else { return }
        retainUnresolvedRequest(runID: runID, target: target)
    }

    nonisolated static func shutdownRecoverySimulator(_ target: TargetIdentity, developerDirectory: URL, workspace: URL) async throws {
        guard target.kind == .simulator, UUID(uuidString: target.id) != nil else { throw AutomationContractError.invalidIdentity }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()]
        let inventory = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "--json"], directory: workspace, environment: environment, timeout: .seconds(15))
        guard inventory.exitStatus == 0, !inventory.logsTruncated,
              let json = try JSONSerialization.jsonObject(with: inventory.stdout) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]],
              let device = devices.values.flatMap({ $0 }).first(where: { ($0["udid"] as? String)?.lowercased() == target.id.lowercased() }) else {
            throw AutomationContractError.missingEvidence("The simulator could not be found. Refresh devices before resetting ownership.")
        }
        if device["state"] as? String == "Shutdown" { return }
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "shutdown", target.id], directory: workspace, environment: environment, timeout: .seconds(30))
        guard result.exitStatus == 0 else { throw AutomationContractError.terminationUnverified }
    }
}
#endif
