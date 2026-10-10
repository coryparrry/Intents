import Foundation

/// Decision-time facts only. Diagnostics never release a lease or authorize recovery.
enum AutomationLeaseReleaseDiagnostics {
    struct Runner: Codable {
        let runner: AutomationDeviceLeaseManager.OwnedRunner
        let presence: String
    }
    struct Record: Codable {
        let schemaVersion: Int
        let date: Date
        let lease: AutomationDeviceLeaseManager.Lease
        let commandsDrained: Bool
        let ownedRunnerTerminated: Bool
        let failedGate: String
        let lastDispatch: AutomationDeviceLeaseManager.Dispatch?
        let runners: [Runner]
        let inspectionDigest: String?
    }
    static func describe(_ presence: AutomationProcessIdentity.Presence) -> String {
        switch presence { case .matching: "matching"; case .absent: "absent"; case .replaced: "replaced"; case .unknown: "unknown" }
    }
    static func save(root: URL?, lease: AutomationDeviceLeaseManager.Lease, campaign: AutomationLeaseState.Campaign,
                     commandsDrained: Bool, ownedRunnerTerminated: Bool, gate: String,
                     runners: [Runner]? = nil) {
        guard let root else { return }
        do {
            var digest: String?
            if let attemptID = campaign.lastDispatch?.scope.attemptId,
               attemptID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
               let data = try? AutomationReadOnlyFile.read(root: root, relativePath: attemptID + "/release-inspection.json",
                   maximumBytes: 3_145_728, requirePrivateOwnership: true) {
                digest = AutomationArtifactRegistry.digest(data)
            }
            let record = Record(schemaVersion: 1, date: Date(), lease: lease, commandsDrained: commandsDrained,
                ownedRunnerTerminated: ownedRunnerTerminated, failedGate: gate, lastDispatch: campaign.lastDispatch,
                runners: runners ?? campaign.runners.map { .init(runner: $0, presence: describe($0.process.presence())) }, inspectionDigest: digest)
            let directory = root.appendingPathComponent("release-failures")
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard try AutomationPath.canonical(directory).path == directory.path,
                  (try FileManager.default.contentsOfDirectory(atPath: directory.path)).count < 256 else { return }
            let data = try JSONEncoder().encode(record)
            let file = try AutomationDurableFile(url: directory.appendingPathComponent(UUID().uuidString + ".json"), maximumBytes: 65_536)
            try file.withLock { try file.write(data) }
        } catch { /* Failed release remains authoritative even when diagnostics cannot be saved. */ }
    }
}
