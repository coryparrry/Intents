#if os(macOS) || os(Linux)
import Foundation
import IntentsAutomationUIHostContracts

/// Executes an entire mixed case with a single prepared UI-test invocation.
public actor AutomationXCUITestRouteDriver {
    private let prepared: AutomationPreparedAppleHost
    private let root: URL
    private let artifacts: AutomationArtifactRegistry
    private let developerDirectory: URL
    private let willStart: @Sendable () async throws -> Void
    private let didStart: @Sendable (AutomationProcessIdentity) async throws -> Void
    private let willWritePayload: @Sendable (AutomationDeviceLeaseManager.PrivatePayload) async throws -> Void
    private let didCleanPayload: @Sendable (AutomationDeviceLeaseManager.PrivatePayload) async throws -> Void
    private let simulatorTerminationVerifier: (@Sendable () async -> Bool)?
    private let command = AutomationOwnedCommand()
    private var executing = false
    private var payloadFile: URL?
    private var payloadDigest: String?
    private var privatePayload: AutomationAppleHostPayloadFile?
    private var revoked = false
    private var subjectStarted = false
    private var testStarted = false
    private var stopVerified = true

    public init(prepared: AutomationPreparedAppleHost, root: URL, artifacts: AutomationArtifactRegistry,
                developerDirectory: URL, willStart: @escaping @Sendable () async throws -> Void = {},
                didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in },
                willWritePayload: @escaping @Sendable (AutomationDeviceLeaseManager.PrivatePayload) async throws -> Void = { _ in },
                didCleanPayload: @escaping @Sendable (AutomationDeviceLeaseManager.PrivatePayload) async throws -> Void = { _ in }) {
        self.prepared = prepared; self.root = root; self.artifacts = artifacts; self.developerDirectory = developerDirectory
        self.willStart = willStart; self.didStart = didStart
        self.willWritePayload = willWritePayload; self.didCleanPayload = didCleanPayload
        self.simulatorTerminationVerifier = nil
    }

    /// Internal release-verification seam; public construction always runs simctl.
    init(prepared: AutomationPreparedAppleHost, root: URL, artifacts: AutomationArtifactRegistry,
         developerDirectory: URL, simulatorTerminationVerifier: @escaping @Sendable () async -> Bool) {
        self.prepared = prepared; self.root = root; self.artifacts = artifacts; self.developerDirectory = developerDirectory
        self.willStart = {}; self.didStart = { _ in }; self.willWritePayload = { _ in }; self.didCleanPayload = { _ in }
        self.simulatorTerminationVerifier = simulatorTerminationVerifier
    }

    public static func destination(_ target: TargetIdentity) throws -> String {
        guard !target.id.isEmpty, !target.id.contains(","), !target.id.contains("\0") else { throw AutomationContractError.invalidIdentity }
        switch target.kind {
        case .simulator: return "platform=iOS Simulator,id=" + target.id
        case .physical: return "platform=iOS,id=" + target.id
        case .nativeMac: return "platform=macOS"
        case .pairedRunner: throw AutomationContractError.missingEvidence("Paired target has no in-host UI test destination")
        }
    }

    public func execute(plan: AutomationCase, approval: RunApproval, attemptID: String,
                        leaseGeneration: Int = 1, timeout: Duration? = nil, excludedEntityIDs: Set<String> = []) async throws -> [AutomationSegmentReceipt] {
        try await execute(plan: plan, approval: approval, attemptID: attemptID, leaseGeneration: leaseGeneration,
            timeout: timeout, absoluteDeadline: nil, excludedEntityIDs: excludedEntityIDs)
    }
    func execute(plan: AutomationCase, approval: RunApproval, attemptID: String,
                 leaseGeneration: Int = 1, timeout: Duration? = nil, absoluteDeadline: ContinuousClock.Instant?,
                 excludedEntityIDs: Set<String> = []) async throws -> [AutomationSegmentReceipt] {
        guard !executing, !revoked, payloadFile == nil, prepared.app == plan.app, prepared.target == plan.target else { throw AutomationContractError.targetBusy }
        executing = true; defer { executing = false }
        let uiPlan = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: attemptID, leaseGeneration: leaseGeneration,
                                                       excludedEntityIDs: excludedEntityIDs)
        let commandTimeout = min(timeout ?? .seconds(plan.budget.wallClockSeconds), .seconds(plan.budget.wallClockSeconds))
        let relativeDeadline = ContinuousClock.now.advanced(by: commandTimeout)
        let deadline = min(relativeDeadline, absoluteDeadline ?? relativeDeadline)
        guard commandTimeout > .zero else { throw AutomationRPCError.timedOut }
        let directory = root.appendingPathComponent("xcuitest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: plan.execution.id, leaseGeneration: leaseGeneration)
        let source = URL(fileURLWithPath: prepared.xctestrunPath)
        let bytes = try AutomationReadOnlyFile.read(source, maximumBytes: 4 * 1024 * 1024)
        guard AutomationArtifactRegistry.digest(bytes) == prepared.xctestrunDigest else { throw AutomationContractError.conflictingOperation }
        let payload = try JSONEncoder().encode(uiPlan)
        let frozen = try Self.freeze(PropertyListSerialization.propertyList(from: bytes, format: nil), prepared: prepared, payload: payload)
        let testFile = directory.appendingPathComponent("ui.xctestrun")
        let frozenBytes = try PropertyListSerialization.data(fromPropertyList: frozen, format: .xml, options: 0)
        let authority = try AutomationAppleHostPayloadFile(data: frozenBytes, url: testFile, scope: scope)
        privatePayload = authority
        payloadFile = testFile
        payloadDigest = AutomationArtifactRegistry.digest(frozenBytes)
        try await willWritePayload(authority.recoveryReference)
        try Task.checkCancellation()
        guard !revoked, payloadFile == testFile, privatePayload != nil else { throw AutomationContractError.unknownLease }
        try authority.write(frozenBytes)
        let resultPath = directory.appendingPathComponent("ui.xcresult")
        var executionError: Error?
        var exitStatus: Int32 = -1
        do {
            try verifyPrepared()
            let result = try await run(["xcodebuild", "test-without-building", "-xctestrun", testFile.path,
                "-destination", Self.destination(plan.target), "-only-testing:" + prepared.testTarget + "/UIStepTests/testUISteps",
                // The host retains failure receipts/screenshots; a sysdiagnose can consume the entire attempt deadline.
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", resultPath.path],
                directory: directory, timeout: commandTimeout, absoluteDeadline: deadline, testInvocation: true)
            exitStatus = result.exitStatus
            _ = try await artifacts.store(data: result.stdout + result.stderr, name: "xcuitest-log-" + UUID().uuidString + ".txt", scope: scope)
        } catch { executionError = error }

        // Failed tests still export the step that failed and all earlier completed steps.
        let attachmentRoot = directory.appendingPathComponent("attachments")
        let recovered = await Task.detached { [self] in
            do {
                let export = try await run(["xcresulttool", "export", "attachments", "--path", resultPath.path,
                                            "--output-path", attachmentRoot.path], directory: directory, timeout: .seconds(30), authorize: false)
                guard export.exitStatus == 0 else { return [Data]() }
                return try await importAttachmentData(root: attachmentRoot, scope: scope)
            } catch { return [Data]() }
        }.value
        var receipts: [AutomationSegmentReceipt]
        do {
            receipts = try AutomationXCUITestReceiptImporter.importReceipts(recovered, uiPlan: uiPlan, plan: plan,
                                                                           allowPartial: executionError != nil || exitStatus != 0)
            for index in receipts.indices {
                let data = try JSONEncoder().encode(receipts[index])
                let artifact = try await artifacts.store(data: data, name: "xcuitest-receipt-" + UUID().uuidString + ".json", scope: receipts[index].scope)
                receipts[index].artifact = artifact.handle
            }
        } catch {
            let release = await release()
            let reason = Self.failureReason(error: executionError, receipts: [], stepReceipts: [], plan: plan)
            throw AutomationXCUITestFailure(receipts: [], reason: reason,
                                           resourcesReleased: release.commandsDrained && release.runnerTerminated && release.privatePayloadCleaned,
                                           subjectDispatchUncertain: testStarted)
        }
        if Task.isCancelled, executionError == nil { executionError = CancellationError() }
        if revoked, executionError == nil { executionError = AutomationContractError.unknownLease }
        if executionError != nil || exitStatus != 0 || receipts.contains(where: { !$0.completed }) {
            let release = await release()
            let steps = recovered.compactMap { try? JSONDecoder().decode(UIHostStepReceipt.self, from: $0) }
            let reason = Self.failureReason(error: executionError, receipts: receipts, stepReceipts: steps, plan: plan)
            throw AutomationXCUITestFailure(receipts: receipts, reason: reason,
                                           resourcesReleased: release.commandsDrained && release.runnerTerminated && release.privatePayloadCleaned,
                                           subjectDispatchUncertain: Self.dispatchUncertain(testStarted: testStarted, receipts: receipts, stepReceipts: steps, plan: plan))
        }
        do { try verifyPrepared() }
        catch {
            let release = await release()
            let steps = recovered.compactMap { try? JSONDecoder().decode(UIHostStepReceipt.self, from: $0) }
            throw Self.failedVerification(receipts: receipts, stepReceipts: steps, plan: plan, testStarted: testStarted, release: release)
        }
        return receipts
    }

    static func failedVerification(receipts: [AutomationSegmentReceipt], stepReceipts: [UIHostStepReceipt], plan: AutomationCase,
                                   testStarted: Bool, release: AutomationReleaseProof) -> AutomationXCUITestFailure {
        .init(receipts: receipts, reason: .infrastructureFailed,
              resourcesReleased: release.commandsDrained && release.runnerTerminated && release.privatePayloadCleaned,
              subjectDispatchUncertain: dispatchUncertain(testStarted: testStarted, receipts: receipts, stepReceipts: stepReceipts, plan: plan))
    }

    static func failureReason(error: Error?, receipts: [AutomationSegmentReceipt], stepReceipts: [UIHostStepReceipt], plan: AutomationCase) -> AttemptResult.Summary {
        if error is CancellationError { return .cancelled }
        if error as? AutomationRPCError == .timedOut { return .timedOut }
        if let last = receipts.last, !last.completed, plan.setup.contains(where: { $0.id == last.segmentID }) { return .invalidFixture }
        if receipts.contains(where: { receipt in
            guard let proof = receipt.terminalUIAssertionFailure,
                  let segment = (plan.setup + [plan.execution] + plan.observations + plan.cleanup).first(where: { $0.id == receipt.segmentID }),
                  (try? proof.validate(receipt: receipt, segment: segment, plan: plan)) != nil else { return false }
            return stepReceipts.contains(where: { $0.kind == .assert && !$0.completed && $0.error == "assertionFailed" &&
                $0.stepID == proof.stepID && $0.segmentID == receipt.segmentID && $0.runID == receipt.scope.runId &&
                $0.attemptID == receipt.scope.attemptId && $0.leaseGeneration == receipt.scope.leaseGeneration && $0.planDigest == proof.planDigest })
        }) { return .assertionFailed }
        if stepReceipts.contains(where: { !$0.completed && $0.error == "timedOut" }) { return .timedOut }
        return .infrastructureFailed
    }
    static func dispatchUncertain(testStarted: Bool, receipts: [AutomationSegmentReceipt], stepReceipts: [UIHostStepReceipt], plan: AutomationCase) -> Bool {
        guard testStarted else { return false }
        if receipts.contains(where: { $0.segmentID == plan.execution.id && $0.completed }) { return false }
        if !receipts.contains(where: { $0.segmentID == plan.execution.id }),
           stepReceipts.contains(where: { receipt in !receipt.completed && receipt.error != nil && plan.setup.contains(where: { $0.id == receipt.segmentID }) }) { return false }
        return true
    }

    public func release() async -> AutomationReleaseProof {
        revoked = true
        let drained = await command.stopOwned()
        if subjectStarted, drained, prepared.target.kind == .simulator {
            let terminated = await Task.detached { [self] in await terminateSimulator() }.value
            stopVerified = stopVerified && terminated
        }
        let runnerStopped = !testStarted || (prepared.target.kind == .simulator && drained && stopVerified)
        var cleaned = privatePayload == nil
        if let privatePayload, drained, runnerStopped {
            do {
                try privatePayload.clean(scope: privatePayload.recoveryReference.scope)
                try await didCleanPayload(privatePayload.recoveryReference)
                self.privatePayload = nil; payloadFile = nil; payloadDigest = nil; cleaned = true
            } catch { cleaned = false }
        }
        subjectStarted = false
        // A local xcodebuild exit cannot prove remote device or native Mac subject/controller absence.
        // Those platforms require their runtime release verifier before reporting released resources.
        return .init(commandsDrained: drained, runnerTerminated: runnerStopped && drained,
                     privatePayloadCleaned: cleaned)
    }

    private func terminateSimulator() async -> Bool {
        if let simulatorTerminationVerifier { return await simulatorTerminationVerifier() }
        return await AutomationSimulatorTermination.stop(
            bundleIDs: [prepared.app.bundleID, prepared.hostBundleID], diagnosticRoot: root,
            run: { [self] bundle, timeout in
                try await run(["simctl", "terminate", prepared.target.id, bundle], directory: root,
                              timeout: timeout, authorize: false)
            }, retainedLogs: { [self] in await command.retainedLogs() })
    }

    static func terminationSucceeded(exitStatus: Int32, output: String) -> Bool {
        if exitStatus == 0 { return true }
        guard exitStatus == 3, output.contains("NSPOSIXErrorDomain") else { return false }
        return output.contains("found nothing to terminate") || output.contains("not running") || output.contains("No such process")
    }

    static func freeze(_ value: Any, prepared: AutomationPreparedAppleHost, payload: Data) throws -> [String: Any] {
        let platform: AutomationAssociatedHostPlatform = prepared.target.kind == .nativeMac ? .macOS : prepared.target.kind == .physical ? .physicalIOS : .iosSimulator
        var frozen = try AutomationAppleHostFile.freeze(value, testRoot: URL(fileURLWithPath: prepared.xctestrunPath).deletingLastPathComponent(),
            expectedHost: URL(fileURLWithPath: prepared.hostBundlePath), expectedSubject: URL(fileURLWithPath: prepared.subjectProductPath),
            testTarget: prepared.testTarget, payload: payload, platform: platform)
        func environment(_ target: [String: Any]) -> [String: Any] {
            var target = target
            var fields = target["EnvironmentVariables"] as? [String: String] ?? [:]
            fields.removeValue(forKey: "INTENTS_AUTOMATION_HOST_PLAN_B64")
            fields["INTENTS_AUTOMATION_UI_PLAN_B64"] = payload.base64EncodedString()
            target["EnvironmentVariables"] = fields
            return target
        }
        if var configs = frozen["TestConfigurations"] as? [[String: Any]], let targets = configs[0]["TestTargets"] as? [[String: Any]] {
            configs[0]["TestTargets"] = targets.map(environment); frozen["TestConfigurations"] = configs
        } else if let target = frozen[prepared.testTarget] as? [String: Any] { frozen[prepared.testTarget] = environment(target) }
        return frozen
    }

    private func verifyPrepared() throws {
        guard try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.subjectProductPath), version: prepared.app.productDigestVersion ?? 1) == prepared.app.productDigest,
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.hostBundlePath), version: prepared.hostProductDigestVersion ?? 1) == prepared.hostProductDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }
    private func importAttachmentData(root: URL, scope: AutomationScope) async throws -> [Data] {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        guard files.count <= 1000 else { throw AutomationContractError.missingEvidence("Too many XCTest attachments") }
        var receipts: [Data] = []
        for file in files where file.lastPathComponent != "manifest.json" {
            let data = try AutomationReadOnlyFile.read(root: root, relativePath: file.lastPathComponent, maximumBytes: 16 * 1024 * 1024)
            _ = try await artifacts.store(data: data, name: "xcuitest-attachment-" + UUID().uuidString + "." + file.pathExtension, scope: scope)
            if file.pathExtension == "json", let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["stepIndex"] != nil, value["planDigest"] != nil { receipts.append(data) }
        }
        return receipts
    }
    private func run(_ arguments: [String], directory: URL, timeout: Duration, absoluteDeadline: ContinuousClock.Instant? = nil,
                     authorize: Bool = true, testInvocation: Bool = false) async throws -> AutomationOwnedCommand.Result {
        // Job control creates a dedicated group for xcrun and all its descendants. The owned shell's
        // termination trap stops that group before returning, including timeout and cancellation.
        let beforeStart: @Sendable () async throws -> Void
        if authorize {
            beforeStart = { [self] in
                try await willStart()
                try await verifyPayload()
            }
        } else { beforeStart = { @Sendable in } }
        let afterStart: @Sendable (AutomationProcessIdentity) async throws -> Void
        if authorize {
            afterStart = { [self] identity in
                if testInvocation { await markTestStarted() }
                try await didStart(identity)
            }
        } else { afterStart = { @Sendable _ in } }
        return try await command.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", Self.processGroupScript, "intents-xcuitest", "/usr/bin/xcrun"] + arguments,
            directory: directory, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path],
            timeout: timeout, absoluteDeadline: absoluteDeadline, willStart: beforeStart, didStart: afterStart)
    }
    func markTestStarted() { testStarted = true; subjectStarted = true }
    private func verifyPayload() throws {
        guard !revoked, let payloadFile, let payloadDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(payloadFile, maximumBytes: 4 * 1024 * 1024)) == payloadDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }
    static let processGroupScript = """
        set -m
        child=''
        stopping=''
        stop_group() {
          trap '' TERM INT HUP
          if [ -n "$child" ]; then
            kill -TERM -- "-$child" 2>/dev/null || true
            sleep 0.2
            kill -KILL -- "-$child" 2>/dev/null || true
          fi
        }
        trap 'stopping=1' TERM INT HUP
        "$@" &
        child=$!
        trap 'stop_group; exit 143' TERM INT HUP
        if [ -n "$stopping" ]; then stop_group; exit 143; fi
        wait "$child"
        result=$?
        stop_group
        exit "$result"
        """
}
#endif
