#if os(macOS)
import Foundation
import Darwin

private final class AutomationJavaScriptNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One scoped leaf process per use. An already listening or racing endpoint is
/// rejected. Forking and outbound network are denied by the process sandbox.
public actor AutomationServedJavaScriptSupervisor {
    private let command = AutomationOwnedCommand()
    private var identity: AutomationProcessIdentity?
    private var worker: Task<AutomationOwnedCommand.Result, any Error>?
    private var active = false
    private var releaseUnverified = false
    private var finalized = false
    private var currentLog: URL?
    private var nodeConfiguration: URL?
    private var probeToken: String?
    private var consumer: AutomationMetroNativeConsumer?
    private var consumerTask: Task<Void, Never>?
    private var consumerRequired = false
    private var consumedResponses: [String: String]?
    private var stage = "idle"
    private var lastListeners: [Listener] = []
    private var lastHTTPStatus: Int?
    private var lastResponseSHA256: String?
    private var lastListenerCensus = ""
    public init() {}
    public func cancelOwned() async -> Bool { worker?.cancel(); return await command.stopOwned() }

    public func withSession<Value: Sendable>(profile: AutomationServedJavaScriptProfile, manifest: AutomationSourceManifest,
        app: AppIdentity, target: TargetIdentity, frozenRoot: URL, developerDirectory: URL, supportRoot: URL,
        expected: AutomationServedJavaScriptIdentity? = nil,
        requiresNativeConsumer: Bool = false,
        operationTimeout: Duration = .seconds(240),
        campaignDeadline: ContinuousClock.Instant? = nil,
        operation: @escaping @Sendable (AutomationServedJavaScriptIdentity) async throws -> Value) async throws -> Value {
        guard !active, !releaseUnverified, worker == nil, target.kind == .simulator,
              operationTimeout > .zero,
              app.sourceManifestDigest == (try manifest.digest), let product = app.productDigest else {
            throw AutomationContractError.invalidIdentity
        }
        let timing = AutomationJavaScriptSessionTiming(operationTimeout: operationTimeout, campaignDeadline: campaignDeadline)
        active = true; finalized = false; defer { active = false }
        stage = "verify-executable"; lastListeners = []; lastHTTPStatus = nil; lastResponseSHA256 = nil; lastListenerCensus = ""
        try profile.verifyExecutable()
        stage = "verify-native-product"
        try profile.validateNativeProduct(app: app)
        stage = "verify-frozen-inputs"
        var script = try profile.verifyFrozenInputs(manifest: manifest, frozenRoot: frozenRoot)
        let session = supportRoot.appendingPathComponent("served-js-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try AutomationPath.canonical(session).path == session.path else { throw AutomationContractError.invalidIdentity }
        currentLog = session.appendingPathComponent("server.log")
        let configuration = try Self.writeNodeConfiguration(session: session)
        nodeConfiguration = configuration
        var reservation = try Self.reserve(port: profile.port)
        defer { if reservation >= 0 { Darwin.close(reservation) } }
        guard try await listeners(port: profile.port).isEmpty else { throw AutomationContractError.conflictingOperation }
        let sandbox = Self.sandbox(profile: profile, root: frozenRoot, temporary: session)
        var environment = Self.childEnvironment(profile: profile, session: session, developerDirectory: developerDirectory, configuration: configuration)
        var scriptArguments = profile.arguments
        if let recipe = profile.automaticMetro {
            let generated = try AutomationMetroBootstrap.write(recipe: recipe, manifest: manifest, frozenRoot: frozenRoot, profile: profile, session: session)
            script = generated.0; scriptArguments = [generated.1.path]
            let token = UUID().uuidString; probeToken = token; environment["INTENTS_JS_TOKEN"] = token
            environment["NODE_ENV"] = "development"; environment["EXPO_NO_TELEMETRY"] = "1"
        } else { probeToken = nil }
        // Hold the socket until immediately before spawning; ownership is checked
        // again after readiness to reject the remaining close-to-bind race.
        Darwin.close(reservation)
        reservation = -1
        let childCommand = command
        let launchScript = script, launchEnvironment = environment, launchArguments = scriptArguments
        worker = Task {
            try await childCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", sandbox, profile.executablePath, launchScript.path] + launchArguments,
                directory: frozenRoot, environment: launchEnvironment, timeout: timing.workerTimeout(automaticMetro: profile.automaticMetro != nil),
                didStart: { started in await self.started(started) })
        }
        let operationGate = AutomationBoundedTask<Value>()
        do {
            stage = "await-owned-listener"
            let deadline = ContinuousClock.now.advanced(by: profile.automaticMetro == nil ? .seconds(10) : .seconds(120))
            var verified = false
            var boundProfile = profile
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let identity {
                    guard identity.presence() == .matching else { throw await startupFailure() }
                    let owners = try await listeners(port: profile.port)
                    if !owners.isEmpty {
                        stage = "validate-owned-listener"
                        do { try Self.validateListener(owners, identity: identity, port: profile.port) }
                        catch { throw AutomationContractError.missingEvidence("The owned JavaScript listener did not match its child PID or loopback endpoint: " + owners.map { String($0.pid) + " " + $0.endpoint }.joined(separator: "; ")) }
                        stage = "observe-pinned-executable"
                        let inventory = try AutomationMacProcessInventory.currentUser(watchedExecutablePaths: [profile.executablePath])
                        try inventory.validate(expectedUserID: getuid(), matchingExecutablePaths: [profile.executablePath])
                        guard inventory.processes.contains(where: { $0.identity == identity && $0.executablePath == profile.executablePath }) else {
                            throw AutomationContractError.missingEvidence("The JavaScript listener's kernel identity did not match the pinned Node executable.")
                        }
                        stage = "verify-initial-response"
                        let digest = try await verifyResponse(profile)
                        if boundProfile.bundleSHA256.isEmpty { boundProfile.bundleSHA256 = digest }
                        try Self.validateListener(try await listeners(port: profile.port), identity: identity, port: profile.port)
                        verified = true; break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard verified else { throw AutomationRPCError.timedOut }
            stage = "bind-session-identity"
            try Self.verifyNodeConfiguration(configuration)
            let observed = AutomationServedJavaScriptIdentity(profileDigest: try boundProfile.digest, sourceManifestDigest: try manifest.digest,
                nativeProductDigest: product, bundleURL: profile.bundleURL, bundleSHA256: boundProfile.bundleSHA256,
                nodeConfigurationSHA256: Self.nodeConfigurationSHA256)
            guard expected == nil || expected == observed else { throw AutomationContractError.conflictingOperation }
            consumedResponses = nil; consumerRequired = requiresNativeConsumer
            if boundProfile.automaticMetro != nil {
                guard let probeToken else { throw AutomationContractError.invalidIdentity }
                let monitor = AutomationMetroNativeConsumer(profile: boundProfile, app: app, target: target, token: probeToken, workspace: session)
                consumer = monitor; consumerTask = Task { await monitor.monitor() }
            }
            stage = "operation"
            let result = try await operationGate.run(until: timing.operationDeadline(at: .now)) { try await operation(observed) }
            try Task.checkCancellation()
            if !finalized { try await finishCurrent(profile: boundProfile, manifest: manifest, frozenRoot: frozenRoot) }
            return result
        } catch {
            let original = error
            try? retainFailure(session: session, profile: profile, error: original)
            // Cleanup is uncancelled and bounded even when the caller cancelled.
            let drained = await Task.detached { await operationGate.cancelAndDrain(until: .now.advanced(by: .seconds(5))) }.value
            try await Task.detached { try await self.dispose(port: profile.port, log: session.appendingPathComponent("server.log")) }.value
            guard drained else { releaseUnverified = true; throw AutomationContractError.terminationUnverified }
            throw original
        }
    }
    /// Called before an attempt can publish its immutable report or live authority.
    func finishCurrent(profile: AutomationServedJavaScriptProfile, manifest: AutomationSourceManifest, frozenRoot: URL) async throws {
        guard active, !finalized, let log = currentLog, let configuration = nodeConfiguration else { throw AutomationContractError.invalidIdentity }
        do {
            stage = "finalize-native-consumers"
            if let consumer {
                await consumer.requestStop()
                if let consumerTask {
                    _ = try await AutomationBoundedTask<Bool>().run(until: .now.advanced(by: .seconds(15))) { await consumerTask.value; return true }
                }
                consumedResponses = try await consumer.validateConsumed(required: consumerRequired)
            }
            stage = "finalize-response"
            try await verifyCurrent(profile: profile)
            stage = "finalize-node-configuration"
            try Self.verifyNodeConfiguration(configuration)
            stage = "finalize-frozen-inputs"
            _ = try profile.verifyFrozenInputs(manifest: manifest, frozenRoot: frozenRoot)
        } catch {
            let original = error
            try? retainFailure(session: log.deletingLastPathComponent(), profile: profile, error: original)
            do { try await Task.detached { try await self.dispose(port: profile.port, log: log) }.value }
            catch { releaseUnverified = true; finalized = true; throw AutomationContractError.terminationUnverified }
            finalized = true
            throw original
        }
        do {
            stage = "release-owned-server"
            try await Task.detached { try await self.dispose(port: profile.port, log: log) }.value
            // Shutdown handlers must be finished before immutable publication;
            // recheck even though the sandbox also denies writes to this input.
            stage = "verify-released-node-configuration"
            try Self.verifyNodeConfiguration(configuration)
        }
        catch {
            try? retainFailure(session: log.deletingLastPathComponent(), profile: profile, error: error)
            releaseUnverified = true; finalized = true; throw AutomationContractError.terminationUnverified
        }
        finalized = true
    }
    func responseEvidence() -> [String: String]? { consumedResponses }
    private func started(_ value: AutomationProcessIdentity) { identity = value }
    private func retainFailure(session: URL, profile: AutomationServedJavaScriptProfile, error: any Error) throws {
        let file = session.appendingPathComponent("failure.json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var facts = ["stage": stage, "error": String(String(describing: error).prefix(2048)),
                     "expectedExecutable": profile.executablePath, "expectedEndpoint": profile.bundleURL,
                     "listeners": lastListeners.map { String($0.pid) + " " + $0.endpoint }.joined(separator: "; "),
                     "listenerCensus": lastListenerCensus]
        if let identity {
            facts["pid"] = String(identity.pid); facts["startIdentity"] = identity.startIdentity
            facts["presence"] = String(describing: identity.presence())
        }
        if let lastHTTPStatus { facts["httpStatus"] = String(lastHTTPStatus) }
        facts["responseSHA256"] = lastResponseSHA256
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try AutomationDurableFile(url: file, maximumBytes: 16_384).write(encoder.encode(facts))
    }
    private func startupFailure() async -> AutomationContractError {
        var logs = await command.retainedLogs()
        if let worker, let result = try? await AutomationBoundedTask<AutomationOwnedCommand.Result>().run(until: .now.advanced(by: .seconds(2)), operation: { try await worker.value }) {
            logs = result
        }
        let diagnostic = String(decoding: logs.stderr.suffix(2048), as: UTF8.self)
        return .missingEvidence("The owned JavaScript server exited before readiness (exit \(logs.exitStatus)). " + diagnostic)
    }
    private func verifyCurrent(profile: AutomationServedJavaScriptProfile) async throws {
        guard let identity, identity.presence() == .matching else { throw AutomationContractError.conflictingOperation }
        try Self.validateListener(try await listeners(port: profile.port), identity: identity, port: profile.port)
        _ = try await verifyResponse(profile)
        try Self.validateListener(try await listeners(port: profile.port), identity: identity, port: profile.port)
        guard identity.presence() == .matching else { throw AutomationContractError.conflictingOperation }
    }
    private func dispose(port: Int, log: URL) async throws {
        consumerTask?.cancel()
        if let consumerTask {
            _ = try await AutomationBoundedTask<Bool>().run(until: .now.advanced(by: .seconds(5))) { await consumerTask.value; return true }
        }
        consumerTask = nil; consumer = nil
        worker?.cancel()
        guard await command.stopOwned() else { throw AutomationContractError.terminationUnverified }
        if let worker {
            _ = try await AutomationBoundedTask<Bool>().run(until: .now.advanced(by: .seconds(5))) {
                _ = await worker.result; return true
            }
        }
        let retained = await command.retainedLogs()
        try AutomationDurableFile(url: log, maximumBytes: 4_194_304).write(retained.stdout + retained.stderr)
        guard identity?.presence() != .matching, try await listeners(port: port).isEmpty else {
            throw AutomationContractError.terminationUnverified
        }
        worker = nil; identity = nil; nodeConfiguration = nil
    }
    struct Listener: Equatable, Sendable { let pid: Int32; let endpoint: String }
    static func parseListeners(_ bytes: Data) throws -> [Listener] {
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else { throw AutomationContractError.invalidIdentity }
        var pid: Int32?, descriptor: Int32?, result: [Listener] = []
        for line in text.split(separator: "\n") {
            if line.first == "p" {
                guard descriptor == nil, let value = Int32(line.dropFirst()), value > 0,
                      String(value) == line.dropFirst() else { throw AutomationContractError.invalidIdentity }
                pid = value
            } else if line.first == "f" {
                // macOS lsof always emits file-descriptor records, including
                // with -Fpn. A TCP census must describe a numeric socket fd.
                guard pid != nil, descriptor == nil, let value = Int32(line.dropFirst()), value >= 0,
                      String(value) == line.dropFirst() else { throw AutomationContractError.invalidIdentity }
                descriptor = value
            } else if line.first == "n" {
                guard let pid, descriptor != nil, line.count > 1 else { throw AutomationContractError.invalidIdentity }
                result.append(.init(pid: pid, endpoint: String(line.dropFirst()))); descriptor = nil
            }
            else { throw AutomationContractError.invalidIdentity }
        }
        guard descriptor == nil else { throw AutomationContractError.invalidIdentity }
        return result
    }
    static func validateListener(_ owners: [Listener], identity: AutomationProcessIdentity, port: Int) throws {
        guard owners.count == 1, owners[0] == .init(pid: identity.pid, endpoint: "127.0.0.1:" + String(port)) else {
            throw AutomationContractError.conflictingOperation
        }
    }
    private func listeners(port: Int) async throws -> [Listener] {
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-iTCP:" + String(port), "-sTCP:LISTEN", "-Fpn"],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(3))
        guard !result.logsTruncated, result.stderr.isEmpty, result.exitStatus == 0 || (result.exitStatus == 1 && result.stdout.isEmpty) else {
            throw AutomationContractError.missingEvidence("The loopback listener ownership census is unavailable.")
        }
        lastListenerCensus = String(decoding: result.stdout.prefix(4096), as: UTF8.self)
        let owners = try Self.parseListeners(result.stdout)
        lastListeners = owners
        return owners
    }
    static func reserve(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationContractError.invalidIdentity }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard status == 0 else { Darwin.close(fd); throw AutomationContractError.conflictingOperation }
        return fd
    }
    static func validateResponse(profile: AutomationServedJavaScriptProfile, response: HTTPURLResponse, bytes: Data) throws {
        guard response.url?.absoluteString == profile.bundleURL, response.statusCode == 200, !bytes.isEmpty,
              bytes.count <= 32 * 1024 * 1024 else {
            throw AutomationContractError.missingEvidence("The owned JavaScript server returned a redirected, unsuccessful, empty or oversized bundle response.")
        }
        guard AutomationArtifactRegistry.digest(bytes) == profile.bundleSHA256 || (profile.automaticMetro != nil && profile.bundleSHA256.isEmpty) else { throw AutomationContractError.conflictingOperation }
    }
    private func verifyResponse(_ profile: AutomationServedJavaScriptProfile) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = profile.automaticMetro == nil ? 3 : 90
        configuration.timeoutIntervalForResource = profile.automaticMetro == nil ? 5 : 120
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: AutomationJavaScriptNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: profile.endpoint); request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let probeToken { request.setValue(probeToken, forHTTPHeaderField: "X-Intents-Probe") }
        let (stream, reply) = try await session.bytes(for: request)
        guard let response = reply as? HTTPURLResponse else { throw AutomationContractError.invalidIdentity }
        lastHTTPStatus = response.statusCode
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 32 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            data.append(byte)
        }
        lastResponseSHA256 = AutomationArtifactRegistry.digest(data)
        try Self.validateResponse(profile: profile, response: response, bytes: data)
        return AutomationArtifactRegistry.digest(data)
    }
    static func sandbox(profile: AutomationServedJavaScriptProfile, root: URL, temporary: URL) -> String {
        func literal(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        // Seatbelt's `local ip` grammar accepts localhost or *, rather than a
        // numeric host. Keep its exact port; the server itself and the kernel
        // ownership census still require the numeric 127.0.0.1 endpoint.
        let endpoint = literal("localhost:" + String(profile.port))
        let tool = URL(fileURLWithPath: profile.executablePath).deletingLastPathComponent().deletingLastPathComponent().path
        return "(version 1) (deny default) (allow process-exec (literal " + literal(profile.executablePath) + ")) " +
            "(deny process-fork) (allow sysctl-read) (allow mach-lookup) (allow file-read-metadata) " +
            "(allow file-read* (literal \"/\") " + [root.path, temporary.path, tool, "/System", "/usr", "/bin", "/dev", "/opt/homebrew/lib", "/opt/homebrew/Cellar", "/private/var/db/dyld"].map { "(subpath " + literal($0) + ")" }.joined(separator: " ") + ") " +
            "(allow file-write* (subpath " + literal(temporary.path) + ") (literal \"/dev/null\")) " +
            "(deny file-write* (literal " + literal(temporary.appendingPathComponent("openssl.cnf").path) + ")) " +
            "(allow network-bind (local ip " + endpoint + ")) (allow network-inbound (local ip " + endpoint + "))"
    }
    // A comment-only OpenSSL configuration keeps Node's default algorithms and
    // excludes machine configuration, external providers and inherited options.
    static let nodeConfigurationBytes = Data("# Intents owned Node session: default OpenSSL configuration.\n".utf8)
    static var nodeConfigurationSHA256: String { AutomationArtifactRegistry.digest(nodeConfigurationBytes) }
    static func writeNodeConfiguration(session: URL) throws -> URL {
        let file = session.appendingPathComponent("openssl.cnf")
        try AutomationDurableFile(url: file, maximumBytes: 4096).write(nodeConfigurationBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        try verifyNodeConfiguration(file)
        return file
    }
    static func verifyNodeConfiguration(_ file: URL) throws {
        guard AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(file, maximumBytes: 4096)) == nodeConfigurationSHA256 else {
            throw AutomationContractError.conflictingOperation
        }
    }
    static func childEnvironment(profile: AutomationServedJavaScriptProfile, session: URL, developerDirectory: URL, configuration: URL) -> [String: String] {
        // AutomationOwnedCommand replaces the environment; none of the caller's
        // OPENSSL_CONF, OPENSSL_MODULES or NODE_OPTIONS are inherited.
        ["PATH": "/usr/bin:/bin", "HOME": session.path, "TMPDIR": session.path,
         "DEVELOPER_DIR": developerDirectory.path, "INTENTS_JS_BUNDLE_URL": profile.bundleURL,
         "OPENSSL_CONF": configuration.path]
    }
}
#endif
