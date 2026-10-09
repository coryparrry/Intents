#if os(macOS)
import Foundation
import Darwin

/// Private Mac associated-host execution source. Customer selection is not wired to this driver.
/// Runtime qualification must establish the actual XCTest child-process closure before admission.
actor AutomationPrivateMacAppleRouteDriver: AutomationResolvedRouteDriver {
    struct Commands: Sendable {
        var run: @Sendable ([String], URL, Duration) async throws -> AutomationOwnedCommand.Result
        var stop: @Sendable () async -> Bool
        var afterPayloadWrite: (@Sendable () throws -> Void)? = nil
        var runnerPresence: (@Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence)? = nil
    }
    private struct Control {
        var scope: AutomationScope
        var lease: AutomationDeviceLeaseManager.Lease
        var plan: AutomationCase
        var segment: AutomationSegment
        var directory: URL
        var testFile: URL
        var testFileDigest: String
        var executing = false
        var issued = false
        var runner: AutomationProcessIdentity?
    }
    private let validateTarget: AutomationMacAssociatedHostReleaseVerifier.TargetValidator
    private let prepared: AutomationPreparedAppleHost
    private let approval: RunApproval
    private let capabilities: CapabilityProfile
    private let developerDirectory: URL
    private let root: URL
    private let leases: AutomationDeviceLeaseManager
    private let artifacts: AutomationArtifactRegistry
    private let subjectVerifier: any AutomationSubjectVerifier
    private let releaseVerifier: any AutomationDeviceReleaseVerifier
    private let campaignBudget: AutomationCampaignBudget?
    private let command = AutomationOwnedCommand()
    private let commands: Commands?
    private var admission: (scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease)?
    private var privatePayload: AutomationAppleHostPayloadFile?
    private var controllerPreparationStarted = false
    private var control: Control?
    private var preparing = false
    private var releasing = false
    private var inspectionUnreleased = false
    private var revoked: Set<Int> = []
    private var liveRuntimeContext: AutomationLiveAppleRuntimeContext?
    init(prepared: AutomationPreparedAppleHost, approval: RunApproval, developerDirectory: URL, stateDirectory: URL,
                leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, subjectVerifier: any AutomationSubjectVerifier,
                releaseVerifier: any AutomationDeviceReleaseVerifier, campaignBudget: AutomationCampaignBudget? = nil, capabilities: CapabilityProfile = .init(),
                validateTarget: @escaping AutomationMacAssociatedHostReleaseVerifier.TargetValidator = { try AutomationMacGUIIdentity.validate($0) },
                commands: Commands? = nil) throws {
        guard prepared.app == approval.app, prepared.target == approval.target, prepared.target.kind == .nativeMac, prepared.app.platform == "macos",
              prepared.app.productDigestVersion == 2, prepared.hostProductDigestVersion == 2,
              prepared.hostBundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil,
              prepared.testTarget.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        _ = try AutomationMacAssociatedHostReleaseVerifier.profile(prepared)
        try validateTarget(prepared.target); self.validateTarget = validateTarget
        self.commands = commands
        self.prepared = prepared; self.approval = approval; self.capabilities = capabilities; self.developerDirectory = try AutomationPath.canonical(developerDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = try AutomationPath.canonical(stateDirectory); self.leases = leases; self.artifacts = artifacts
        self.subjectVerifier = subjectVerifier; self.releaseVerifier = releaseVerifier; self.campaignBudget = campaignBudget
    }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: nil)
    }
    func acquireResolved(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                         authority: AutomationSegmentResolutionAuthority) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: authority)
    }
    private func acquireAuthorized(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                                   authority: AutomationSegmentResolutionAuthority?) async throws {
        guard admission == nil, control == nil, !preparing, !releasing, !revoked.contains(lease.generation), lease.control == .system, lease.target == prepared.target, lease.runID == approval.runID,
              scope.runId == approval.runID, scope.leaseGeneration == lease.generation, segment.lifecycle == .persistedStateAcrossSegments,
              plan.app == prepared.app, plan.target == prepared.target, plan.app == approval.app, plan.target == approval.target,
              plan.environmentID == approval.environmentID, scope.segmentId == segment.id, let program = segment.hostProgram else { throw AutomationContractError.unknownLease }
        guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)),
              try (Self.exactMember(segment, plan: plan) || authority?.matches(plan: plan, segment: segment, scope: scope) == true),
              segment.effects.isSubset(of: approval.effects), program.operations.count <= approval.maximumActions else {
            throw AutomationContractError.invalidPlan("Mac system execution requires this exact reviewed case and approved effects")
        }
        // Authenticate a no-work admission so a local preflight denial can drain its exact lease.
        admission = (scope, lease); controllerPreparationStarted = false
        liveRuntimeContext = nil
        // Direct driver users must satisfy the same execution contract as the coordinator.
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        try AutomationCodecRequirements.validate(segment, plan: plan, capabilities: capabilities)
        try program.validate(route: segment.kind, phase: segment.phase)
        preparing = true; defer { preparing = false }
        let fileInputs = try await authority?.fileInputs(plan: plan, segment: segment, scope: scope, artifacts: artifacts) ?? [:]
        let payload = try program.executionPayload(scope: scope, app: plan.app, route: segment.kind, phase: segment.phase, fileInputs: fileInputs)
        guard await leases.isCurrent(lease), !revoked.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation()
        do {
            try await verifySubject(plan)
            guard !revoked.contains(lease.generation) else { throw AutomationContractError.unknownLease }
            controllerPreparationStarted = true
            try await releaseVerifier.prepare(target: plan.target, controllerBundleIDs: [prepared.hostBundleID])
        }
        catch { if error as? AutomationContractError == .terminationUnverified { inspectionUnreleased = true }; throw error }
        try verifyPreparedHost()
        let current = await leases.isCurrent(lease)
        guard current, !revoked.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        let directory = root.appendingPathComponent("system-\(lease.generation)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let testFile = directory.appendingPathComponent("host.xctestrun")
        let data = try AutomationReadOnlyFile.read(URL(fileURLWithPath: prepared.xctestrunPath), maximumBytes: 4 * 1024 * 1024)
        guard AutomationArtifactRegistry.digest(data) == prepared.xctestrunDigest else { throw AutomationContractError.conflictingOperation }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let frozen = try AutomationAppleHostFile.freeze(plist, testRoot: URL(fileURLWithPath: prepared.xctestrunPath).deletingLastPathComponent(),
                                                      expectedHost: URL(fileURLWithPath: prepared.hostBundlePath), expectedSubject: URL(fileURLWithPath: prepared.subjectProductPath), testTarget: prepared.testTarget, payload: payload, platform: .macOS)
        let frozenData = try PropertyListSerialization.data(fromPropertyList: frozen, format: .xml, options: 0)
        let payloadFile = try AutomationAppleHostPayloadFile(data: frozenData, url: testFile, scope: scope)
        privatePayload = payloadFile
        try await leases.recordPrivatePayload(payloadFile, lease: lease)
        guard await leases.isCurrent(lease), !revoked.contains(lease.generation), !releasing else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation()
        try payloadFile.write(frozenData)
        try commands?.afterPayloadWrite?()
        control = .init(scope: scope, lease: lease, plan: plan, segment: segment, directory: directory, testFile: testFile,
                        testFileDigest: AutomationArtifactRegistry.digest(frozenData))
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard var active = control, active.scope == scope, active.lease == lease, active.plan == plan, active.segment == segment,
              !active.executing, !active.issued, !releasing, !revoked.contains(lease.generation), let program = active.segment.hostProgram else { throw AutomationContractError.unknownLease }
        guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)),
              try Self.exactSegment(active.segment, segment) else { throw AutomationContractError.conflictingOperation }
        // Consume authority before the first suspension; competing calls cannot retain an unissued snapshot.
        active.executing = true; active.issued = true; control = active
        defer { if control?.scope == scope { control?.executing = false } }
        let current = await leases.isCurrent(lease)
        guard current, !releasing, !revoked.contains(lease.generation), control?.scope == scope,
              control?.executing == true, control?.issued == true else { throw AutomationContractError.unknownLease }
        try verifyPreparedHost(); try await verifySubject(plan)
        try await authorizeLaunch(scope: scope, lease: lease)
        try await campaignBudget?.reserveOperations(id: scope.attemptId + "." + scope.segmentId, phase: segment.phase, count: program.operations.count)
        try await authorizeLaunch(scope: scope, lease: lease)
        let resultPath = active.directory.appendingPathComponent("system.xcresult")
        let result = try await run(["xcodebuild", "test-without-building", "-xctestrun", active.testFile.path,
            "-destination", "platform=macOS", "-only-testing:" + prepared.testTarget + "/SegmentTests/testSegment",
            "-jobs", "2", "-parallel-testing-enabled", "NO", "-resultBundlePath", resultPath.path], scope: scope, lease: lease, timeout: .seconds(180))
        if program.usesFiles { _ = try await artifacts.storeNativeEvidence(data: result.stdout + result.stderr, scope: scope) }
        else { _ = try await artifacts.store(data: result.stdout + result.stderr, name: "apple-log-\(lease.generation).txt", scope: scope) }
        guard result.exitStatus == 0 else { throw AutomationContractError.ambiguousDispatch }
        let attachmentRoot = active.directory.appendingPathComponent("attachments")
        let exported = try await run(["xcresulttool", "export", "attachments", "--path", resultPath.path, "--output-path", attachmentRoot.path], scope: scope, lease: lease, timeout: .seconds(30))
        guard exported.exitStatus == 0 else { throw AutomationContractError.missingEvidence("Apple attachments unavailable") }
        let data: Data, receipt: AutomationImportedHostReceipt
        if program.usesFiles {
            let imported = try await AutomationHostFileAttachments.importExport(root: attachmentRoot, scope: scope, app: plan.app, program: program, artifacts: artifacts, planDigest: AutomationFrozenCase.planDigest(plan))
            data = imported.receiptData; receipt = imported.receipt
        } else {
            let files = try FileManager.default.contentsOfDirectory(at: attachmentRoot, includingPropertiesForKeys: [.isRegularFileKey])
            guard files.count <= 1000 else { throw AutomationContractError.missingEvidence("Attachment budget exceeded") }
            var matching: [(Data, AutomationImportedHostReceipt)] = []
            for file in files where file.pathExtension == "json" && file.lastPathComponent != "manifest.json" {
                let data = try AutomationReadOnlyFile.read(root: attachmentRoot, relativePath: file.lastPathComponent, maximumBytes: 1_048_576)
                if let receipt = try? AutomationHostReceiptImporter.importReceipt(data, scope: scope, app: plan.app, program: program) { matching.append((data, receipt)) }
            }
            guard matching.count == 1 else { throw AutomationContractError.missingEvidence("No unique completed correlated Apple receipt") }
            (data, receipt) = matching[0]
        }
        try await authorizeLaunch(scope: scope, lease: lease)
        let expectedExecutable = try AutomationMacAssociatedHostReleaseVerifier.profile(prepared).executable.path
        guard receipt.executablePath == expectedExecutable else { throw AutomationContractError.terminationUnverified }
        if receipt.runner.presence() == .matching {
            // Both kernel start identity and exact prepared executable are required before ownership.
            guard let executable = Self.executablePath(receipt.runner), executable == expectedExecutable else { throw AutomationContractError.terminationUnverified }
            try await leases.recordRunner(.init(scope: scope, process: receipt.runner, role: .appleHost, executablePath: executable), lease: lease)
            control?.runner = receipt.runner
        } else if receipt.runner.presence() != .absent { throw AutomationContractError.terminationUnverified }
        try verifyPreparedHost(); try await verifySubject(plan)
        try await authorizeLaunch(scope: scope, lease: lease)
        let artifact = try await artifacts.store(data: data, name: "apple-receipt-\(lease.generation).json", scope: scope)
        let observations: [AutomationObservation]
        if segment.phase == .observe, segment.kind == .systemQuery, program.operations.count == 1, let value = receipt.values[program.operations[0].id] {
            observations = [.init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: scope.attemptId, stepID: segment.id, route: segment.kind, proof: .appState, value: value)]
        } else { observations = [] }
        try await authorizeLaunch(scope: scope, lease: lease)
        var segmentReceipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true, observations: observations, artifact: artifact.handle, verifiedOutputs: receipt.values, environmentID: plan.environmentID)
        if program.usesFiles { segmentReceipt.hostReceiptDigest = AutomationArtifactRegistry.digest(data) }
        // Injected command fixtures cannot mint live context, even with realistic receipt labels.
        if commands == nil, let observation = receipt.runtimeObservation {
            liveRuntimeContext = try? .init(host: prepared, plan: plan, receipt: segmentReceipt, rawReceipt: data,
                developerDirectory: developerDirectory, observation: observation)
        }
        try await authorizeLaunch(scope: scope, lease: lease)
        return segmentReceipt
    }
    func runtimeContext(report: AutomationAttemptReport, plan: AutomationCase) -> AutomationLiveAppleRuntimeContext? {
        guard control == nil, admission == nil, !releasing, !preparing, report.resourcesReleased,
              let context = liveRuntimeContext, (try? context.matches(report: report, plan: plan, host: prepared)) == true else { return nil }
        return context
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard admission?.scope == scope, admission?.lease == lease, !releasing else { return .init(commandsDrained: false, runnerTerminated: false) }
        revoked.insert(lease.generation)
        releasing = true; defer { releasing = false }
        guard let active = control else {
            var independent = true
            if controllerPreparationStarted { independent = await releaseVerifier.verifyReleased(target: prepared.target, controllerBundleIDs: [prepared.hostBundleID]) }
            let terminated = !preparing && !inspectionUnreleased && independent
            let cleaned = !preparing && terminated ? await cleanPrivatePayload(scope: scope, lease: lease) : privatePayload == nil
            if terminated && cleaned { admission = nil; controllerPreparationStarted = false; privatePayload = nil }
            return .init(commandsDrained: !preparing, runnerTerminated: terminated, privatePayloadCleaned: cleaned)
        }
        guard active.scope == scope, active.lease == lease else { return .init(commandsDrained: false, runnerTerminated: false) }
        let commandStopped: Bool
        if let commands { commandStopped = await commands.stop() } else { commandStopped = await command.stopOwned() }
        var runnerStopped = true
        let presence: (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence = commands?.runnerPresence ?? { $0.presence() }
        if let runner = control?.runner {
            switch presence(runner) {
            case .matching:
                guard let expected = try? AutomationMacAssociatedHostReleaseVerifier.profile(prepared).executable.path,
                      Self.executablePath(runner) == expected, presence(runner) == .matching else {
                    runnerStopped = false; break
                }
                _ = kill(runner.pid, SIGTERM)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while presence(runner) == .matching, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                runnerStopped = presence(runner) == .absent || presence(runner) == .replaced
            case .absent, .replaced: break
            case .unknown: runnerStopped = false
            }
        }
        let deviceReleased = await releaseVerifier.verifyReleased(target: prepared.target, controllerBundleIDs: [prepared.hostBundleID])
        let drained = control?.executing == false
        let terminated = commandStopped && runnerStopped && deviceReleased && !inspectionUnreleased
        let cleaned = drained && terminated ? await cleanPrivatePayload(scope: scope, lease: lease) : privatePayload == nil
        if drained && terminated && cleaned { control = nil; admission = nil; controllerPreparationStarted = false; privatePayload = nil }
        return .init(commandsDrained: drained, runnerTerminated: terminated, privatePayloadCleaned: cleaned)
    }
    private func cleanPrivatePayload(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> Bool {
        guard let privatePayload else { return true }
        do {
            try privatePayload.clean(scope: scope)
            try await leases.retirePrivatePayload(privatePayload, lease: lease)
            return true
        } catch { return false }
    }
    private func authorizeLaunch(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        let current = await leases.isCurrent(lease)
        guard current, control?.scope == scope, control?.executing == true, !releasing, !revoked.contains(lease.generation) else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation(); try validateTarget(prepared.target); try verifyPreparedHost()
        guard let active = control,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(active.testFile, maximumBytes: 4 * 1024 * 1024)) == active.testFileDigest else {
            throw AutomationContractError.conflictingOperation
        }
        try campaignBudget?.validateDeadline()
    }
    private func verifySubject(_ plan: AutomationCase) async throws {
        do { try validateTarget(plan.target); try await subjectVerifier.verify(app: plan.app, target: plan.target); try validateTarget(plan.target) }
        catch { if error as? AutomationContractError == .terminationUnverified { inspectionUnreleased = true }; throw error }
    }
    private func run(_ arguments: [String], scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease, timeout: Duration) async throws -> AutomationOwnedCommand.Result {
        let leases = self.leases
        let boundedTimeout = min(timeout, try await campaignBudget?.remainingDuration() ?? timeout)
        if let commands {
            try await authorizeLaunch(scope: scope, lease: lease)
            return try await commands.run(arguments, root, boundedTimeout)
        }
        do { return try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, directory: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path, "HOME": root.path, "TMPDIR": root.path], timeout: boundedTimeout,
            willStart: { try await self.authorizeLaunch(scope: scope, lease: lease) },
            didStart: { identity in try await leases.recordRunner(.init(scope: scope, process: identity, role: .appleHost, executablePath: "/usr/bin/xcrun"), lease: lease) }) }
        catch {
            if error as? AutomationContractError == .terminationUnverified { inspectionUnreleased = true }
            let retained = await command.retainedLogs()
            if control?.segment.hostProgram?.usesFiles == true { _ = try? await artifacts.storeNativeEvidence(data: retained.stdout + retained.stderr, scope: scope) }
            else { _ = try? await artifacts.store(data: retained.stdout + retained.stderr, name: "apple-command-failure-\(scope.leaseGeneration)-\(UUID().uuidString).txt", scope: scope) }
            throw error
        }
    }
    private func verifyPreparedHost() throws {
        let subject = URL(fileURLWithPath: prepared.subjectProductPath), test = URL(fileURLWithPath: prepared.xctestrunPath)
        guard try AutomationPath.canonical(subject).path == subject.path,
              try AutomationProductDigest.compute(bundle: subject, version: 2) == prepared.app.productDigest,
              try AutomationPath.canonical(test).path == test.path,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(test, maximumBytes: 4 * 1024 * 1024)) == prepared.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
        _ = try AutomationMacAssociatedHostReleaseVerifier.profile(prepared)
    }
    private static func exactMember(_ segment: AutomationSegment, plan: AutomationCase) throws -> Bool {
        // A reviewed template with unresolved inputs is not an executable literal program.
        guard segment.inputBindings?.isEmpty != false, segment.attemptTextBindings?.isEmpty != false,
              segment.hostProgram?.operations.contains(where: { $0.attemptQueryPrefix != nil }) != true else { return false }
        for member in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            if try exactSegment(member, segment) { return true }
        }
        return false
    }
    private static func exactSegment(_ lhs: AutomationSegment, _ rhs: AutomationSegment) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }
    private static func executablePath(_ process: AutomationProcessIdentity) -> String? {
        guard process.presence() == .matching else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(process.pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Ephemeral authority, issued only in this file by a non-injected owned Apple driver.
/// Retained reports, imported observations and caller labels cannot reconstruct it.
struct AutomationLiveAppleRuntimeContext: Sendable {
    private let host: AutomationPreparedAppleHost
    private let planDigest: String, segmentDigest: String
    private let scope: AutomationScope
    private let snapshot: AutomationMacAppleRuntimeSnapshot
    let rawReceiptDigest: String
    var evidence: [String] {
        [rawReceiptDigest, snapshot.observation.processOSBuild, snapshot.observation.architecture,
         snapshot.observation.xcodeBuild, snapshot.observation.sdkBuild, snapshot.observation.frameworkUUID,
         snapshot.observation.frameworkSHA256, snapshot.xcodeVersionDigest, snapshot.sdkVersionDigest, snapshot.hostInfoDigest]
    }
    fileprivate init(host: AutomationPreparedAppleHost, plan: AutomationCase, receipt: AutomationSegmentReceipt,
                     rawReceipt: Data, developerDirectory: URL, observation: AutomationAppleRuntimeObservation) throws {
        self.host = host; scope = receipt.scope
        planDigest = try AutomationFrozenCase.planDigest(plan); segmentDigest = try Self.digest(receipt)
        rawReceiptDigest = AutomationArtifactRegistry.digest(rawReceipt)
        snapshot = try .observe(host: host, developerDirectory: developerDirectory, observation: observation)
    }
    func matches(report: AutomationAttemptReport, plan: AutomationCase, host: AutomationPreparedAppleHost) throws -> Bool {
        guard self.host == host, report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
              report.attemptID == scope.attemptId, try AutomationFrozenCase.planDigest(plan) == planDigest,
              report.receipts.filter({ $0.scope == scope }).count == 1,
              let receipt = report.receipts.first(where: { $0.scope == scope }), try Self.digest(receipt) == segmentDigest else { return false }
        try snapshot.validate(host: host)
        return true
    }
    func validate(host: AutomationPreparedAppleHost) throws {
        guard self.host == host else { throw AutomationContractError.conflictingOperation }
        try snapshot.validate(host: host)
    }
    private static func digest(_ receipt: AutomationSegmentReceipt) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AutomationArtifactRegistry.digest(try encoder.encode(receipt))
    }
}
#endif
