#if os(macOS)
import Foundation

/// Owns a read-only real-record query followed by non-performing parameter readback.
/// No action invocation is used to qualify conversion, and no remote PID is signalled.
enum AutomationPhysicalInputAdapterQualification {
    static func run(prepared: AutomationPreparedApplication, baseline: AutomationCase, actionID: String,
                    approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                    root: URL, developer: URL, leases: AutomationDeviceLeaseManager) async throws -> AutomationPhysicalInputAdapterReport {
        try AutomationSiriQualificationProposal.validateSingle(plan: baseline, approval: approval)
        guard await AutomationPreparedCodecAuthority.shared.contains(prepared), prepared.host.app == baseline.app,
              prepared.host.target == baseline.target, attemptID.range(of: #"^[A-Za-z0-9-]{1,100}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        var limits = AutomationCampaignLimits.firstCampaign; limits.attempts = 2; limits.wallClockSeconds = 600
        let budget = try AutomationCampaignBudget(limits: limits)
        let queryID = attemptID + "-query"
        var querySegment = baseline.setup[0]; querySegment.id = "query"; querySegment.phase = .subject
        let queryPlan = AutomationCase(id: "physical-input-query-" + attemptID, app: baseline.app, target: baseline.target,
            environmentID: baseline.environmentID, execution: querySegment)
        var queryApproval = RunApproval(runID: approval.runID, app: baseline.app, target: baseline.target,
            environmentID: baseline.environmentID, effects: [.observe], maximumActions: 20, disposable: true)
        queryApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(queryPlan)
        try await budget.reserveAttempt(id: queryID)
        let queryReport = try await AutomationPreparedPhysicalCampaign.run(prepared: prepared, plan: queryPlan, approval: queryApproval,
            capabilities: capabilities, attemptID: queryID, root: root, developer: developer, leases: leases, campaignBudget: budget)
        guard queryReport.resourcesReleased, queryReport.result.subjectCompleted, !queryReport.result.subjectDispatchUncertain,
              let predicate = baseline.setupChecks?.first?.entityProperty, let operation = querySegment.hostProgram?.operations.first,
              let output = queryReport.receipts.first(where: { $0.segmentID == querySegment.id })?.verifiedOutputs?[operation.id] else {
            return .init(queryReport: queryReport, resourcesReleased: queryReport.resourcesReleased, qualified: false,
                failure: "Read-only record query was incomplete or did not release ownership", artifact: nil)
        }
        try AutomationRecordedEvidence.validate(report: queryReport, plan: queryPlan, expectedRunID: approval.runID)
        guard case .entity(_, let entityID) = try predicate.selection.resolve(output, query: operation) else { throw AutomationContractError.missingEvidence("Select one actual query record") }
        let state = root.appendingPathComponent(attemptID + "-probe")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let host = prepared.host
        let info = try plist(URL(fileURLWithPath: host.hostBundlePath).appendingPathComponent("Info.plist"))
        let testInfo = try plist(URL(fileURLWithPath: host.hostBundlePath).appendingPathComponent("PlugIns/" + host.testTarget + ".xctest/Info.plist"))
        guard testInfo["DTPlatformName"] as? String == "iphoneos", let sdk = testInfo["DTSDKBuild"] as? String,
              let xcode = testInfo["DTXcodeBuild"] as? String, let executable = info["CFBundleExecutable"] as? String else { throw AutomationContractError.invalidIdentity }
        let plan = try AutomationPhysicalInputAdapterPlan(prepared: prepared, baseline: baseline, actionID: actionID,
            entityID: entityID, sdkBuild: sdk, xcodeBuild: xcode, runnerExecutable: executable)
        let selected = try AutomationInstalledUIApplication.preparedPhysicalProduct(prepared)
        let installation = try JSONDecoder().decode(AutomationPhysicalInstallationReceipt.self, from:
            AutomationReadOnlyFile.read(root: root.appendingPathComponent(queryID), relativePath: "owned-installation.json", maximumBytes: 131_072))
        guard installation.scope.runId == approval.runID, installation.scope.attemptId == queryID else { throw AutomationContractError.conflictingOperation }
        let installed = try AutomationPhysicalInstalledUIApplication(installation: installation, selected: selected)
        let positive = try AutomationPhysicalInstalledSubjectVerifier(selected: installed, workspace: state, developerDirectory: developer)
        let subject = AutomationPreparedPhysicalSubjectVerifier(selected: selected, installed: installed, verifier: positive)
        let release = try AutomationPhysicalDeviceReleaseVerifier(workspace: state, developerDirectory: developer,
            controllers: [.init(bundleID: host.hostBundleID, executableName: executable)])
        try await release.bindDevice(installed.deviceIdentifier)
        let artifacts = try AutomationArtifactRegistry(root: state.appendingPathComponent("artifacts"), secretEvidenceRoot: root.appendingPathComponent("secret-evidence"))
        try await budget.reserveAttempt(id: attemptID + "-probe")
        let runner = try AutomationPhysicalInputAdapterRunner(plan: plan, runID: approval.runID, root: state, developer: developer,
            leases: leases, artifacts: artifacts, subject: subject, release: release, budget: budget)
        let result = try await runner.run(attemptID: attemptID + "-probe")
        var expiresAt: ContinuousClock.Instant?
        if let observation = result.observation, result.released {
            expiresAt = try await AutomationPhysicalInputAdapterAuthority.shared.record(plan: plan, observation: observation, released: result.released)
        }
        return .init(queryReport: queryReport, resourcesReleased: result.released, qualified: result.observation != nil && result.released,
            failure: result.failure, artifact: result.artifact, expiresAt: expiresAt)
    }
    private static func plist(_ path: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(path, maximumBytes: 1_048_576), format: nil) as? [String: Any] else { throw AutomationContractError.invalidIdentity }
        return value
    }
}

actor AutomationPhysicalInputAdapterRunner {
    struct Result: Sendable { let observation: AutomationPhysicalInputAdapterObservation?; let released: Bool; let failure: String?; let artifact: String? }
    private let plan: AutomationPhysicalInputAdapterPlan, runID: String, root: URL, developer: URL
    private let leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, budget: AutomationCampaignBudget
    private let subject: any AutomationSubjectVerifier, release: AutomationPhysicalDeviceReleaseVerifier
    private let command = AutomationOwnedCommand()
    private var busy = false
    init(plan: AutomationPhysicalInputAdapterPlan, runID: String, root: URL, developer: URL,
         leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry, subject: any AutomationSubjectVerifier,
         release: AutomationPhysicalDeviceReleaseVerifier, budget: AutomationCampaignBudget) throws {
        self.plan = plan; self.runID = runID; self.root = root; self.developer = developer; self.leases = leases
        self.artifacts = artifacts; self.subject = subject; self.release = release; self.budget = budget
    }
    func run(attemptID: String) async throws -> Result {
        guard !busy else { throw AutomationContractError.targetBusy }; busy = true; defer { busy = false }
        let host = plan.prepared.host
        try await leases.reserveCampaign(runID: runID, target: host.target)
        let lease: AutomationDeviceLeaseManager.Lease
        do { lease = try await leases.acquire(runID: runID, target: host.target, control: .system) }
        catch {
            do { try await leases.releaseCampaign(runID: runID, target: host.target) }
            catch { throw AutomationContractError.terminationUnverified }
            throw error
        }
        let scope = AutomationScope(runID: runID, attemptID: attemptID, segmentID: "input-adapter", leaseGeneration: lease.generation)
        var payload: AutomationAppleHostPayloadFile?, observation: AutomationPhysicalInputAdapterObservation?, artifact: String?, failure: String?
        var inspectorUnproved = false
        do {
            try await authorize(lease)
            try await subject.verify(app: host.app, target: host.target)
            try await release.prepare(target: host.target, controllerBundleIDs: [host.hostBundleID])
            try await authorize(lease)
            let original = try AutomationReadOnlyFile.read(URL(fileURLWithPath: host.xctestrunPath), maximumBytes: 4_194_304)
            let frozen = try AutomationAppleHostFile.freeze(PropertyListSerialization.propertyList(from: original, format: nil),
                testRoot: URL(fileURLWithPath: host.xctestrunPath).deletingLastPathComponent(), expectedHost: URL(fileURLWithPath: host.hostBundlePath),
                expectedSubject: URL(fileURLWithPath: host.subjectProductPath), testTarget: host.testTarget, payload: plan.payload(scope: scope), platform: .physicalIOS, purpose: .inputAdapterProbe)
            let data = try PropertyListSerialization.data(fromPropertyList: frozen, format: .xml, options: 0)
            let testFile = root.appendingPathComponent("probe.xctestrun")
            let owned = try AutomationAppleHostPayloadFile(data: data, url: testFile, scope: scope); payload = owned
            try await leases.recordPrivatePayload(owned, lease: lease); try owned.write(data)
            let resultPath = root.appendingPathComponent("probe.xcresult")
            try await budget.reserveOperations(id: attemptID + ".roundtrip", phase: .observe, count: 3)
            let result = try await runCommand(["xcodebuild", "test-without-building", "-xctestrun", testFile.path,
                "-destination", "platform=iOS,id=" + host.target.id, "-only-testing:" + host.testTarget + "/PhysicalInputAdapterProbeTests/testRecordBoolRoundTrip",
                "-jobs", "2", "-parallel-testing-enabled", "NO", "-resultBundlePath", resultPath.path], scope: scope, lease: lease, testFile: testFile, digest: AutomationArtifactRegistry.digest(data))
            guard result.exitStatus == 0, !result.logsTruncated else { throw AutomationContractError.missingEvidence("Physical parameter readback XCTest did not complete") }
            let attachments = root.appendingPathComponent("attachments")
            let exported = try await runCommand(["xcresulttool", "export", "attachments", "--path", resultPath.path, "--output-path", attachments.path], scope: scope, lease: lease, testFile: testFile, digest: AutomationArtifactRegistry.digest(data))
            guard exported.exitStatus == 0, !exported.logsTruncated else { throw AutomationContractError.missingEvidence("Physical probe attachment export incomplete") }
            let files = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            guard files.count <= 1000 else { throw AutomationContractError.invalidIdentity }
            var matching: [(Data, AutomationPhysicalInputAdapterObservation)] = []
            for file in files where file.pathExtension == "json" && file.lastPathComponent != "manifest.json" {
                let bytes = try AutomationReadOnlyFile.read(root: attachments, relativePath: file.lastPathComponent, maximumBytes: 32_768)
                if let readback = try? AutomationPhysicalInputAdapterObservation.read(bytes, plan: plan, scope: scope) { matching.append((bytes, readback)) }
            }
            guard matching.count == 1 else { throw AutomationContractError.missingEvidence("One exact physical adapter receipt is required") }
            try await authorize(lease); try await subject.verify(app: host.app, target: host.target); try await authorize(lease)
            artifact = try await artifacts.storeNativeEvidence(data: matching[0].0, scope: scope).handle
            observation = matching[0].1
        } catch {
            inspectorUnproved = error as? AutomationContractError == .terminationUnverified
            failure = String(String(describing: error).prefix(4096))
        }
        do { try await budget.reserveResourceRelease(id: scope.attemptId + ".probe.release") }
        catch { failure = String(String(describing: error).prefix(4096)) }
        let drained = await command.stopOwned()
        let absent = await release.verifyReleased(target: host.target, controllerBundleIDs: [host.hostBundleID])
        var released = false
        do {
            guard drained && absent && !inspectorUnproved else { throw AutomationContractError.terminationUnverified }
            if let payload { try payload.clean(scope: scope); try payload.recoveryReference.verifyClean(); try await leases.retirePrivatePayload(payload, lease: lease) }
            try await leases.release(lease, commandsDrained: drained, ownedRunnerTerminated: absent)
            try await leases.releaseCampaign(runID: runID, target: host.target); released = true
        } catch { failure = String(String(describing: error).prefix(4096)) }
        if Task.isCancelled { failure = "Physical adapter qualification cancelled" }
        return .init(observation: released && failure == nil ? observation : nil, released: released, failure: failure, artifact: artifact)
    }
    private func authorize(_ lease: AutomationDeviceLeaseManager.Lease) async throws {
        guard await leases.isCurrent(lease) else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation(); try budget.validateDeadline()
        let host = plan.prepared.host
        guard try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: host.hostBundlePath)) == host.hostProductDigest,
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: host.subjectProductPath)) == host.app.productDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: host.xctestrunPath), maximumBytes: 4_194_304)) == host.xctestrunDigest else { throw AutomationContractError.conflictingOperation }
    }
    private func runCommand(_ arguments: [String], scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease, testFile: URL, digest: String) async throws -> AutomationOwnedCommand.Result {
        try await authorize(lease)
        guard AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(testFile, maximumBytes: 4_194_304)) == digest else { throw AutomationContractError.conflictingOperation }
        try await budget.reserveControllerCall(id: scope.attemptId + ".command." + arguments[0])
        let remaining = try await budget.remainingDuration()
        let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, directory: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path, "HOME": root.path, "TMPDIR": root.path], timeout: min(.seconds(120), remaining),
            willStart: { try await self.authorize(lease) }, didStart: { identity in
                try await self.leases.recordRunner(.init(scope: scope, process: identity, role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease)
            })
        _ = try await artifacts.storeNativeEvidence(data: result.stdout + result.stderr, scope: scope)
        try await authorize(lease)
        return result
    }
}
#endif
