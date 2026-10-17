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
        case .pairedRunner: "Paired app feature"
        }
    }
    var detail: String {
        if record.target.kind == .pairedRunner {
            return "The paired app may still be running this request. Local process absence cannot release its reservation; verified runner completion is required."
        }
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
    func loadRecentApplications() {
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("recent-applications.json").path) else { return }
        do { recentApplications = try AutomationRecentApplicationStore(supportRoot: support).read(); recentApplicationsError = nil }
        catch { recentApplicationsError = "Recent apps could not be read. You can still choose an app." }
    }
    func rememberApplication(_ url: URL) {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        do {
            recentApplications = try AutomationRecentApplicationStore(supportRoot: support).remember(.init(path: AutomationPath.canonical(url).path,
                name: candidate?.name ?? url.deletingPathExtension().lastPathComponent, bookmark: bookmark))
            recentApplicationsError = nil
        } catch { recentApplicationsError = "The app is selected, but its recent entry could not be saved." }
    }
    func reopenApplication(_ entry: AutomationRecentApplication) {
        guard !busy else { return }
        do {
            let url: URL
            if let bookmark = entry.bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                // A successful reinspection below creates a fresh bookmark, including after a move.
            } else { url = URL(fileURLWithPath: entry.path) }
            select(url)
            let selection = task, epoch = selectionEpoch
            Task { [weak self] in
                await selection?.value
                guard let self, !self.busy, self.selectionEpoch == epoch, self.intake != nil,
                      (try? AutomationPath.canonical(url).path) != entry.path else { return }
                self.forgetApplication(entry)
            }
        } catch { message = "This saved app can no longer be opened. Choose it again to restore access." }
    }
    func forgetApplication(_ entry: AutomationRecentApplication) {
        guard !busy else { return }
        do { recentApplications = try AutomationRecentApplicationStore(supportRoot: support).forget(path: entry.path) }
        catch { recentApplicationsError = "The recent entry could not be removed." }
    }
    func refreshRecovery() async {
        await ownershipRecoveryTask?.value
        guard !busy, !recoveryLoading else { return }
        recoveryLoading = true
        defer { recoveryLoading = false }
        // Re-read the paired campaign authority as well as device records. A
        // paired reservation can remain without a currently acquired lease.
        await restorePairedOwnership()
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("target-leases.json").path) else {
            recoveryItems = []; recoveryError = nil; await refreshTargets(); return
        }
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
        for record in try await leases.recoveryRecords() where !record.runID.hasPrefix("intent-lab-") && record.target.kind != .pairedRunner && [.absent, .replaced].contains(record.owner.presence()) {
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
        do { try beginExecutionAdmission(allowingRecovery: true) }
        catch { message = errorText(error); return }
        progress = "Resetting device ownership…"; recoveryError = nil
        defer { progress = nil; finishExecutionAdmission() }
        do {
            let leases = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
            let records = try await leases.recoveryRecords().filter { !$0.runID.hasPrefix("intent-lab-") }
            let current = try AutomationProcessIdentity.current()
            let eligible = records.filter {
                $0.target.kind != .pairedRunner &&
                    ([.absent, .replaced].contains($0.owner.presence()) ||
                     ($0.owner == current && retainedUnresolvedRequestTargets[$0.runID]?.leaseKey == $0.target.leaseKey))
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
                try await recoverySimulatorShutdown(target, developerDirectory(for: target), support)
            }
            for record in eligible {
                if [.absent, .replaced].contains(record.owner.presence()) {
                    try await leases.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
                } else {
                    try await leases.resetCurrentProcessCampaign(record)
                }
            }
            let remaining = try await leases.recoveryRecords()
            finishOwnershipReset()
            recoveryItems = remaining.map { .init(record: $0) }
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
