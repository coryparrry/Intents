#if os(macOS)
import Foundation
import Darwin

/// Separate review consent; an AutomationCase approval cannot admit this calibration payload.
struct AutomationInputAdapterProbeApproval: Sendable {
    let runID: String, probeDigest: String
    let app: AppIdentity, target: TargetIdentity
}
struct AutomationInputAdapterProbeReport: Sendable {
    let scope: AutomationScope
    let observation: AutomationInputAdapterProbeObservation?
    let artifact: String?
    let resourcesReleased: Bool
    let failure: String?
}

/// Internal qualification owner, deliberately absent from customer construction until child closure is qualified.
/// Readback data never becomes a business attempt or generic codec capability.
actor AutomationInputAdapterProbeRunner {
    struct Commands: Sendable {
        var run: @Sendable ([String], URL, Duration) async throws -> AutomationOwnedCommand.Result
        var stop: @Sendable () async -> Bool
        var beforeStart: @Sendable ([String], URL) async throws -> Void = { _, _ in }
    }
    private let plan: AutomationInputAdapterProbePlan, approval: AutomationInputAdapterProbeApproval
    private let developer: URL, root: URL, leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry
    private let subject: any AutomationSubjectVerifier, release: any AutomationDeviceReleaseVerifier
    private let validateTarget: @Sendable (TargetIdentity) throws -> Void
    private let commands: Commands?
    private let command = AutomationOwnedCommand()
    private var busy = false, revoked = false, stopRequested = false
    private var frozenTestFile: (url: URL, digest: String)?
    init(plan: AutomationInputAdapterProbePlan, approval: AutomationInputAdapterProbeApproval, developerDirectory: URL, state: URL,
         leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, subject: any AutomationSubjectVerifier,
         release: any AutomationDeviceReleaseVerifier, commands: Commands? = nil,
         validateTarget: @escaping @Sendable (TargetIdentity) throws -> Void = { try AutomationMacGUIIdentity.validate($0) }) throws {
        guard approval.probeDigest == (try plan.digest), approval.app == plan.prepared.host.app, approval.target == plan.prepared.host.target,
              approval.runID.range(of: #"^[A-Za-z0-9_.:-]{1,128}$"#, options: .regularExpression) != nil,
              plan.prepared.host.testTarget.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.conflictingOperation
        }
        self.plan = plan; self.approval = approval; self.leases = leases; self.artifacts = artifacts
        self.subject = subject; self.release = release; self.commands = commands; self.validateTarget = validateTarget
        developer = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = try AutomationPath.canonical(state)
    }
    /// Stops commands; only the completed report can establish release of the lease and host.
    func cancel() async -> Bool {
        revoked = true
        stopRequested = true
        if let commands { return await commands.stop() }
        return await command.stopOwned()
    }
    func run(attemptID: String) async throws -> AutomationInputAdapterProbeReport {
        guard !busy, attemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        busy = true; revoked = false; stopRequested = false; frozenTestFile = nil; defer { busy = false }
        let host = plan.prepared.host
        let lease = try await leases.acquire(runID: approval.runID, target: host.target, control: .system)
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: "input-adapter", leaseGeneration: lease.generation)
        var observation: AutomationInputAdapterProbeObservation?, artifact: String?, failure: String?
        var started = false, inspectionUnreleased = false, runner: AutomationProcessIdentity?
        var privatePayload: AutomationAppleHostPayloadFile?
        do {
            try await authorize(lease)
            try await subject.verify(app: host.app, target: host.target)
            try await authorize(lease)
            started = true
            do { try await release.prepare(target: host.target, controllerBundleIDs: [host.hostBundleID]) }
            catch { if error as? AutomationContractError == .terminationUnverified { inspectionUnreleased = true }; throw error }
            try await authorize(lease)
            let directory = root.appendingPathComponent("input-adapter-\(lease.generation)")
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let original = try AutomationReadOnlyFile.read(URL(fileURLWithPath: host.xctestrunPath), maximumBytes: 4_194_304)
            guard AutomationArtifactRegistry.digest(original) == host.xctestrunDigest else { throw AutomationContractError.conflictingOperation }
            let frozen = try AutomationAppleHostFile.freeze(PropertyListSerialization.propertyList(from: original, format: nil),
                testRoot: URL(fileURLWithPath: host.xctestrunPath).deletingLastPathComponent(), expectedHost: URL(fileURLWithPath: host.hostBundlePath),
                expectedSubject: URL(fileURLWithPath: host.subjectProductPath), testTarget: host.testTarget, payload: plan.payload(scope: scope), platform: .macOS, purpose: .inputAdapterProbe)
            let testData = try PropertyListSerialization.data(fromPropertyList: frozen, format: .xml, options: 0), testFile = directory.appendingPathComponent("probe.xctestrun")
            let payloadFile = try AutomationAppleHostPayloadFile(data: testData, url: testFile, scope: scope)
            privatePayload = payloadFile
            try await leases.recordPrivatePayload(payloadFile, lease: lease)
            try await authorize(lease)
            try payloadFile.write(testData)
            frozenTestFile = (testFile, AutomationArtifactRegistry.digest(testData))
            let resultPath = directory.appendingPathComponent("probe.xcresult")
            try await authorize(lease)
            guard try AutomationReadOnlyFile.read(testFile, maximumBytes: 4_194_304) == testData else { throw AutomationContractError.conflictingOperation }
            let result = try await runCommand(["xcodebuild", "test-without-building", "-xctestrun", testFile.path, "-destination", "platform=macOS",
                "-only-testing:" + host.testTarget + "/InputAdapterProbeTests/testParameterRoundTrip", "-jobs", "2", "-parallel-testing-enabled", "NO",
                "-resultBundlePath", resultPath.path], lease: lease, scope: scope, timeout: .seconds(120))
            if plan.parameters.contains(where: { $0.family == "intentFile" }) { _ = try await artifacts.storeNativeEvidence(data: result.stdout + result.stderr, scope: scope) }
            else { _ = try await artifacts.store(data: result.stdout + result.stderr, name: "input-adapter-log.txt", scope: scope) }
            guard result.exitStatus == 0 else { throw AutomationContractError.missingEvidence("Input adapter probe XCTest failed") }
            let attachments = directory.appendingPathComponent("attachments")
            let exported = try await runCommand(["xcresulttool", "export", "attachments", "--path", resultPath.path, "--output-path", attachments.path],
                lease: lease, scope: scope, timeout: .seconds(30))
            guard exported.exitStatus == 0 else { throw AutomationContractError.missingEvidence("Input adapter probe attachments unavailable") }
            let data: Data, readback: AutomationInputAdapterProbeObservation
            if plan.parameters.contains(where: { $0.family == "intentFile" }) {
                (data, readback) = try await AutomationInputAdapterProbeFileAttachments.importExport(root: attachments, plan: plan, scope: scope, artifacts: artifacts)
            } else {
                let files = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isRegularFileKey])
                guard files.count <= 1000 else { throw AutomationContractError.invalidIdentity }
                var matching: [(Data, AutomationInputAdapterProbeObservation)] = []
                for file in files where file.pathExtension == "json" && file.lastPathComponent != "manifest.json" {
                    let data = try AutomationReadOnlyFile.read(root: attachments, relativePath: file.lastPathComponent, maximumBytes: 1_048_576)
                    if let readback = try? AutomationInputAdapterProbeObservation.read(data, plan: plan, scope: scope) { matching.append((data, readback)) }
                }
                guard matching.count == 1 else { throw AutomationContractError.missingEvidence("Unique input adapter probe receipt required") }
                (data, readback) = matching[0]
            }
            let expectedPath = try AutomationMacAssociatedHostReleaseVerifier.profile(host).executable.path
            switch readback.runner.presence() {
            case .matching:
                guard Self.executablePath(readback.runner) == expectedPath else { throw AutomationContractError.terminationUnverified }
                runner = readback.runner
                try await leases.recordRunner(.init(scope: scope, process: readback.runner, role: .appleHost, executablePath: expectedPath), lease: lease)
            case .absent: break
            case .replaced, .unknown: throw AutomationContractError.terminationUnverified
            }
            try await authorize(lease)
            try await subject.verify(app: host.app, target: host.target)
            try await authorize(lease)
            artifact = try await artifacts.store(data: data, name: "input-adapter-receipt.json", scope: scope).handle
            observation = readback
        } catch { failure = String(String(describing: error).prefix(4096)) }
        // No sample readback escapes as a released result if any owner cannot prove cleanup.
        revoked = true
        let drained: Bool
        if let commands { drained = await commands.stop() } else { drained = await command.stopOwned() }
        var runnerStopped = true
        if let runner {
            if runner.presence() == .matching {
                if let expected = try? AutomationMacAssociatedHostReleaseVerifier.profile(host).executable.path,
                   let executable = Self.executablePath(runner), executable == expected, runner.presence() == .matching {
                    _ = kill(runner.pid, SIGTERM)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while runner.presence() == .matching, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                }
            }
            runnerStopped = runner.presence() == .absent || runner.presence() == .replaced
        }
        let independent = started ? await release.verifyReleased(target: host.target, controllerBundleIDs: [host.hostBundleID]) : true
        var released = false
        do {
            if drained && runnerStopped && independent && !inspectionUnreleased, let privatePayload {
                try privatePayload.clean(scope: scope)
                try await leases.retirePrivatePayload(privatePayload, lease: lease)
            }
            try await leases.release(lease, commandsDrained: drained, ownedRunnerTerminated: runnerStopped && independent && !inspectionUnreleased)
            try await leases.releaseCampaign(runID: approval.runID, target: host.target)
            released = true
        } catch { failure = String(String(describing: error).prefix(4096)) }
        if (stopRequested || Task.isCancelled), failure == nil { failure = "Input adapter probe cancelled before publication" }
        return .init(scope: scope, observation: released && failure == nil ? observation : nil,
            artifact: released && failure == nil ? artifact : nil, resourcesReleased: released, failure: failure)
    }
    private func authorize(_ lease: AutomationDeviceLeaseManager.Lease) async throws {
        let current = await leases.isCurrent(lease)
        guard current, !revoked else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation(); try validateTarget(plan.prepared.host.target)
        try AutomationMacAppleRuntimeSnapshot.validatePreparedArtifacts(plan.prepared.host)
        guard approval.probeDigest == (try plan.digest) else { throw AutomationContractError.conflictingOperation }
        if let frozenTestFile {
            guard AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(frozenTestFile.url, maximumBytes: 4_194_304)) == frozenTestFile.digest else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
    private func runCommand(_ arguments: [String], lease: AutomationDeviceLeaseManager.Lease, scope: AutomationScope, timeout: Duration) async throws -> AutomationOwnedCommand.Result {
        try await authorize(lease)
        if let commands {
            try await commands.beforeStart(arguments, root)
            try await authorize(lease)
            return try await commands.run(arguments, root, timeout)
        }
        return try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, directory: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path, "HOME": root.path, "TMPDIR": root.path], timeout: timeout,
            willStart: { try await self.authorize(lease) }, didStart: { identity in
                try await self.leases.recordRunner(.init(scope: scope, process: identity, role: .appleHost, executablePath: "/usr/bin/xcrun"), lease: lease)
            })
    }
    private static func executablePath(_ identity: AutomationProcessIdentity) -> String? {
        guard identity.presence() == .matching else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(identity.pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
