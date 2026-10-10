#if os(macOS)
import Foundation

/// Acknowledged owned installation and bundle presence, never a remote-byte equivalence assertion.
public struct AutomationPhysicalInstallationReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: AutomationScope
    public let app: AppIdentity
    public let target: TargetIdentity
    public let developerDirectory: String
    public let deviceIdentifier: String
    public let installedBundleURL: String
    public let stagedBundlePath: String
    public let commandArguments: [String]
    public let commandExitStatus: Int32
    public let stdoutSHA256: String
    public let stderrSHA256: String
    public let beforeInventorySHA256: String
    public let afterInventorySHA256: String
    public var evidenceScope: String { "ownedInstallCommandAndBundlePresence" }
    public var installedBytesVerified: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, scope, app, target, developerDirectory, deviceIdentifier, installedBundleURL, stagedBundlePath
        case commandArguments, commandExitStatus, stdoutSHA256, stderrSHA256, beforeInventorySHA256, afterInventorySHA256
        case evidenceScope, installedBytesVerified
    }
    init(schemaVersion: Int, scope: AutomationScope, app: AppIdentity, target: TargetIdentity, developerDirectory: String,
         deviceIdentifier: String, installedBundleURL: String, stagedBundlePath: String, commandArguments: [String],
         commandExitStatus: Int32, stdoutSHA256: String, stderrSHA256: String, beforeInventorySHA256: String, afterInventorySHA256: String) {
        self.schemaVersion = schemaVersion; self.scope = scope; self.app = app; self.target = target
        self.developerDirectory = developerDirectory; self.deviceIdentifier = deviceIdentifier; self.installedBundleURL = installedBundleURL
        self.stagedBundlePath = stagedBundlePath; self.commandArguments = commandArguments; self.commandExitStatus = commandExitStatus
        self.stdoutSHA256 = stdoutSHA256; self.stderrSHA256 = stderrSHA256
        self.beforeInventorySHA256 = beforeInventorySHA256; self.afterInventorySHA256 = afterInventorySHA256
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(String.self, forKey: .evidenceScope) == "ownedInstallCommandAndBundlePresence",
              try c.decode(Bool.self, forKey: .installedBytesVerified) == false else { throw AutomationContractError.invalidIdentity }
        self.init(schemaVersion: 1, scope: try c.decode(AutomationScope.self, forKey: .scope),
            app: try c.decode(AppIdentity.self, forKey: .app), target: try c.decode(TargetIdentity.self, forKey: .target),
            developerDirectory: try c.decode(String.self, forKey: .developerDirectory), deviceIdentifier: try c.decode(String.self, forKey: .deviceIdentifier),
            installedBundleURL: try c.decode(String.self, forKey: .installedBundleURL), stagedBundlePath: try c.decode(String.self, forKey: .stagedBundlePath),
            commandArguments: try c.decode([String].self, forKey: .commandArguments), commandExitStatus: try c.decode(Int32.self, forKey: .commandExitStatus),
            stdoutSHA256: try c.decode(String.self, forKey: .stdoutSHA256), stderrSHA256: try c.decode(String.self, forKey: .stderrSHA256),
            beforeInventorySHA256: try c.decode(String.self, forKey: .beforeInventorySHA256), afterInventorySHA256: try c.decode(String.self, forKey: .afterInventorySHA256))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(scope, forKey: .scope)
        try c.encode(app, forKey: .app); try c.encode(target, forKey: .target)
        try c.encode(developerDirectory, forKey: .developerDirectory); try c.encode(deviceIdentifier, forKey: .deviceIdentifier)
        try c.encode(installedBundleURL, forKey: .installedBundleURL); try c.encode(stagedBundlePath, forKey: .stagedBundlePath)
        try c.encode(commandArguments, forKey: .commandArguments); try c.encode(commandExitStatus, forKey: .commandExitStatus)
        try c.encode(stdoutSHA256, forKey: .stdoutSHA256); try c.encode(stderrSHA256, forKey: .stderrSHA256)
        try c.encode(beforeInventorySHA256, forKey: .beforeInventorySHA256); try c.encode(afterInventorySHA256, forKey: .afterInventorySHA256)
        try c.encode(evidenceScope, forKey: .evidenceScope); try c.encode(false, forKey: .installedBytesVerified)
    }
}

/// Serial owned native commands under the caller's system lease. Does not launch/reset a device app.
public actor AutomationPhysicalApplicationInstaller {
    typealias Invocation = AutomationPhysicalRunnerVerifier.InventoryInvocation
    struct Commands: Sendable {
        var run: @Sendable (Invocation, @escaping @Sendable () async throws -> Void,
                           @escaping @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> AutomationOwnedCommand.Result
        var stop: @Sendable () async -> Bool
        var logs: @Sendable () async -> AutomationOwnedCommand.Result
        static func owned() -> Self {
            let command = AutomationOwnedCommand()
            return .init(run: { invocation, willStart, didStart in
                try await command.run(executable: invocation.executable, arguments: invocation.arguments,
                    directory: invocation.directory, environment: invocation.environment, timeout: invocation.timeout,
                    willStart: willStart, didStart: didStart)
            }, stop: { await command.stopOwned() }, logs: { await command.retainedLogs() })
        }
    }
    private let workspace: URL
    private let developerDirectory: URL
    private let commands: Commands
    private var busy = false
    private var unproved = false
    public init(workspace: URL, developerDirectory: URL) throws {
        self.workspace = try AutomationPath.canonical(workspace)
        self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        commands = .owned()
    }
    init(workspace: URL, developerDirectory: URL, commands: Commands) throws {
        self.workspace = try AutomationPath.canonical(workspace)
        self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        self.commands = commands
    }
    /// Caller retains/releases the lease; unresolved native commands must keep it fenced.
    public func install(selected: AutomationInstalledUIApplication, approval: RunApproval,
                        lease: AutomationDeviceLeaseManager.Lease, scope: AutomationScope,
                        leases: AutomationDeviceLeaseManager, journal: AutomationJournal,
                        allowInstall: Bool, expectedDeviceIdentifier: String? = nil,
                        campaignBudget: AutomationCampaignBudget? = nil) async throws -> AutomationPhysicalInstallationReceipt {
        guard !busy, !unproved, allowInstall, selected.app == approval.app, selected.target == approval.target,
              lease.target == selected.target, lease.runID == approval.runID, lease.control == .system,
              scope.runId == approval.runID, scope.leaseGeneration == lease.generation,
              scope.segmentId == "prepare.install", approval.maximumActions > 0 else { throw AutomationContractError.invalidIdentity }
        try scope.validate(); try AutomationPhysicalExecutable.validateTarget(selected.target)
        guard expectedDeviceIdentifier == nil || UUID(uuidString: expectedDeviceIdentifier!) != nil else { throw AutomationContractError.invalidIdentity }
        try await campaignBudget?.available(); try Task.checkCancellation()
        busy = true; defer { busy = false }
        try await leases.validate(lease)
        let operationID = scope.attemptId + ".prepare.install"
        let state = workspace.appendingPathComponent("physical-install-" + UUID().uuidString)
        let staged = try AutomationPhysicalInstallPayload.stage(selected, into: state)
        let willStart: @Sendable () async throws -> Void = {
            try await leases.validate(lease); try await campaignBudget?.available(); try Task.checkCancellation()
        }
        let didStart: @Sendable (AutomationProcessIdentity) async throws -> Void = { process in
            try await leases.recordRunner(.init(scope: scope, process: process, role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease)
        }
        do {
            let before = try await inventory(selected.target, state: state, name: "before", willStart: willStart, didStart: didStart, campaignBudget: campaignBudget)
            guard expectedDeviceIdentifier == nil || before.inventory.deviceIdentifier == expectedDeviceIdentifier else { throw AutomationContractError.conflictingOperation }
            let arguments = ["devicectl", "device", "install", "app", "--device", selected.target.id, staged.path, "--timeout", "60", "--quiet"]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let binding = try encoder.encode(InstallBinding(scope: scope, app: selected.app, target: selected.target,
                developerDirectory: developerDirectory.path, arguments: arguments, deviceIdentifier: before.inventory.deviceIdentifier))
            let digest = AutomationArtifactRegistry.digest(binding)
            guard try await journal.begin(operationID: operationID, digest: digest) == nil else { throw AutomationContractError.ambiguousDispatch }
            try await leases.recordDispatch(.init(scope: scope, operationID: operationID, payloadDigest: digest), lease: lease)
            let result = try await invoke(arguments, state: state, timeout: .seconds(65), willStart: {
                try await willStart()
                guard try AutomationProductDigest.compute(bundle: staged, version: selected.app.productDigestVersion) == selected.app.productDigest else {
                    throw AutomationContractError.conflictingOperation
                }
            }, didStart: didStart, campaignBudget: campaignBudget)
            try retain(result, state: state, name: "install")
            guard result.exitStatus == 0, !result.logsTruncated else { throw AutomationContractError.missingEvidence("Physical install command did not complete") }
            let after = try await inventory(selected.target, state: state, name: "after", willStart: willStart, didStart: didStart, campaignBudget: campaignBudget)
            guard before.inventory.deviceIdentifier == after.inventory.deviceIdentifier,
                  let installed = after.inventory.apps.first(where: { $0.bundleIdentifier == selected.app.bundleID }),
                  try AutomationProductDigest.compute(bundle: staged, version: selected.app.productDigestVersion) == selected.app.productDigest else {
                throw AutomationContractError.conflictingOperation
            }
            guard await commands.stop() else { unproved = true; throw AutomationContractError.terminationUnverified }
            let receipt = AutomationPhysicalInstallationReceipt(schemaVersion: 1, scope: scope, app: selected.app,
                target: selected.target, developerDirectory: developerDirectory.path, deviceIdentifier: after.inventory.deviceIdentifier,
                installedBundleURL: installed.url, stagedBundlePath: staged.path, commandArguments: arguments,
                commandExitStatus: result.exitStatus, stdoutSHA256: AutomationArtifactRegistry.digest(result.stdout),
                stderrSHA256: AutomationArtifactRegistry.digest(result.stderr), beforeInventorySHA256: AutomationArtifactRegistry.digest(before.data),
                afterInventorySHA256: AutomationArtifactRegistry.digest(after.data))
            try persist(encoder.encode(receipt), state: state, name: "receipt.json")
            try await journal.complete(operationID: operationID, digest: digest, response: .object([
                "receiptSHA256": .text(AutomationArtifactRegistry.digest(try encoder.encode(receipt))),
                "installedBytesVerified": .bool(false)]))
            return receipt
        } catch {
            let logs = await commands.logs()
            try? retain(logs, state: state, name: "failure")
            if !(await commands.stop()) { unproved = true }
            throw error
        }
    }
    public func drain() async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        if !(await commands.stop()) { unproved = true }
        return !unproved
    }
    private struct InstallBinding: Codable {
        let scope: AutomationScope; let app: AppIdentity; let target: TargetIdentity
        let developerDirectory: String; let arguments: [String]; let deviceIdentifier: String
    }
    private func invoke(_ arguments: [String], state: URL, timeout: Duration,
                        willStart: @escaping @Sendable () async throws -> Void,
                        didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void,
                        campaignBudget: AutomationCampaignBudget?) async throws -> AutomationOwnedCommand.Result {
        let boundedTimeout = min(timeout, try await campaignBudget?.remainingDuration() ?? timeout)
        return try await commands.run(.init(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments,
            directory: state, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path,
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: boundedTimeout), willStart, didStart)
    }
    private func inventory(_ target: TargetIdentity, state: URL, name: String,
                           willStart: @escaping @Sendable () async throws -> Void,
                           didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void,
                           campaignBudget: AutomationCampaignBudget?) async throws -> (inventory: AutomationPhysicalAppInventory, data: Data) {
        let output = state.appendingPathComponent(name + "-apps.json")
        let result = try await invoke(["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps",
            "--json-output", output.path, "--timeout", "10", "--quiet"], state: state, timeout: .seconds(15), willStart: willStart, didStart: didStart, campaignBudget: campaignBudget)
        try retain(result, state: state, name: name)
        guard result.exitStatus == 0, !result.logsTruncated,
              let data = try AutomationDurableFile(url: output, maximumBytes: 2_097_152).read() else { throw AutomationContractError.terminationUnverified }
        return (try AutomationPhysicalAppInventory.parse(data, targetID: target.id, expectedOutputURL: output), data)
    }
    private func retain(_ result: AutomationOwnedCommand.Result, state: URL, name: String) throws {
        try persist(result.stdout, state: state, name: name + ".stdout")
        try persist(result.stderr, state: state, name: name + ".stderr")
        try persist(JSONEncoder().encode(CommandOutcome(exitStatus: result.exitStatus, logsTruncated: result.logsTruncated)), state: state, name: name + ".outcome.json")
    }
    private struct CommandOutcome: Codable { let exitStatus: Int32; let logsTruncated: Bool }
    private func persist(_ data: Data, state: URL, name: String) throws {
        let file = try AutomationDurableFile(url: state.appendingPathComponent(name), maximumBytes: 16_777_216)
        try file.withLock { try file.write(data) }
    }
}
#endif
