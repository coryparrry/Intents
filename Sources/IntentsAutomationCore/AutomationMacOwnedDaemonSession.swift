#if os(macOS)
import Foundation
import Darwin

/// Native ownership for the frozen development entry. This is internal source
/// composition, not a customer route or a claim about GUI event completion.
actor AutomationMacOwnedDaemonSession: AutomationMacProgramSession {
    struct Context: Sendable {
        let unit: AutomationPrivateMacDaemonUnit.Loaded
        let app: AppIdentity
        let target: TargetIdentity
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        let leases: AutomationDeviceLeaseManager
        let state: URL
        let authorize: AutomationMacNativeHelperBridge.Authorize
        let revalidate: @Sendable () async throws -> Void
    }
    struct Dependencies: Sendable {
        var unit: @Sendable (URL) throws -> AutomationPrivateMacDaemonUnit.Loaded
        var bridge: @Sendable (Context) async throws -> AutomationMacNativeHelperBridge
        var release: @Sendable (Context, AutomationMacNativeHelperBridge) throws -> any AutomationDeviceReleaseVerifier
        var subject: any AutomationSubjectVerifier
        var beforeWorkerAdmission: @Sendable () async -> Void = {}
        static func owned(workspace: URL, developerDirectory: URL) -> Self {
            .init(unit: { try AutomationPrivateMacDaemonUnit.load(root: $0) }, bridge: { context in
                try await AutomationMacNativeHelperBridge(helper: context.unit.helper, directory: context.state,
                    bundleID: context.app.bundleID, bundlePath: URL(fileURLWithPath: context.app.canonicalBundlePath!),
                    scope: context.scope, lease: context.lease, leases: context.leases, authorize: context.authorize, revalidate: context.revalidate, sourceVariant: context.unit.inputCapabilities.sourceVariant)
            }, release: { context, bridge in
                let paths: Set<String> = [context.unit.helper.path]
                return try AutomationMacHelperReleaseVerifier(helpers: [.init(executable: context.unit.helper,
                    sha256: context.unit.inputCapabilities.helperSHA256)], loginSession: context.target.loginSession!,
                    userID: getuid(), inspector: { try AutomationMacProcessInventory.currentUser(helperExecutablePaths: paths) },
                    drain: { !(await bridge.isInFlight()) })
            }, subject: AutomationMacGUISubjectVerifier(subject: AutomationInstalledSubjectVerifier(developerDirectory: developerDirectory, workspace: workspace),
                identity: { try AutomationMacGUIIdentity.validate($0) }))
        }
    }
    private let context: Context
    private let bridge: AutomationMacNativeHelperBridge
    private let release: any AutomationDeviceReleaseVerifier
    private let subject: any AutomationSubjectVerifier
    private let review: AutomationRPC.ReverseHandler
    private let beforeWorkerAdmission: @Sendable () async -> Void
    private var process: AutomationSidecarProcess?
    private var instance: AutomationJSON?
    private var started = false, closing = false, busy = false, inputUncertain = false, acquisitionIssued = false
    private var cleanup: Task<AutomationReleaseProof, Never>?
    private var programMode = false, programIssued = false
    private var workers: [AutomationProcessIdentity] = []
    init(unitRoot: URL, app: AppIdentity, target: TargetIdentity, scope: AutomationScope,
         lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager, state: URL,
         authorize: @escaping AutomationMacNativeHelperBridge.Authorize, dependencies: Dependencies,
         review: @escaping AutomationRPC.ReverseHandler = { _, _ in .object(["allowed": .bool(false)]) },
         revalidate: @escaping @Sendable () async throws -> Void = {}) async throws {
        try scope.validate(); try await leases.validate(lease)
        guard await leases.isDurable, target.kind == .nativeMac, target.id == "host-macos-local",
              let login = target.loginSession, !login.isEmpty, login.utf8.count <= 256, !login.contains("\0"),
              app.platform == "macos", app.productDigest != nil, let path = app.canonicalBundlePath,
              path == (try AutomationPath.canonical(URL(fileURLWithPath: path))).path,
              scope.runId == lease.runID, scope.leaseGeneration == lease.generation, lease.target == target,
              lease.control == .ui, state.isFileURL, state.path == (try AutomationPath.canonical(state)).path else { throw AutomationContractError.invalidIdentity }
        let context = Context(unit: try dependencies.unit(unitRoot), app: app, target: target, scope: scope,
            lease: lease, leases: leases, state: state, authorize: authorize, revalidate: {
                try await dependencies.subject.verify(app: app, target: target)
                try await revalidate()
                try await leases.validate(lease)
            })
        self.context = context; self.review = review; beforeWorkerAdmission = dependencies.beforeWorkerAdmission
        bridge = try await dependencies.bridge(context)
        release = try dependencies.release(context, bridge); subject = dependencies.subject
        try await leases.validate(lease)
    }
    func open(programMode: Bool = false) async throws -> AutomationJSON {
        guard !started, !closing, !busy else { throw AutomationContractError.targetBusy }
        started = true; busy = true; self.programMode = programMode
        do {
            try await validateSubject()
            try await requireOpen()
            try await release.prepare(target: context.target, controllerBundleIDs: [])
            try await requireOpen()
            let process = try AutomationSidecarProcess(configuration: .init(node: context.unit.node, entry: context.unit.entry,
                stateDirectory: context.state, privateMacDaemon: true), reverse: { method, input in
                try await self.reverse(method: method, input: input)
            })
            self.process = process
            try await process.start()
            guard let identity = await process.processIdentity else { throw AutomationContractError.invalidIdentity }
            try await context.leases.recordRunner(.init(scope: context.scope, process: identity,
                role: .sidecar, executablePath: context.unit.node.path), lease: context.lease)
            try await requireOpen()
            let hello = try await process.rpc.request(.hello, params: .object(["scope": try json(context.scope),
                "target": targetJSON(), "authentication": .string(await bridge.pipeCapability()),
                "helperSHA256": .string(context.unit.inputCapabilities.helperSHA256)]))
            guard hello == .object(["protocolVersion": .number(1), "artifactVariant": .string("private-owned-mac-daemon-integration"),
                "customerRuntimeEnabled": .bool(false), "hardwareQualified": .bool(false)]) else { throw AutomationRPCError.invalidFrame }
            try await requireOpen()
            acquisitionIssued = true
            var acquisition: [String: AutomationJSON] = ["scope": try json(context.scope)]
            if programMode { acquisition["programMode"] = .bool(true) }
            let acquired = try await process.rpc.request(.acquire, params: .object(acquisition))
            guard let fields = acquired.object, Set(fields.keys) == ["applicationTarget"], let observed = fields["applicationTarget"] else { throw AutomationRPCError.invalidFrame }
            try validateInstance(observed)
            instance = observed
            try await validateSubject(); try await requireOpen()
            busy = false; return observed
        } catch {
            busy = false
            _ = await close()
            throw error
        }
    }
    func capture(timeoutMilliseconds: Int = 30_000) async throws -> AutomationJSON {
        guard !programMode else { throw AutomationContractError.conflictingOperation }
        return try await operation(kind: "capture", timeoutMilliseconds: timeoutMilliseconds, point: nil)
    }
    func press(x: Double, y: Double, timeoutMilliseconds: Int = 30_000) async throws -> AutomationJSON {
        guard !programMode, !inputUncertain, x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw AutomationContractError.invalidIdentity }
        do { return try await operation(kind: "press", timeoutMilliseconds: timeoutMilliseconds, point: (x, y)) }
        catch { inputUncertain = true; throw error }
    }
    func runProgram(_ program: AutomationUIProgram, phase: AutomationSegment.Phase, operationID: String) async throws -> AutomationJSON {
        guard programMode, !programIssued, !busy, !closing, !inputUncertain, let process, let instance else { throw AutomationContractError.targetBusy }
        try program.validate(phase: phase)
        try context.unit.inputCapabilities.validate(program)
        let payload = try program.payload(scope: context.scope, phase: phase, operationID: operationID, digestVersion: context.unit.programDigestVersion)
        busy = true; programIssued = true; defer { busy = false }
        try await validateSubject(); try await requireOpen()
        let result = try await process.rpc.request(.runSegment, params: payload, timeout: .milliseconds(program.timeoutMilliseconds + 10_000))
        try await validateSubject(); try await requireOpen()
        guard let fields = result.object, Set(fields.keys) == ["applicationTarget", "receipt"], fields["applicationTarget"] == instance,
              let receipt = fields["receipt"], let body = receipt.object, Set(body.keys) == ["schemaVersion", "scope", "operationId", "complete", "outputs"],
              body["schemaVersion"] == .number(1), body["scope"] == (try json(context.scope)), body["operationId"] == .string(operationID),
              body["complete"] == .bool(true), body["outputs"]?.object != nil else { throw AutomationRPCError.invalidFrame }
        return receipt
    }
    private func reverse(method: String, input: AutomationJSON) async throws -> AutomationJSON {
        if ["mac.helper.run", "mac.helper.stop"].contains(method) { return try await bridge.handle(method: method, input: input) }
        guard programMode else { throw AutomationRPCError.invalidFrame }
        try await requireOpen()
        if method == "ui.workerStarted" {
            guard workers.isEmpty else { throw AutomationContractError.targetBusy }
            await beforeWorkerAdmission()
            guard workers.isEmpty, let fields = input.object, case .number(let pid) = fields["pid"],
                  pid.rounded() == pid, (1...Double(Int32.max)).contains(pid),
                  .object(fields.filter { $0.key != "pid" }) == (try json(context.scope)),
                  let parent = await process?.processIdentity else { throw AutomationContractError.invalidIdentity }
            try await requireOpen()
            guard workers.isEmpty else { throw AutomationContractError.targetBusy }
            let identity = try workerIdentity(pid: Int32(pid), parent: parent)
            workers.append(identity)
            try await context.leases.recordRunner(.init(scope: context.scope, process: identity, role: .uiWorker,
                executablePath: context.unit.node.path), lease: context.lease)
            try await requireOpen()
            guard identity.presence() == .matching, parent.presence() == .matching else { throw AutomationContractError.invalidIdentity }
            return .object(["allowed": .bool(true)])
        }
        guard ["policy.reviewAction", "controller.decide"].contains(method) else { throw AutomationRPCError.invalidFrame }
        let result = try await review(method, input)
        try await requireOpen()
        return result
    }
    private func workerIdentity(pid: Int32, parent: AutomationProcessIdentity) throws -> AutomationProcessIdentity {
        guard parent.presence() == .matching else { throw AutomationContractError.invalidIdentity }
        var info = proc_bsdinfo(), path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == UInt32(parent.pid), info.pbi_uid == getuid(),
              length > 0, length < path.count, let end = path.firstIndex(of: 0), end > 0,
              String(bytes: path[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8) == context.unit.node.path else { throw AutomationContractError.invalidIdentity }
        return .init(pid: pid, startIdentity: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
    }
    private func operation(kind: String, timeoutMilliseconds: Int, point: (Double, Double)?) async throws -> AutomationJSON {
        guard !busy, !closing, let process, let instance, (1...60_000).contains(timeoutMilliseconds) else { throw AutomationContractError.targetBusy }
        busy = true; defer { busy = false }
        try await validateSubject(); try await requireOpen()
        var fields: [String: AutomationJSON] = ["scope": try json(context.scope), "operation": .string(kind),
            "applicationTarget": instance, "timeoutMs": .number(Double(timeoutMilliseconds))]
        if let point { fields["x"] = .number(point.0); fields["y"] = .number(point.1) }
        let result = try await process.rpc.request(.runSegment, params: .object(fields), timeout: .milliseconds(timeoutMilliseconds + 5_000))
        try await requireOpen(); try await validateSubject(); try await requireOpen()
        guard result.object?["applicationTarget"] == instance else { throw AutomationContractError.conflictingOperation }
        if kind == "capture" {
            guard result.object?["appBundleId"] == .string(context.app.bundleID),
                  result.object?["identifiers"]?.object?["session"] == .string("intents-\(context.scope.runId)-\(context.scope.leaseGeneration)") else { throw AutomationContractError.conflictingOperation }
        } else {
            guard let point, result.object?["x"] == .number(point.0), result.object?["y"] == .number(point.1),
                  result.object?["disposition"] == .string("submittedUnconfirmed"), result.object?["releaseSubmitted"] == .bool(true) else { throw AutomationContractError.terminationUnverified }
        }
        return result
    }
    func close() async -> AutomationReleaseProof {
        if let cleanup { return await cleanup.value }
        closing = true
        let task = Task.detached { await self.finish() }; cleanup = task
        return await task.value
    }
    func admitsWork() -> Bool { !closing }
    private func finish() async -> AutomationReleaseProof {
        var protocolReleased = false
        if let process {
            if let result = try? await process.rpc.request(.shutdown, params: .object(["protocolVersion": .number(1)]), timeout: .seconds(45)) {
                protocolReleased = result.object?["scope"] == (try? json(context.scope)) &&
                    result.object?["applicationTarget"] == (instance ?? .null) && result.object?["subjectTerminated"] == .bool(false) &&
                    ["resourcesReleased", "commandsDrained", "ownedHelperReaped", "daemonStopped"].allSatisfy({ result.object?[$0] == .bool(true) })
            }
        }
        let helperDrained = await bridge.stop()
        let processStopped = await process?.stop() ?? true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while busy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let absent = acquisitionIssued ? await release.verifyReleased(target: context.target, controllerBundleIDs: []) : true
        let workersStopped = workers.allSatisfy { [.absent, .replaced].contains($0.presence()) }
        return .init(commandsDrained: !busy && helperDrained && processStopped && workersStopped,
            runnerTerminated: (!acquisitionIssued || protocolReleased) && !busy && helperDrained && processStopped && workersStopped && absent)
    }
    private func requireOpen() async throws {
        guard !closing, !Task.isCancelled else { throw AutomationContractError.unknownLease }
        try await context.leases.validate(context.lease)
        guard !closing else { throw AutomationContractError.unknownLease }
    }
    private func validateSubject() async throws { try await subject.verify(app: context.app, target: context.target) }
    private func validateInstance(_ value: AutomationJSON) throws {
        guard let fields = value.object, Set(fields.keys) == ["bundleId", "canonicalBundlePath", "pid", "processStartIdentity"],
              fields["bundleId"] == .string(context.app.bundleID), fields["canonicalBundlePath"] == .string(context.app.canonicalBundlePath!),
              case .number(let pid) = fields["pid"], pid.rounded() == pid, (1...Double(Int32.max)).contains(pid),
              let start = fields["processStartIdentity"]?.string,
              start.range(of: #"^[1-9][0-9]{0,19}:(0|[1-9][0-9]{0,5})$"#, options: .regularExpression) != nil else { throw AutomationContractError.conflictingOperation }
        let parts = start.split(separator: ":")
        guard UInt64(parts[0]) != nil, let microseconds = UInt32(parts[1]), microseconds <= 999_999 else { throw AutomationContractError.invalidIdentity }
    }
    private func targetJSON() -> AutomationJSON {
        .object(["id": .string(context.target.id), "platform": .string("macos"), "kind": .string("nativeMac"),
            "bundleId": .string(context.app.bundleID), "bundlePath": .string(context.app.canonicalBundlePath!),
            "loginSession": .string(context.target.loginSession!)])
    }
    private func json<T: Encodable>(_ value: T) throws -> AutomationJSON { try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value)) }
}
#endif
