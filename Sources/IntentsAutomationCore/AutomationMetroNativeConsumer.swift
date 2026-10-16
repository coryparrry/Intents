#if os(macOS)
import Foundation
import Darwin

/// A paused HTTP request is released only after two kernel socket observations
/// attribute its client port to the exact installed selected simulator product.
actor AutomationMetroNativeConsumer {
    struct Pending: Codable, Sendable { let id: Int; let port: Int; let url: String }
    struct Delivered: Codable, Sendable { let id: Int; let port: Int; let url: String; let sha256: String }
    struct State: Codable, Sendable { let pending: [Pending]; let delivered: [Delivered]; var inFlight: Int = 0; var splitURLs: [String]? = nil }
    struct Proof: Codable, Equatable, Sendable { let process: AutomationProcessIdentity; let installedProduct: String; let bundleSHA256: String }
    private var proofs: [Int: Proof] = [:]
    private var failure: (any Error)?
    private var stopping = false
    private let profile: AutomationServedJavaScriptProfile
    private let app: AppIdentity
    private let target: TargetIdentity
    private let token: String
    private let workspace: URL
    init(profile: AutomationServedJavaScriptProfile, app: AppIdentity, target: TargetIdentity, token: String, workspace: URL) {
        self.profile = profile; self.app = app; self.target = target; self.token = token; self.workspace = workspace
    }
    func monitor() async {
        do {
            while !Task.isCancelled && !stopping {
                let state = try await readState()
                guard state.pending.count <= 16, state.delivered.count <= 32 else { throw AutomationContractError.invalidIdentity }
                for request in state.pending {
                    if stopping { break }
                    guard Self.admittedRequest(request.url, profile.bundleURL, splitURLs: state.splitURLs ?? []) else { throw AutomationContractError.conflictingOperation }
                    let proof = try await attribute(clientPort: request.port)
                    proofs[request.id] = proof
                    do { _ = try await control(path: "/__intents/release?id=" + String(request.id)) }
                    catch { proofs.removeValue(forKey: request.id); throw error }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch is CancellationError { }
        catch { failure = error }
    }
    func requestStop() { stopping = true }
    func validateConsumed(required: Bool) async throws -> [String: String]? {
        if let failure { throw failure }
        let state = try await readState()
        let responses = try Self.validateState(state, profile: profile, proofs: proofs, required: required)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try AutomationDurableFile(url: workspace.appendingPathComponent("native-javascript-consumers.json"), maximumBytes: 65_536).write(encoder.encode(proofs))
        return responses
    }
    static func validateState(_ state: State, profile: AutomationServedJavaScriptProfile, proofs: [Int: Proof], required: Bool) throws -> [String: String]? {
        guard state.pending.isEmpty, state.inFlight == 0, state.delivered.count == proofs.count else { throw AutomationContractError.terminationUnverified }
        if !required, proofs.isEmpty { return nil }
        guard !proofs.isEmpty, state.delivered.contains(where: { sameRequest($0.url, profile.bundleURL) && $0.sha256 == profile.bundleSHA256 }) else {
            throw AutomationContractError.missingEvidence("The selected native app did not consume the pinned JavaScript from its owned Metro server.")
        }
        var responses: [String: String] = [:]
        for item in state.delivered {
            guard proofs[item.id] != nil, admittedRequest(item.url, profile.bundleURL, splitURLs: state.splitURLs), AutomationTuistRecipePin.validDigest(item.sha256),
                  !sameRequest(item.url, profile.bundleURL) || item.sha256 == profile.bundleSHA256 else { throw AutomationContractError.conflictingOperation }
            guard responses[item.url] == nil || responses[item.url] == item.sha256 else { throw AutomationContractError.conflictingOperation }
            responses[item.url] = item.sha256
        }
        return responses
    }
    static func admittedRequest(_ request: String, _ approved: String, splitURLs: [String]? = nil) -> Bool {
        if sameRequest(request, approved) { return true }
        if let splitURLs { return splitURLs.contains { sameRequest(request, $0) } }
        guard let base = URL(string: approved), let url = URL(string: request, relativeTo: base)?.absoluteURL,
              let a = URLComponents(url: url, resolvingAgainstBaseURL: true), let b = URLComponents(url: base, resolvingAgainstBaseURL: true),
              a.scheme == b.scheme, ["127.0.0.1", "localhost"].contains(a.host ?? ""), a.port == b.port,
              a.path.hasSuffix(".bundle"), !a.path.split(separator: "/").contains(".."), a.user == nil, a.password == nil, a.fragment == nil,
              let items = a.queryItems, let expected = b.queryItems, items.count == expected.count,
              Set(items.map(\.name)).count == items.count else { return false }
        var values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let pinned = Dictionary(uniqueKeysWithValues: expected.map { ($0.name, $0.value ?? "") })
        guard values["modulesOnly"] == "true", values["runModule"] == "false" else { return false }
        values["modulesOnly"] = pinned["modulesOnly"]; values["runModule"] = pinned["runModule"]
        return values == pinned
    }
    static func sameRequest(_ request: String, _ approved: String) -> Bool {
        guard let base = URL(string: approved), let url = URL(string: request, relativeTo: base)?.absoluteURL,
              let a = URLComponents(url: url, resolvingAgainstBaseURL: true), let b = URLComponents(url: base, resolvingAgainstBaseURL: true),
              a.scheme == b.scheme, ["127.0.0.1", "localhost"].contains(a.host ?? ""), a.port == b.port,
              a.path == b.path, a.user == nil, a.password == nil, a.fragment == nil else { return false }
        let pairs: (URLComponents) -> [String] = { ($0.queryItems ?? []).map { $0.name + "=" + ($0.value ?? "") }.sorted() }
        return pairs(a) == pairs(b)
    }
    private func attribute(clientPort: Int) async throws -> Proof {
        guard (1024...65535).contains(clientPort), UUID(uuidString: target.id) != nil else { throw AutomationContractError.invalidIdentity }
        let first = try await clientPID(port: clientPort)
        guard let identity = AutomationProcessIdentity.inspect(pid: first) else { throw AutomationContractError.invalidIdentity }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(identity.pid, &buffer, UInt32(buffer.count))
        guard count > 0, Int(count) < buffer.count else { throw AutomationContractError.invalidIdentity }
        let executable = URL(fileURLWithPath: String(cString: buffer)), bundle = executable.deletingLastPathComponent()
        try Self.validateInstalledPath(bundle, target: target)
        let product = try AutomationProductDigest.compute(bundle: bundle, version: app.productDigestVersion)
        let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: bundle,
            relativePath: "Info.plist", maximumBytes: 1_048_576, version: app.productDigestVersion, expectedDigest: app.productDigest), format: nil) as? [String: Any]
        try Self.validateProduct(app: app, digest: product, info: info, executable: executable)
        guard try await clientPID(port: clientPort) == first, identity.presence() == .matching else { throw AutomationContractError.conflictingOperation }
        return .init(process: identity, installedProduct: product, bundleSHA256: profile.bundleSHA256)
    }
    static func validateProduct(app: AppIdentity, digest: String, info: [String: Any]?, executable: URL) throws {
        guard digest == app.productDigest, info?["CFBundleIdentifier"] as? String == app.bundleID,
              info?["CFBundleExecutable"] as? String == executable.lastPathComponent else { throw AutomationContractError.conflictingOperation }
    }
    static func validateInstalledPath(_ bundle: URL, target: TargetIdentity) throws {
        let parts = bundle.pathComponents
        guard target.kind == .simulator, bundle.pathExtension == "app", try AutomationPath.canonical(bundle).path == bundle.path,
              let marker = parts.indices.first(where: { parts[$0] == "CoreSimulator" && $0 + 2 < parts.count && parts[$0 + 1] == "Devices" }),
              UUID(uuidString: parts[marker + 2]) == UUID(uuidString: target.id),
              Array(parts.dropFirst(marker + 3).prefix(4)) == ["data", "Containers", "Bundle", "Application"] else { throw AutomationContractError.invalidIdentity }
    }
    private func clientPID(port: Int) async throws -> Int32 {
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-iTCP:" + String(profile.port), "-sTCP:ESTABLISHED", "-Fpn"], directory: workspace,
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(3))
        guard result.exitStatus == 0, !result.logsTruncated, result.stderr.isEmpty else { throw AutomationContractError.invalidIdentity }
        return try Self.clientPID(bytes: result.stdout, clientPort: port, serverPort: profile.port)
    }
    static func clientPID(bytes: Data, clientPort: Int, serverPort: Int) throws -> Int32 {
        let endpoint = "127.0.0.1:" + String(clientPort) + "->127.0.0.1:" + String(serverPort)
        let owners = try AutomationServedJavaScriptSupervisor.parseListeners(bytes).filter { $0.endpoint == endpoint }
        guard owners.count == 1 else { throw AutomationContractError.invalidIdentity }
        return owners[0].pid
    }
    private func readState() async throws -> State { try JSONDecoder().decode(State.self, from: await control(path: "/__intents/pending")) }
    private func control(path: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:" + String(profile.port) + path)!)
        request.setValue(token, forHTTPHeaderField: "X-Intents-Probe"); request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (bytes, response) = try await session.data(for: request)
        guard bytes.count <= 65_536, let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == request.url else { throw AutomationContractError.invalidIdentity }
        return bytes
    }
}
#endif
