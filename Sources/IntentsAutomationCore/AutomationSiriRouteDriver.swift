#if os(macOS)
import Foundation

/// Owns one physical recognised-text XCTest submission and independently verifies device release.
public actor AutomationSiriRouteDriver: AutomationRouteDriver {
    struct Commands: Sendable {
        let run: @Sendable (String, [String], URL, Duration) async throws -> AutomationOwnedCommand.Result
        let stop: @Sendable () async -> Bool
    }
    private struct Active {
        let plan: AutomationCase
        let segment: AutomationSegment
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        let directory: URL
        let testFile: URL
        let digest: String
        var issued = false
    }
    private let prepared: AutomationPreparedApplication
    private let approval: RunApproval
    private let capabilities: CapabilityProfile
    private let siriAuthority: AutomationSiriRouteAuthority?
    private var liveSubmission: AutomationImportedSiriSubmission?
    private let developer: URL
    private let root: URL
    private let leases: AutomationDeviceLeaseManager
    private let artifacts: AutomationArtifactRegistry
    private let subjectVerifier: any AutomationSubjectVerifier
    private let releaseVerifier: any AutomationDeviceReleaseVerifier
    private let campaignBudget: AutomationCampaignBudget?
    private let command = AutomationOwnedCommand()
    private let commands: Commands?
    private var admission: (AutomationScope, AutomationDeviceLeaseManager.Lease)?
    private var active: Active?
    private var payload: AutomationAppleHostPayloadFile?
    private var preparing = false, executing = false, releasing = false, revoked = false
    private var controllerPrepared = false, inspectorUnproved = false

    public init(prepared: AutomationPreparedApplication, approval: RunApproval, capabilities: CapabilityProfile,
                developerDirectory: URL, stateDirectory: URL, leases: AutomationDeviceLeaseManager,
                artifacts: AutomationArtifactRegistry, subjectVerifier: any AutomationSubjectVerifier,
                releaseVerifier: any AutomationDeviceReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil, siriAuthority: AutomationSiriRouteAuthority? = nil) throws {
        try self.init(prepared: prepared, approval: approval, capabilities: capabilities, developerDirectory: developerDirectory,
            stateDirectory: stateDirectory, leases: leases, artifacts: artifacts, subjectVerifier: subjectVerifier,
            releaseVerifier: releaseVerifier, campaignBudget: campaignBudget, siriAuthority: siriAuthority, commands: nil)
    }
    init(prepared: AutomationPreparedApplication, approval: RunApproval, capabilities: CapabilityProfile,
         developerDirectory: URL, stateDirectory: URL, leases: AutomationDeviceLeaseManager,
         artifacts: AutomationArtifactRegistry, subjectVerifier: any AutomationSubjectVerifier,
         releaseVerifier: any AutomationDeviceReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil, siriAuthority: AutomationSiriRouteAuthority? = nil, commands: Commands?) throws {
        try AutomationPhysicalExecutable.validateTarget(prepared.host.target)
        guard prepared.host.app == approval.app, prepared.host.target == approval.target,
              prepared.generatedHost.includesSiri == true, prepared.host.app.platform == "ios",
              (prepared.host.app.productDigestVersion ?? 1) == 1, (prepared.host.hostProductDigestVersion ?? 1) == 1,
              prepared.host.testTarget.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        self.prepared = prepared; self.approval = approval; self.capabilities = capabilities; self.siriAuthority = siriAuthority
        self.commands = commands
        developer = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = try AutomationPath.canonical(stateDirectory)
        self.leases = leases; self.artifacts = artifacts; self.subjectVerifier = subjectVerifier
        self.releaseVerifier = releaseVerifier; self.campaignBudget = campaignBudget
    }

    public func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws {
        try scope.validate()
        guard admission == nil, !preparing, !executing, !releasing, !revoked,
              scope.runId == approval.runID, scope.runId == lease.runID, scope.segmentId == segment.id,
              scope.leaseGeneration == lease.generation, lease.target == plan.target, lease.control == .system,
              plan.app == prepared.host.app, plan.target == prepared.host.target,
              plan.environmentID == approval.environmentID, plan.execution == segment,
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)), let program = segment.siriProgram,
              await leases.isCurrent(lease) else {
            throw AutomationContractError.invalidPlan("Siri requires the exact approved physical subject and lease")
        }
        admission = (scope, lease)
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: siriAuthority)
        try AutomationSiriTextProgram.validateAdmission(plan: plan, approval: approval, capabilities: capabilities, authority: siriAuthority)
        try program.validate(segment: segment, target: plan.target)
        preparing = true; defer { preparing = false }
        try await subjectVerifier.verify(app: plan.app, target: plan.target)
        try await checkAdmission(scope, lease)
        controllerPrepared = true
        do { try await releaseVerifier.prepare(target: plan.target, controllerBundleIDs: [prepared.host.hostBundleID]) }
        catch { if error as? AutomationContractError == .terminationUnverified { inspectorUnproved = true }; throw error }
        try await checkAdmission(scope, lease); try verifyProducts()
        let directory = root.appendingPathComponent("siri-\(lease.generation)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var fields: [String: AutomationJSON] = ["schemaVersion": .number(1), "runID": .string(scope.runId),
            "attemptID": .string(scope.attemptId), "segmentID": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration)),
            "bundleID": .string(plan.app.bundleID), "productDigest": .string(try productDigest(plan.app)), "request": .string(program.request)]
        if let build = siriAuthority?.expectedOSBuild { fields["expectedOSBuild"] = .string(build) }
        if let version = plan.app.productDigestVersion { fields["productDigestVersion"] = .number(Double(version)) }
        let original = try AutomationReadOnlyFile.read(URL(fileURLWithPath: prepared.host.xctestrunPath), maximumBytes: 4_194_304)
        let plist = try PropertyListSerialization.propertyList(from: original, format: nil)
        let frozen = try AutomationAppleHostFile.freeze(plist,
            testRoot: URL(fileURLWithPath: prepared.host.xctestrunPath).deletingLastPathComponent(),
            expectedHost: URL(fileURLWithPath: prepared.host.hostBundlePath), expectedSubject: URL(fileURLWithPath: prepared.host.subjectProductPath),
            testTarget: prepared.host.testTarget, payload: JSONEncoder().encode(AutomationJSON.object(fields)), platform: .physicalIOS, purpose: .siriSubmission)
        let data = try PropertyListSerialization.data(fromPropertyList: frozen, format: .xml, options: 0)
        let testFile = directory.appendingPathComponent("host.xctestrun")
        let privatePayload = try AutomationAppleHostPayloadFile(data: data, url: testFile, scope: scope)
        payload = privatePayload
        try await leases.recordPrivatePayload(privatePayload, lease: lease)
        try await checkAdmission(scope, lease)
        try privatePayload.write(data)
        active = .init(plan: plan, segment: segment, scope: scope, lease: lease, directory: directory, testFile: testFile,
                       digest: AutomationArtifactRegistry.digest(data))
    }

    public func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard var state = active, state.plan == plan, state.segment == segment, state.scope == scope, state.lease == lease,
              !state.issued, !executing, !preparing, let program = segment.siriProgram else { throw AutomationContractError.unknownLease }
        try requireAdmission(scope, lease)
        state.issued = true; active = state; executing = true
        defer { executing = false }
        try await subjectVerifier.verify(app: plan.app, target: plan.target)
        for product in [prepared.host.subjectProductPath, prepared.host.hostBundlePath] {
            let signed = try await run(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", product], scope: scope, lease: lease, timeout: .seconds(30))
            guard signed.exitStatus == 0, !signed.logsTruncated else { throw AutomationContractError.conflictingOperation }
        }
        try await campaignBudget?.reserveOperations(id: scope.attemptId + "." + scope.segmentId, phase: .subject, count: 1)
        let resultPath = state.directory.appendingPathComponent("siri.xcresult")
        let result = try await run(arguments: ["xcodebuild", "test-without-building", "-xctestrun", state.testFile.path,
            "-destination", "platform=iOS,id=" + plan.target.id, "-only-testing:" + prepared.host.testTarget + "/SiriSubmissionTests/testSubmitRecognizedText",
            "-parallel-testing-enabled", "NO", "-jobs", "2", "-resultBundlePath", resultPath.path], scope: scope, lease: lease,
            timeout: .seconds(min(120, plan.budget.wallClockSeconds)))
        guard result.exitStatus == 0, !result.logsTruncated else { throw AutomationContractError.ambiguousDispatch }
        let attachmentRoot = state.directory.appendingPathComponent("attachments")
        let exported = try await run(arguments: ["xcresulttool", "export", "attachments", "--path", resultPath.path,
            "--output-path", attachmentRoot.path], scope: scope, lease: lease, timeout: .seconds(30))
        guard exported.exitStatus == 0, !exported.logsTruncated else { throw AutomationContractError.ambiguousDispatch }
        let files = try FileManager.default.contentsOfDirectory(at: attachmentRoot, includingPropertiesForKeys: nil)
        guard files.count <= 1000 else { throw AutomationContractError.ambiguousDispatch }
        var matching: [(Data, AutomationImportedSiriSubmission)] = []
        for file in files where file.pathExtension == "json" || file.pathExtension.isEmpty {
            guard let data = try? AutomationReadOnlyFile.read(root: attachmentRoot, relativePath: file.lastPathComponent, maximumBytes: 16_384),
                  let receipt = try? AutomationSiriSubmissionReceipt.importReceipt(data, scope: scope, app: plan.app, program: program) else { continue }
            matching.append((data, receipt))
        }
        guard matching.count == 1 else { throw AutomationContractError.ambiguousDispatch }
        let (data, receipt) = matching[0]
        let info = try hostInfo()
        guard let executable = info["CFBundleExecutable"] as? String,
              AutomationPhysicalControllerValidation.matchesExecutablePath(receipt.executablePath,
                bundleName: URL(fileURLWithPath: prepared.host.hostBundlePath).lastPathComponent, executableName: executable) else {
            throw AutomationContractError.ambiguousDispatch
        }
        guard siriAuthority?.expectedOSBuild == nil || receipt.osBuild == siriAuthority?.expectedOSBuild else { throw AutomationContractError.conflictingOperation }
        liveSubmission = receipt
        // Remote PIDs are never inspected or signalled on this Mac. Device release uses CoreDevice inventory.
        let artifact = try await artifacts.storeNativeEvidence(data: data, scope: scope)
        try requireAdmission(scope, lease)
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .siriText,
            dispatched: true, completed: true, artifact: artifact.handle, environmentID: plan.environmentID)
    }

    func qualificationSubmission() -> AutomationImportedSiriSubmission? { liveSubmission }

    public func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard admission?.0 == scope, admission?.1 == lease, !releasing else { return .init(commandsDrained: false, runnerTerminated: false) }
        revoked = true; releasing = true; defer { releasing = false }
        let stopped: Bool
        if let commands { stopped = await commands.stop() } else { stopped = await command.stopOwned() }
        let absent: Bool
        if controllerPrepared {
            absent = await releaseVerifier.verifyReleased(target: prepared.host.target, controllerBundleIDs: [prepared.host.hostBundleID])
        } else { absent = true }
        let drained = stopped && !preparing && !executing && !inspectorUnproved
        var cleaned = payload == nil
        if drained && absent, let payload {
            do {
                try payload.clean(scope: scope); try payload.recoveryReference.verifyClean()
                try await leases.retirePrivatePayload(payload, lease: lease); cleaned = true
            } catch { cleaned = false }
        }
        if drained && absent && cleaned { active = nil; admission = nil; payload = nil; controllerPrepared = false }
        return .init(commandsDrained: drained, runnerTerminated: absent && drained, privatePayloadCleaned: cleaned)
    }

    private func run(executable: String = "/usr/bin/xcrun", arguments: [String], scope: AutomationScope,
                     lease: AutomationDeviceLeaseManager.Lease, timeout: Duration) async throws -> AutomationOwnedCommand.Result {
        let bounded = min(timeout, try await campaignBudget?.remainingDuration() ?? timeout)
        do {
            try await authorize(scope, lease)
            let result: AutomationOwnedCommand.Result
            if let commands { result = try await commands.run(executable, arguments, root, bounded) }
            else { result = try await command.run(executable: URL(fileURLWithPath: executable), arguments: arguments, directory: root,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path, "HOME": root.path, "TMPDIR": root.path],
                timeout: bounded, willStart: { try await self.authorize(scope, lease) },
                didStart: { [leases] identity in try await leases.recordRunner(.init(scope: scope, process: identity, role: .nativeCommand, executablePath: executable), lease: lease) }) }
            _ = try await artifacts.storeNativeEvidence(data: result.stdout + result.stderr, scope: scope)
            try await authorize(scope, lease); return result
        } catch {
            if error as? AutomationContractError == .terminationUnverified { inspectorUnproved = true }
            let logs = await command.retainedLogs()
            _ = try? await artifacts.storeNativeEvidence(data: logs.stdout + logs.stderr, scope: scope)
            throw error
        }
    }
    private func authorize(_ scope: AutomationScope, _ lease: AutomationDeviceLeaseManager.Lease) async throws {
        try requireAdmission(scope, lease)
        guard executing, await leases.isCurrent(lease), let active, active.scope == scope,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(active.testFile, maximumBytes: 4_194_304)) == active.digest else {
            throw AutomationContractError.unknownLease
        }
        try Task.checkCancellation(); try campaignBudget?.validateDeadline(); try verifyProducts()
    }
    private func requireAdmission(_ scope: AutomationScope, _ lease: AutomationDeviceLeaseManager.Lease) throws {
        guard admission?.0 == scope, admission?.1 == lease, !revoked, !releasing else { throw AutomationContractError.unknownLease }
    }
    private func checkAdmission(_ scope: AutomationScope, _ lease: AutomationDeviceLeaseManager.Lease) async throws {
        guard await leases.isCurrent(lease) else { throw AutomationContractError.unknownLease }
        try requireAdmission(scope, lease); try Task.checkCancellation()
    }
    private func verifyProducts() throws {
        guard try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.hostBundlePath)) == prepared.host.hostProductDigest,
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.subjectProductPath)) == prepared.host.app.productDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: prepared.host.xctestrunPath), maximumBytes: 4_194_304)) == prepared.host.xctestrunDigest,
              try hostInfo()["CFBundleIdentifier"] as? String == prepared.host.hostBundleID else { throw AutomationContractError.conflictingOperation }
    }
    private func hostInfo() throws -> [String: Any] {
        guard let info = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(root: URL(fileURLWithPath: prepared.host.hostBundlePath),
            relativePath: "Info.plist", maximumBytes: 1_048_576), format: nil) as? [String: Any] else { throw AutomationContractError.invalidIdentity }
        return info
    }
    private func productDigest(_ app: AppIdentity) throws -> String {
        guard let digest = app.productDigest else { throw AutomationContractError.invalidIdentity }; return digest
    }
}
#endif
