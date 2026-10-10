import Foundation

/// An observed bundle on a physical device. Local payload and installed-byte digests remain unknown.
public struct AutomationPhysicalInstalledUIApplication: Sendable {
    public let app: AppIdentity
    public let target: TargetIdentity
    public let deviceIdentifier: String
    public let installedBundleURL: String
    public init(bundleID: String, target: TargetIdentity, inventory: AutomationPhysicalAppInventory) throws {
        try AutomationPhysicalExecutable.validateTarget(target)
        guard bundleID.utf8.count <= 256, bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil,
              inventory.targetID == target.id, UUID(uuidString: inventory.deviceIdentifier) != nil,
              inventory.apps.filter({ $0.bundleIdentifier == bundleID }).count == 1,
              let installed = inventory.apps.first(where: { $0.bundleIdentifier == bundleID }) else { throw AutomationContractError.invalidIdentity }
        app = .init(logicalID: "installed:" + bundleID, bundleID: bundleID, platform: "ios")
        self.target = target; deviceIdentifier = inventory.deviceIdentifier; installedBundleURL = installed.url
    }
    #if os(macOS)
    /// The owned install acknowledges selected local bytes, but remote bytes remain
    /// unreadable. Deliberately produce the weak installed identity for UI readback.
    init(installation: AutomationPhysicalInstallationReceipt, selected: AutomationInstalledUIApplication) throws {
        try selected.verifySelectedProduct(); try installation.scope.validate()
        guard installation.schemaVersion == 1, installation.app == selected.app, installation.target == selected.target,
              installation.scope.segmentId == "prepare.install", installation.commandExitStatus == 0,
              installation.commandArguments == ["devicectl", "device", "install", "app", "--device", selected.target.id,
                installation.stagedBundlePath, "--timeout", "60", "--quiet"],
              !installation.installedBytesVerified, let url = URL(string: installation.installedBundleURL),
              url.isFileURL, url.path.hasPrefix("/"), url.path.hasSuffix(".app") else { throw AutomationContractError.invalidIdentity }
        try self.init(bundleID: selected.app.bundleID, target: selected.target,
            inventory: .init(targetID: selected.target.id, deviceIdentifier: installation.deviceIdentifier,
                apps: [.init(bundleIdentifier: selected.app.bundleID, url: installation.installedBundleURL)]))
    }
    #endif
}

#if os(macOS)
/// Positive installed-bundle presence under a pinned toolchain/device, with no remote-byte assertion.
public actor AutomationPhysicalInstalledSubjectVerifier: AutomationSubjectVerifier {
    typealias Invocation = AutomationPhysicalRunnerVerifier.InventoryInvocation
    private let selected: AutomationPhysicalInstalledUIApplication
    private let workspace: URL
    private let developerDirectory: URL
    private let commands: AutomationPhysicalRunnerVerifier.InventoryCommands
    private let didStart: @Sendable (AutomationProcessIdentity) async throws -> Void
    private var busy = false, unproved = false
    private var ordinal = 0
    public init(selected: AutomationPhysicalInstalledUIApplication, workspace: URL, developerDirectory: URL,
                didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) throws {
        self.selected = selected; self.workspace = try AutomationPath.canonical(workspace)
        self.developerDirectory = try AutomationPath.canonical(developerDirectory); self.didStart = didStart
        commands = .owned()
    }
    init(selected: AutomationPhysicalInstalledUIApplication, workspace: URL, developerDirectory: URL,
         commands: AutomationPhysicalRunnerVerifier.InventoryCommands,
         didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) throws {
        self.selected = selected; self.workspace = try AutomationPath.canonical(workspace)
        self.developerDirectory = try AutomationPath.canonical(developerDirectory); self.commands = commands; self.didStart = didStart
    }
    public func verify(app: AppIdentity, target: TargetIdentity) async throws {
        guard !busy, !unproved else { throw AutomationContractError.terminationUnverified }
        guard app == selected.app, target == selected.target, app.productDigest == nil, ordinal < 64 else { throw AutomationContractError.invalidIdentity }
        busy = true; defer { busy = false }
        ordinal += 1
        let output = workspace.appendingPathComponent("physical-subject-\(ordinal)-\(UUID().uuidString).json")
        let args = ["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps",
            "--json-output", output.path, "--timeout", "10", "--quiet"]
        do {
            let result = try await commands.run(.init(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: args,
                directory: workspace, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path],
                timeout: .seconds(15)), didStart)
            guard result.exitStatus == 0, !result.logsTruncated,
                  let data = try AutomationDurableFile(url: output, maximumBytes: 2_097_152).read() else { throw AutomationContractError.terminationUnverified }
            let inventory = try AutomationPhysicalAppInventory.parse(data, targetID: target.id, expectedOutputURL: output)
            guard inventory.deviceIdentifier == selected.deviceIdentifier,
                  inventory.apps.contains(where: { $0.bundleIdentifier == app.bundleID && $0.url == selected.installedBundleURL }) else {
                throw AutomationContractError.conflictingOperation
            }
            guard await commands.stop() else { unproved = true; throw AutomationContractError.terminationUnverified }
            let evidence: AutomationJSON = .object(["schemaVersion": .number(1), "app": try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(app)),
                "target": try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(target)),
                "deviceIdentifier": .string(inventory.deviceIdentifier), "installedBundleURL": .string(selected.installedBundleURL),
                "inventorySHA256": .string(AutomationArtifactRegistry.digest(data)), "installedBytesVerified": .bool(false),
                "evidenceScope": .string("installedBundlePresence")])
            let file = try AutomationDurableFile(url: workspace.appendingPathComponent("physical-subject-presence-\(ordinal).json"), maximumBytes: 32768)
            try file.withLock { try file.write(JSONEncoder().encode(evidence)) }
        } catch {
            if !(await commands.stop()) { unproved = true; throw AutomationContractError.terminationUnverified }
            throw error
        }
    }
    public func drain() async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        if !(await commands.stop()) { unproved = true }
        return !unproved
    }
}
#endif
