import Foundation

/// Device controllers can outlive their Mac daemon. SDK shutdown alone is insufficient proof.
public protocol AutomationDeviceReleaseVerifier: Sendable {
    func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws
    func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool
}

#if os(macOS)
public actor AutomationSimulatorReleaseVerifier: AutomationDeviceReleaseVerifier {
    struct Inspection: Codable, Sendable {
        let targetID: String
        let ordinal: Int
        let stage: String
        let completed: Bool
        let exitStatus: Int32
        let stdout: Data
        let stderr: Data
        let logsTruncated: Bool
        let error: String?
    }
    // Pinned agent-device 0.21.20 defaults; overridden runner IDs are not accepted by our environment.
    static let runnerBundleIDs = ["com.callstack.agentdevice.runner", "com.callstack.agentdevice.runner.uitests.xctrunner"]
    private let developerDirectory: URL
    private let workspace: URL
    private let bundleIDs: [String]
    private let command = AutomationOwnedCommand()
    private var unprovedInspector = false
    private var inspectionOrdinal = 0
    public init(developerDirectory: URL, workspace: URL, additionalRunnerBundleIDs: [String] = []) {
        self.developerDirectory = developerDirectory; self.workspace = workspace
        bundleIDs = Self.runnerBundleIDs + additionalRunnerBundleIDs
    }
    public func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {
        guard !unprovedInspector, try await runnerJobs(target: target, additionalIDs: controllerBundleIDs, timeout: .seconds(15), stage: "prepare").isEmpty else { throw AutomationContractError.targetBusy }
    }
    public func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
        guard !unprovedInspector else { return false }
        do { return try await runnerJobs(target: target, additionalIDs: controllerBundleIDs, stage: "verify").isEmpty } catch { return false }
    }
    private func runnerJobs(target: TargetIdentity, additionalIDs: [String], // Match preparation: under CPU load, launching the read-only inspector can exceed three seconds.
    // The coordinator still bounds all cleanup and retains ownership on timeout.
    timeout: Duration = .seconds(15), stage: String) async throws -> [Int32] {
        guard target.kind == .simulator, target.id.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.missingEvidence("Device runner termination has no qualified verifier for this target")
        }
        var completedCommand: AutomationOwnedCommand.Result?
        do {
            let developer = try AutomationPath.canonical(developerDirectory)
            let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "spawn", target.id, "launchctl", "list"], directory: workspace,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path, "HOME": workspace.path, "TMPDIR": workspace.path], timeout: timeout)
            completedCommand = result
            guard result.exitStatus == 0, !result.logsTruncated else { throw AutomationContractError.terminationUnverified }
            let jobs = try Self.parseRunnerJobs(result.stdout, bundleIDs: Array(Set(bundleIDs + additionalIDs)))
            persistInspection(target: target, result: result, error: nil, stage: stage)
            return jobs
        } catch {
            let diagnostics = await command.retainedLogs()
            persistInspection(target: target, result: completedCommand ?? diagnostics, error: error, stage: stage)
            if error as? AutomationContractError == .terminationUnverified { unprovedInspector = true }
            throw error
        }
    }
    private func persistInspection(target: TargetIdentity, result: AutomationOwnedCommand.Result, error: (any Error)?, stage: String) {
        // Diagnostics never grant release authority or change the result of verification.
        inspectionOrdinal += 1
        let record = Inspection(targetID: target.id, ordinal: inspectionOrdinal, stage: stage, completed: error == nil, exitStatus: result.exitStatus,
            stdout: result.stdout, stderr: result.stderr, logsTruncated: result.logsTruncated,
            error: error.map { String(String(describing: $0).prefix(4096)) })
        do {
            let data = try JSONEncoder().encode(record)
            // Preserve earlier failures even if catch cleanup subsequently succeeds.
            let history = workspace.appendingPathComponent("release-inspections")
            if !FileManager.default.fileExists(atPath: history.path) {
                try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard try AutomationPath.canonical(history).path == history.path else { return }
            let entries = try FileManager.default.contentsOfDirectory(atPath: history.path)
            guard entries.count < 128 else { return }
            let bytes = try entries.filter { $0.hasSuffix(".json") }.reduce(0) { total, name in
                total + (((try FileManager.default.attributesOfItem(atPath: history.appendingPathComponent(name).path)[.size]) as? NSNumber)?.intValue ?? 0)
            }
            guard bytes <= 16_777_216 - data.count else { return }
            let retained = try AutomationDurableFile(url: history.appendingPathComponent(String(inspectionOrdinal) + "-" + UUID().uuidString + ".json"), maximumBytes: 3_145_728)
            try retained.withLock { try retained.write(data) }
            let file = try AutomationDurableFile(url: workspace.appendingPathComponent("release-inspection.json"), maximumBytes: 3_145_728)
            try file.withLock { try file.write(data) }
        } catch { /* Retained ownership and failed verification remain authoritative. */ }
    }
    static func parseRunnerJobs(_ data: Data, bundleIDs: [String] = runnerBundleIDs) throws -> [Int32] {
        guard (1...10).contains(bundleIDs.count), bundleIDs.allSatisfy({ $0.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil }) else { throw AutomationContractError.invalidIdentity }
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
            throw AutomationContractError.terminationUnverified
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "PID\tStatus\tLabel" else { throw AutomationContractError.terminationUnverified }
        var jobs: [Int32] = []
        for line in lines.dropFirst().dropLast() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "-" || Int32(fields[0]).map({ $0 > 0 }) == true,
                  Int32(fields[1]) != nil, !fields[2].isEmpty else { throw AutomationContractError.terminationUnverified }
            if bundleIDs.contains(where: { fields[2].hasPrefix("UIKitApplication:\($0)[") }) {
                // A loaded job without a PID can restart; it cannot establish release either.
                jobs.append(Int32(fields[0]) ?? -1)
            }
        }
        return jobs
    }
}
#endif
