#if os(macOS)
import Foundation

/// Read-only physical-device verification. Never terminates a device process.
public actor AutomationPhysicalRunnerVerifier {
    struct InventoryInvocation: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
        let timeout: Duration
    }
    struct InventoryCommands: Sendable {
        let run: @Sendable (InventoryInvocation, @escaping @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> AutomationOwnedCommand.Result
        let stop: @Sendable () async -> Bool
        static func owned() -> Self {
            let command = AutomationOwnedCommand()
            return .init(run: { invocation, didStart in
                try await command.run(executable: invocation.executable, arguments: invocation.arguments,
                    directory: invocation.directory, environment: invocation.environment, timeout: invocation.timeout, didStart: didStart)
            }, stop: { await command.stopOwned() })
        }
    }
    public struct Controller: Codable, Equatable, Sendable {
        public var bundleID: String
        public var executableName: String
        public var ownedPID: Int32?
        public init(bundleID: String, executableName: String, ownedPID: Int32? = nil) {
            self.bundleID = bundleID; self.executableName = executableName; self.ownedPID = ownedPID
        }
        func validate() throws {
            try AutomationPhysicalControllerValidation.validate(bundleID: bundleID, executableName: executableName, ownedPID: ownedPID)
        }
    }
    public struct ControllerObservation: Codable, Equatable, Sendable {
        public var controller: Controller
        public var absent: Bool
        public init(controller: Controller, absent: Bool) { self.controller = controller; self.absent = absent }
    }
    public struct BatchObservation: Codable, Equatable, Sendable {
        public var targetID: String
        public var deviceIdentifier: String
        public var controllers: [ControllerObservation]
        public var appsSHA256: String
        public var processesSHA256: String
        public init(targetID: String, deviceIdentifier: String, controllers: [ControllerObservation], appsSHA256: String, processesSHA256: String) {
            self.targetID = targetID; self.deviceIdentifier = deviceIdentifier; self.controllers = controllers
            self.appsSHA256 = appsSHA256; self.processesSHA256 = processesSHA256
        }
    }
    public struct Observation: Codable, Equatable, Sendable {
        public var targetID: String
        public var deviceIdentifier: String
        public var runnerAbsent: Bool
        public var appsSHA256: String
        public var processesSHA256: String
        public init(targetID: String, deviceIdentifier: String, runnerAbsent: Bool, appsSHA256: String, processesSHA256: String) {
            self.targetID = targetID; self.deviceIdentifier = deviceIdentifier; self.runnerAbsent = runnerAbsent
            self.appsSHA256 = appsSHA256; self.processesSHA256 = processesSHA256
        }
    }
    private let workspace: URL
    private let developerDirectory: URL?
    private let commands: InventoryCommands
    private var ordinal = 0
    private var unprovedInspector = false
    private var inspecting = false
    public init(workspace: URL, developerDirectory: URL? = nil) throws {
        try Self.validateSetup(workspace: workspace, developerDirectory: developerDirectory)
        self.workspace = workspace; self.developerDirectory = developerDirectory; commands = .owned()
    }
    // Internal command seam tests the actual composition/parsing/drain boundary without touching hardware.
    init(workspace: URL, developerDirectory: URL?, commands: InventoryCommands) throws {
        try Self.validateSetup(workspace: workspace, developerDirectory: developerDirectory)
        self.workspace = workspace; self.developerDirectory = developerDirectory; self.commands = commands
    }
    private static func validateSetup(workspace: URL, developerDirectory: URL?) throws {
        guard try AutomationPath.canonical(workspace).path == workspace.path,
              try workspace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AutomationContractError.invalidIdentity
        }
        if let developerDirectory {
            guard try AutomationPath.canonical(developerDirectory).path == developerDirectory.path,
                  try developerDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw AutomationContractError.invalidIdentity
            }
        }
    }
    public func inspect(target: TargetIdentity, runnerBundleID: String, executableName: String, ownedPID: Int32? = nil,
                        didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) async throws -> Observation {
        let batch = try await inspect(target: target, controllers: [.init(bundleID: runnerBundleID, executableName: executableName, ownedPID: ownedPID)], didStart: didStart)
        let observation = Observation(targetID: batch.targetID, deviceIdentifier: batch.deviceIdentifier,
            runnerAbsent: batch.controllers[0].absent, appsSHA256: batch.appsSHA256, processesSHA256: batch.processesSHA256)
        let file = try AutomationDurableFile(url: workspace.appendingPathComponent("physical-inspection-\(ordinal).json"), maximumBytes: 4096)
        try file.withLock { try file.write(JSONEncoder().encode(observation)) }
        return observation
    }
    public func inspect(target: TargetIdentity, controllers: [Controller],
                        didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) async throws -> BatchObservation {
        guard target.kind == .physical, !unprovedInspector, !inspecting, (1...10).contains(controllers.count),
              Set(controllers.map(\.bundleID)).count == controllers.count else { throw AutomationContractError.terminationUnverified }
        inspecting = true; defer { inspecting = false }
        for controller in controllers { try controller.validate() }
        let appsResult = try await inventory("apps", targetID: target.id, didStart: didStart), appsData = appsResult.data
        let apps = try AutomationPhysicalAppInventory.parse(appsData, targetID: target.id, expectedOutputURL: appsResult.outputURL)
        let processResult = try await inventory("processes", targetID: target.id, didStart: didStart), processData = processResult.data
        let processes = try AutomationPhysicalProcessInventory.parse(processData, targetID: target.id, expectedOutputURL: processResult.outputURL)
        let observation = BatchObservation(targetID: target.id, deviceIdentifier: processes.deviceIdentifier,
            controllers: try controllers.map { controller in
                .init(controller: controller, absent: try processes.runnerAbsent(bundleID: controller.bundleID,
                    executableName: controller.executableName, ownedPID: controller.ownedPID, apps: apps))
            },
            appsSHA256: AutomationArtifactRegistry.digest(appsData), processesSHA256: AutomationArtifactRegistry.digest(processData))
        let file = try AutomationDurableFile(url: workspace.appendingPathComponent("physical-batch-inspection-\(ordinal).json"), maximumBytes: 32768)
        try file.withLock { try file.write(JSONEncoder().encode(observation)) }
        return observation
    }
    public func drainInspector() async -> Bool {
        let stopped = await commands.stop()
        if !stopped { unprovedInspector = true }
        return stopped && !unprovedInspector
    }
    private func inventory(_ kind: String, targetID: String, didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> (data: Data, outputURL: URL) {
        guard !unprovedInspector, ordinal < 8, targetID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        ordinal += 1
        let url = workspace.appendingPathComponent("physical-\(kind)-\(ordinal)-\(UUID().uuidString).json")
        let arguments = ["devicectl", "device", "info", kind, "--device", targetID]
            + (kind == "apps" ? ["--include-all-apps"] : [])
            + ["--json-output", url.path, "--timeout", "10", "--quiet"]
        do {
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            if let developerDirectory { environment["DEVELOPER_DIR"] = developerDirectory.path }
            let invocation = InventoryInvocation(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments,
                directory: workspace, environment: environment, timeout: .seconds(15))
            let result = try await commands.run(invocation, didStart)
            guard result.exitStatus == 0, !result.logsTruncated,
                  let data = try AutomationDurableFile(url: url, maximumBytes: 2_097_152).read() else {
                throw AutomationContractError.terminationUnverified
            }
            return (data, url)
        } catch {
            if !(await commands.stop()) { unprovedInspector = true }
            throw error
        }
    }
}
#endif
