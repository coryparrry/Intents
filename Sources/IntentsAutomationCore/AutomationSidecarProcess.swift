#if os(macOS) || os(Linux)
import Foundation

private actor AutomationPipeWriter {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() { try? handle.close() }
}

/// Owns one packaged Node child; never uses a shell or inherits the user's environment.
public actor AutomationSidecarProcess {
    public struct Configuration: Sendable {
        public var node: URL
        public var entry: URL
        public var stateDirectory: URL
        public var helper: URL?
        public var developerDirectory: URL?
        public var privateMacDaemon: Bool
        public var retainDiagnostics: Bool
        public init(node: URL, entry: URL, stateDirectory: URL, helper: URL? = nil, developerDirectory: URL? = nil, privateMacDaemon: Bool = false, retainDiagnostics: Bool = true) {
            self.node = node; self.entry = entry; self.stateDirectory = stateDirectory; self.helper = helper
            self.developerDirectory = developerDirectory; self.privateMacDaemon = privateMacDaemon
            self.retainDiagnostics = retainDiagnostics
        }
    }
    private let process: Process
    private let writer: AutomationPipeWriter
    public let rpc: AutomationRPC
    private let input: Pipe, output: Pipe, diagnostics: Pipe
    private var reader: Task<Void, Never>?
    private var diagnosticReader: Task<Void, Never>?
    private var diagnosticBytes = Data()
    private let retainDiagnostics: Bool
    public private(set) var processID: Int32 = 0
    public private(set) var processIdentity: AutomationProcessIdentity?

    private let exitGracePeriod: Duration
    private let terminationGracePeriod: Duration

    public init(configuration: Configuration, reverse: @escaping AutomationRPC.ReverseHandler) throws {
        try self.init(configuration: configuration, reverse: reverse, exitGracePeriod: .seconds(10), terminationGracePeriod: .seconds(5))
    }
    init(configuration: Configuration, reverse: @escaping AutomationRPC.ReverseHandler,
         exitGracePeriod: Duration, terminationGracePeriod: Duration) throws {
        retainDiagnostics = configuration.retainDiagnostics
        self.exitGracePeriod = exitGracePeriod; self.terminationGracePeriod = terminationGracePeriod
        for path in [configuration.node, configuration.entry] + (configuration.helper.map { [$0] } ?? []) {
            guard path.isFileURL, path.path == (try AutomationPath.canonical(path)).path,
                  FileManager.default.fileExists(atPath: path.path) else { throw AutomationContractError.invalidIdentity }
        }
        guard configuration.stateDirectory.isFileURL else { throw AutomationContractError.invalidIdentity }
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        guard configuration.stateDirectory.path == (try AutomationPath.canonical(configuration.stateDirectory)).path else { throw AutomationContractError.invalidIdentity }
        input = Pipe(); output = Pipe(); diagnostics = Pipe()
        writer = AutomationPipeWriter(input.fileHandleForWriting)
        let pipeWriter = writer
        rpc = AutomationRPC(send: { data in try await pipeWriter.write(data) }, reverse: reverse)
        process = Process()
        process.executableURL = configuration.node
        process.arguments = [configuration.entry.path, "--state-dir", configuration.stateDirectory.path]
        process.currentDirectoryURL = configuration.stateDirectory
        process.environment = try Self.environment(configuration)
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
    }
    static func environment(_ configuration: Configuration) throws -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": configuration.stateDirectory.path,
                               "TMPDIR": NSTemporaryDirectory(), "AGENT_DEVICE_NO_UPDATE_NOTIFIER": "1",
                               "AGENT_DEVICE_STATE_DIR": configuration.stateDirectory.path]
        if configuration.privateMacDaemon {
            environment["AGENT_DEVICE_CLAIMS_DIR"] = configuration.stateDirectory.appendingPathComponent("owned-mac/claims").path
        }
        if let helper = configuration.helper { environment["AGENT_DEVICE_MACOS_HELPER_BIN"] = helper.path }
        if let developer = configuration.developerDirectory {
            guard developer.isFileURL, developer.path == (try AutomationPath.canonical(developer)).path else { throw AutomationContractError.invalidIdentity }
            guard try FileManager.default.attributesOfItem(atPath: developer.path)[.type] as? FileAttributeType == .typeDirectory else { throw AutomationContractError.invalidIdentity }
            environment["DEVELOPER_DIR"] = developer.path
        }
        return environment
    }
    public func start() throws {
        guard processID == 0 else { throw AutomationContractError.targetBusy }
        try process.run(); processID = process.processIdentifier
        processIdentity = AutomationProcessIdentity.inspect(pid: processID)
        let frames = Self.stream(output.fileHandleForReading), logs = Self.stream(diagnostics.fileHandleForReading), endpoint = rpc
        reader = Task {
            for await bytes in frames {
                do { try await endpoint.receive(bytes) } catch { break }
            }
            await endpoint.close()
        }
        diagnosticReader = Task {
            for await bytes in logs { appendDiagnostics(bytes) }
        }
    }
    public func handshake() async throws -> AutomationJSON {
        let result = try await rpc.request(.hello, params: .object(["protocolVersion": .number(1)]))
        guard result.object?["protocolVersion"] == .number(1), result.object?["adapterVersion"] == .string("0.1.0") else {
            throw AutomationRPCError.invalidFrame
        }
        return result
    }
    public func stop() async -> Bool {
        await Task.detached { await self.stopOwnedChild() }.value
    }
    private func stopOwnedChild() async -> Bool {
        await writer.close()
        // EOF gives the sidecar a chance to drain its owned workers first.
        let deadline = ContinuousClock.now.advanced(by: exitGracePeriod)
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            if processIdentity?.presence() == .matching { process.terminate() }
        }
        let terminationDeadline = ContinuousClock.now.advanced(by: terminationGracePeriod)
        while process.isRunning && ContinuousClock.now < terminationDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        await rpc.close(); reader?.cancel(); diagnosticReader?.cancel()
        return !process.isRunning
    }
    public func diagnosticsSummary() -> String { String(decoding: diagnosticBytes, as: UTF8.self) }
    private func appendDiagnostics(_ data: Data) {
        guard retainDiagnostics else { return }
        diagnosticBytes.append(data)
        if diagnosticBytes.count > 262_144 { diagnosticBytes.removeFirst(diagnosticBytes.count - 262_144) }
    }
    private static func stream(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            handle.readabilityHandler = { file in
                let bytes = file.availableData
                if bytes.isEmpty { file.readabilityHandler = nil; continuation.finish() }
                else if case .dropped = continuation.yield(bytes) { file.readabilityHandler = nil; continuation.finish() }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }
}
#endif
