#if os(macOS)
import Foundation

/// A private pipe capability bound to one UI lease. It never accepts an executable or argv from Node.
public actor AutomationMacNativeHelperBridge {
    public static let helperABI = "startup-gate-v1"
    public static let privateHelperSHA256 = "91dc95a1bf0715746dfc6cf4790a9714f60565aab8e025ce0acc9edafb2ce4a4"
    public static let privateScrollHelperSHA256 = "068dfd47b668ddb656fdef257382f4763357fe49c0dbdeb89ea1bd634564be4f"
    public static let privateFillHelperSHA256 = "e1a073e759f643fa6f04799b4a492fc7cf0ef63d8fd13959e5aca7bbcbd4f576"
    public enum SourceVariant: Sendable { case tapOnly, boundedScrollExperiment, boundedFillExperiment }
    public typealias Authorize = @Sendable (AutomationJSON) async throws -> Void
    private let scope: AutomationScope
    private let lease: AutomationDeviceLeaseManager.Lease
    private let leases: AutomationDeviceLeaseManager
    private let selection: AutomationJSON
    private let executable: URL, directory: URL
    private let prefix: [String]
    private let helperDigest: String
    private let scrollImplemented: Bool
    private let fillImplemented: Bool
    private let selectedABI: String
    private let authorize: Authorize
    private let revalidate: @Sendable () async throws -> Void
    private let didCapture: @Sendable (AutomationProcessIdentity, String) async throws -> Void
    private let beforeCommandAdmission: @Sendable () async -> Void
    private let command = AutomationOwnedCommand()
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var instance: AutomationJSON?
    private var opened = false, active = false, disabled = false

    public init(helper: URL, directory: URL, bundleID: String, bundlePath: URL, scope: AutomationScope,
                lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager,
                authorize: @escaping Authorize, revalidate: @escaping @Sendable () async throws -> Void = {},
                sourceVariant: SourceVariant = .tapOnly) async throws {
        guard await leases.isDurable else { throw AutomationContractError.invalidIdentity }
        let expectedDigest: String
        switch sourceVariant {
        case .tapOnly: expectedDigest = Self.privateHelperSHA256
        case .boundedScrollExperiment: expectedDigest = Self.privateScrollHelperSHA256
        case .boundedFillExperiment: expectedDigest = Self.privateFillHelperSHA256
        }
        try Self.validate(executable: helper, directory: directory, bundleID: bundleID, bundlePath: bundlePath,
                          digest: expectedDigest, scope: scope, lease: lease)
        self.scope = scope; self.lease = lease; self.leases = leases
        executable = helper; self.directory = directory; prefix = []; helperDigest = expectedDigest
        scrollImplemented = sourceVariant != .tapOnly
        fillImplemented = sourceVariant == .boundedFillExperiment
        selectedABI = fillImplemented ? "startup-gate-v2-private-input" : Self.helperABI
        selection = .object(["bundleId": .string(bundleID), "canonicalBundlePath": .string(bundlePath.path)])
        self.authorize = authorize; self.revalidate = revalidate; didCapture = { _, _ in }; beforeCommandAdmission = {}
    }

    /// Synthetic-only seam: not available to an enclosing application outside this module.
    init(executable: URL, prefix: [String], directory: URL, bundleID: String, bundlePath: URL,
         scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager,
         authorize: @escaping Authorize,
         didCapture: @escaping @Sendable (AutomationProcessIdentity, String) async throws -> Void,
         beforeCommandAdmission: @escaping @Sendable () async -> Void = {}, revalidate: @escaping @Sendable () async throws -> Void = {},
         scrollImplemented: Bool = false, fillImplemented: Bool = false) throws {
        let digest = AutomationArtifactRegistry.digest(try Data(contentsOf: executable))
        try Self.validate(executable: executable, directory: directory, bundleID: bundleID, bundlePath: bundlePath,
                          digest: digest, scope: scope, lease: lease)
        self.scope = scope; self.lease = lease; self.leases = leases; self.executable = executable
        self.directory = directory; self.prefix = prefix; helperDigest = digest
        self.scrollImplemented = scrollImplemented
        self.fillImplemented = fillImplemented
        selectedABI = fillImplemented ? "startup-gate-v2-private-input" : Self.helperABI
        selection = .object(["bundleId": .string(bundleID), "canonicalBundlePath": .string(bundlePath.path)])
        self.authorize = authorize; self.revalidate = revalidate; self.didCapture = didCapture; self.beforeCommandAdmission = beforeCommandAdmission
    }

    public func pipeCapability() -> String { token }
    public func isInFlight() -> Bool { active }

    public func handle(method: String, input: AutomationJSON) async throws -> AutomationJSON {
        if method == "mac.helper.run" { return try await execute(input) }
        guard method == "mac.helper.stop", let fields = input.object,
              Set(fields.keys) == ["authentication", "scope", "applicationTarget"],
              fields["authentication"] == .string(token), fields["scope"] == Self.json(scope),
              let requested = fields["applicationTarget"], requested == .null || requested == instance else {
            throw AutomationContractError.invalidIdentity
        }
        let drained = await stop()
        return .object(["scope": Self.json(scope), "applicationTarget": requested,
                        "commandsDrained": .bool(drained), "ownedHelperReaped": .bool(drained)])
    }

    public func execute(_ input: AutomationJSON) async throws -> AutomationJSON {
        guard !disabled, !active, let envelope = input.object,
              Set(envelope.keys) == ["authentication", "request"], envelope["authentication"] == .string(token),
              let request = envelope["request"]?.object,
              Set(request.keys) == ["requestId", "scope", "selection", "action", "timeoutMs"],
              request["scope"] == Self.json(scope), request["selection"] == selection,
              let id = request["requestId"]?.string, UUID(uuidString: id)?.uuidString.lowercased() == id,
              case .number(let timeout) = request["timeoutMs"], timeout.rounded() == timeout, (1...60_000).contains(timeout),
              let action = request["action"]?.object, let kind = action["kind"]?.string else {
            throw AutomationContractError.invalidIdentity
        }
        let arguments = try arguments(action, kind: kind)
        active = true; defer { active = false }
        if kind == "acquire" { opened = true }
        do {
            let nonce = UUID().uuidString.lowercased()
            let privateFrame = kind == "ordinaryFill" ? try AutomationMacOrdinaryFillInput.frame(action: action, nonce: nonce) : nil
            let scope = self.scope, lease = self.lease, leases = self.leases, executable = self.executable
            let digest = helperDigest, authorize = self.authorize, captured = didCapture, revalidate = self.revalidate
            await beforeCommandAdmission()
            let result = try await command.run(executable: executable, arguments: prefix + arguments,
                directory: directory, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                timeout: .milliseconds(Int64(timeout)), ownershipGateNonce: nonce, privateInputFrame: privateFrame,
                willStart: {
                    try await self.requireAdmission()
                    try await leases.validate(lease)
                    try Self.verifyExecutable(executable, digest: digest)
                    try await authorize(.object(request))
                    try await self.requireAdmission()
                    try await leases.validate(lease)
                }, didStart: { identity in
                    try await self.requireAdmission()
                    try await leases.validate(lease)
                    try await leases.recordRunner(.init(scope: scope, process: identity, role: .nativeCommand,
                                                       executablePath: executable.path), lease: lease)
                    try await captured(identity, nonce)
                    try await self.requireAdmission()
                    try await leases.validate(lease)
                }, willAcknowledge: {
                    try await revalidate()
                    try await self.requireAdmission()
                    try await leases.validate(lease)
                })
            guard !disabled, await leases.isCurrent(lease), result.exitStatus == 0,
                  result.startupAcknowledged, result.directChildReaped, result.pipesDrained, result.callbacksDrained,
                  !result.logsTruncated, let owned = result.ownedIdentity,
                  let stdout = String(data: result.stdout, encoding: .utf8), let stderr = String(data: result.stderr, encoding: .utf8),
                  result.stdout.count <= 1_048_576, result.stderr.count <= 1_048_576 else {
                throw AutomationContractError.terminationUnverified
            }
            try Self.verifyExecutable(executable, digest: digest)
            let reply = try JSONDecoder().decode(AutomationJSON.self, from: result.stdout)
            guard reply.object?["ok"] == .bool(true), let data = reply.object?["data"] else {
                throw AutomationContractError.invalidIdentity
            }
            if kind == "acquire" {
                try Self.validateInstance(data, selection: selection)
                instance = data
            } else {
                guard data.object?["applicationTarget"] == instance else { throw AutomationContractError.invalidIdentity }
                if kind == "press" {
                    guard data.object?["x"] == action["x"], data.object?["y"] == action["y"],
                          data.object?["disposition"] == .string("submittedUnconfirmed"),
                          data.object?["releaseSubmitted"] == .bool(true) else { throw AutomationContractError.invalidIdentity }
                }
                if kind == "scroll" {
                    guard data.object?["x"] == action["x"], data.object?["y"] == action["y"],
                          data.object?["direction"] == action["direction"], data.object?["disposition"] == .string("submittedUnconfirmed") else {
                        throw AutomationContractError.invalidIdentity
                    }
                }
            }
            if kind == "ordinaryFill" {
                guard let fields = data.object, Set(fields.keys) == ["applicationTarget", "x", "y", "disposition"],
                      fields["x"] == action["x"], fields["y"] == action["y"], fields["disposition"] == .string("replacementVerified") else {
                    throw AutomationContractError.invalidIdentity
                }
            }
            try await leases.retireNativeCommand(.init(scope: scope, process: owned, role: .nativeCommand,
                                                       executablePath: executable.path), lease: lease)
            try requireAdmission()
            return .object(["requestId": .string(id), "scope": Self.json(scope), "helperABI": .string(selectedABI),
                "helperSHA256": .string(helperDigest), "ownedIdentity": Self.json(owned),
                "startupAcknowledged": .bool(true), "directChildReaped": .bool(true), "pipesDrained": .bool(true),
                "callbacksDrained": .bool(true), "logsTruncated": .bool(false), "exitCode": .number(0),
                "stdout": .string(stdout), "stderr": .string(stderr)])
        } catch { disabled = true; throw error }
    }

    private func requireAdmission() throws {
        guard !disabled, active, !Task.isCancelled else { throw AutomationContractError.invalidIdentity }
    }

    public func stop() async -> Bool {
        disabled = true
        let stopped = await command.stopOwned()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while active && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return stopped && !active
    }

    private func arguments(_ action: [String: AutomationJSON], kind: String) throws -> [String] {
        if kind == "acquire" {
            guard !opened, Set(action.keys) == ["kind"], let selected = selection.object else { throw AutomationContractError.invalidIdentity }
            return ["app", "open", "--bundle-id", selected["bundleId"]!.string!, "--bundle-path", selected["canonicalBundlePath"]!.string!]
        }
        let keys: Set<String> = kind == "snapshot" ? ["kind", "instance"] : kind == "scroll" ? ["kind", "instance", "x", "y", "direction"] : kind == "ordinaryFill" ? ["kind", "instance", "x", "y", "value"] : ["kind", "instance", "x", "y"]
        guard ["snapshot", "press", "scroll", "ordinaryFill"].contains(kind), (kind != "scroll" || scrollImplemented), (kind != "ordinaryFill" || fillImplemented), let instance, action["instance"] == instance,
              Set(action.keys) == keys,
              let target = instance.object, case .number(let pid) = target["pid"] else { throw AutomationContractError.invalidIdentity }
        var args = [kind == "scroll" ? "owned-scroll" : kind == "ordinaryFill" ? "owned-fill" : kind, "--bundle-id", target["bundleId"]!.string!, "--target-bundle-path", target["canonicalBundlePath"]!.string!,
                    "--target-pid", String(Int32(pid)), "--target-process-start", target["processStartIdentity"]!.string!, "--surface", "frontmost-app"]
        if kind == "press" || kind == "scroll" || kind == "ordinaryFill" {
            for key in ["x", "y"] {
                guard case .number(let point) = action[key], point.isFinite, abs(point) <= 1_000_000 else { throw AutomationContractError.invalidIdentity }
                args += ["--" + key, point.rounded() == point ? String(Int64(point)) : String(point)]
            }
        }
        if kind == "scroll" {
            guard let direction = action["direction"]?.string, ["up", "down", "left", "right"].contains(direction) else { throw AutomationContractError.invalidIdentity }
            args += ["--direction", direction]
        }
        if kind == "ordinaryFill" {
            guard let value = action["value"]?.string else { throw AutomationContractError.invalidIdentity }
            try AutomationMacOrdinaryFillInput.validate(value)
        }
        return args
    }

    static func validateInstance(_ input: AutomationJSON, selection: AutomationJSON) throws {
        guard let value = input.object, let selected = selection.object,
              Set(value.keys) == ["bundleId", "canonicalBundlePath", "pid", "processStartIdentity"],
              value["bundleId"] == selected["bundleId"], value["canonicalBundlePath"] == selected["canonicalBundlePath"],
              case .number(let pid) = value["pid"], pid.rounded() == pid, (1...Double(Int32.max)).contains(pid),
              let start = value["processStartIdentity"]?.string,
              start.range(of: #"^[1-9][0-9]{0,19}:(0|[1-9][0-9]{0,5})$"#, options: .regularExpression) != nil,
              UInt64(start.split(separator: ":")[0]) != nil else { throw AutomationContractError.invalidIdentity }
    }
    private static func validate(executable: URL, directory: URL, bundleID: String, bundlePath: URL,
                                 digest: String, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) throws {
        try scope.validate()
        guard lease.control == .ui, lease.target.kind == .nativeMac, lease.runID == scope.runId, lease.generation == scope.leaseGeneration,
              directory.isFileURL, directory.path == (try AutomationPath.canonical(directory)).path,
              bundlePath.isFileURL, bundlePath.path == (try AutomationPath.canonical(bundlePath)).path, bundlePath.path.hasSuffix(".app"),
              bundleID.range(of: #"^[A-Za-z0-9_.:-]{1,256}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        try verifyExecutable(executable, digest: digest)
    }
    private static func verifyExecutable(_ url: URL, digest: String) throws {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.isFileURL, url.path == (try AutomationPath.canonical(url)).path,
              info[.type] as? FileAttributeType == .typeRegular, (info[.referenceCount] as? NSNumber)?.intValue == 1,
              (info[.size] as? NSNumber)?.intValue ?? Int.max <= 128 * 1024 * 1024,
              AutomationArtifactRegistry.digest(try Data(contentsOf: url)) == digest else { throw AutomationContractError.invalidIdentity }
    }
    private static func json<T: Encodable>(_ value: T) -> AutomationJSON {
        // All call sites are bounded Codable value records; failure is never exposed as a successful reply.
        (try? JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value))) ?? .null
    }
}
#endif
