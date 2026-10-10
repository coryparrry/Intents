#if os(macOS)
import Foundation
import XCTest
import IntentsAutomationDateCodec
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    actor InputProbeCommands {
        let host: AutomationPreparedAppleHost
        let duplicate: Bool
        let tamperBeforeStart: Bool
        var calls: [String] = [], payload: Data?, testFile: URL?
        var suspended = false, continuation: CheckedContinuation<Void, Never>?
        init(host: AutomationPreparedAppleHost, duplicate: Bool = false, suspended: Bool = false, tamperBeforeStart: Bool = false) {
            self.host = host; self.duplicate = duplicate; self.suspended = suspended; self.tamperBeforeStart = tamperBeforeStart
        }
        func beforeStart(_ arguments: [String], root: URL) throws {
            if let index = arguments.firstIndex(of: "-xctestrun") {
                let file = URL(fileURLWithPath: arguments[index + 1]); testFile = file
                if tamperBeforeStart { try (Data(contentsOf: file) + Data([0])).write(to: file) }
            }
        }
        func run(_ arguments: [String], root: URL, timeout: Duration) async throws -> AutomationOwnedCommand.Result {
            calls.append(arguments[0])
            if arguments[0] == "xcodebuild" {
                guard arguments.contains("-only-testing:" + host.testTarget + "/InputAdapterProbeTests/testParameterRoundTrip"),
                      let index = arguments.firstIndex(of: "-xctestrun"),
                      let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])), format: nil) as? [String: Any],
                      let entry = plist[host.testTarget] as? [String: Any], let environment = entry["EnvironmentVariables"] as? [String: String],
                      environment["INTENTS_AUTOMATION_HOST_PLAN_B64"] == nil, let encoded = environment["INTENTS_AUTOMATION_INPUT_PROBE_B64"],
                      let decoded = Data(base64Encoded: encoded) else { throw AutomationContractError.conflictingOperation }
                payload = decoded
                if suspended { await withCheckedContinuation { continuation = $0 } }
            } else {
                guard let index = arguments.firstIndex(of: "--output-path"), let payload,
                      var fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AutomationContractError.conflictingOperation }
                fields["runner"] = ["pid": Int32.max, "startIdentity": "123:0", "executablePath": host.hostBundlePath + "/Contents/MacOS/" + host.testTarget + "-Runner"]
                fields["complete"] = true
                let output = URL(fileURLWithPath: arguments[index + 1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let data = try JSONSerialization.data(withJSONObject: fields)
                try data.write(to: output.appendingPathComponent("probe.json"))
                if duplicate { try data.write(to: output.appendingPathComponent("duplicate.json")) }
            }
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func stop() -> Bool { true }
        func resume() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while continuation == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard continuation != nil else { throw AutomationContractError.missingEvidence("Probe fixture did not suspend") }
        }
        nonisolated var adapter: AutomationInputAdapterProbeRunner.Commands {
            .init(run: { try await self.run($0, root: $1, timeout: $2) }, stop: { await self.stop() }, beforeStart: { try await self.beforeStart($0, root: $1) })
        }
    }
    actor FileInputProbeCommands {
        let host: AutomationPreparedAppleHost, tamper: Bool
        var fields: [String: Any]?
        init(host: AutomationPreparedAppleHost, tamper: Bool) { self.host = host; self.tamper = tamper }
        func run(_ arguments: [String], root: URL, timeout: Duration) throws -> AutomationOwnedCommand.Result {
            if let index = arguments.firstIndex(of: "-xctestrun") {
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])), format: nil) as? [String: Any])
                let target = try XCTUnwrap(plist[host.testTarget] as? [String: Any]), environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
                fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(environment["INTENTS_AUTOMATION_INPUT_PROBE_B64"])))) as? [String: Any])
            }
            if let index = arguments.firstIndex(of: "--output-path") {
                let output = URL(fileURLWithPath: arguments[index + 1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var receipt = try XCTUnwrap(fields)
                let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AutomationIntentFileCalibration.metadata()))
                receipt["parameters"] = [["name": "sample", "family": "intentFile", "samples": [["kind": "intentFile", "value": "intents-file-sample:0", "file": metadata]]]]
                receipt["runner"] = ["pid": Int32.max, "startIdentity": "100:0", "executablePath": host.hostBundlePath + "/Contents/MacOS/" + host.testTarget + "-Runner"]
                receipt["complete"] = true
                try JSONSerialization.data(withJSONObject: receipt).write(to: output.appendingPathComponent("receipt.json"))
                try (tamper ? Data("changed".utf8) : AutomationIntentFileCalibration.data).write(to: output.appendingPathComponent("file.bin"))
                let entries = [("receipt.json", "intents-input-adapter-probe"), ("file.bin", "intents-file-sample:0")].map { file, name in
                    ["exportedFileName": file, "suggestedHumanReadableName": name, "isAssociatedWithFailure": false,
                     "configurationName": "Debug", "deviceName": "fixture", "deviceId": "owned"] as [String: Any]
                }
                try JSONSerialization.data(withJSONObject: [["testIdentifier": "InputAdapterProbeTests/testParameterRoundTrip()", "attachments": entries]])
                    .write(to: output.appendingPathComponent("manifest.json"))
            }
            return .init(exitStatus: 0, stdout: AutomationIntentFileCalibration.data, stderr: Data(), logsTruncated: false)
        }
        nonisolated var adapter: AutomationInputAdapterProbeRunner.Commands {
            .init(run: { try await self.run($0, root: $1, timeout: $2) }, stop: { true }, beforeStart: { _, _ in })
        }
    }
    func testFileProbeOwnerPublishesOnlyReleasedOpaqueBinaryAndWithholdsNativeLog() async throws {
        try await checkFileProbeOwner(tamper: false)
    }
    func testFileProbeOwnerRejectsChangedBinaryAndStillCleansItsPayload() async throws {
        try await checkFileProbeOwner(tamper: true)
    }
    private func checkFileProbeOwner(tamper: Bool) async throws {
        let h = try await fixture(), commands = FileInputProbeCommands(host: h.host, tamper: tamper)
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        let plan = try inputProbe(h, family: "intentFile"), artifacts = try AutomationArtifactRegistry(root: h.root.appendingPathComponent("file-probe-artifacts"))
        let owner = try AutomationInputAdapterProbeRunner(plan: plan,
            approval: .init(runID: h.approval.runID, probeDigest: plan.digest, app: h.host.app, target: h.host.target),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), state: h.root.appendingPathComponent("file-probe-owner"),
            leases: h.leases, artifacts: artifacts, subject: Subject(app: h.host.app, target: h.host.target), release: h.release, commands: commands.adapter, validateTarget: { _ in })
        let report = try await owner.run(attemptID: "probe")
        XCTAssertTrue(report.resourcesReleased)
        if tamper { XCTAssertNil(report.observation); XCTAssertNil(report.artifact); XCTAssertNotNil(report.failure) }
        else {
            XCTAssertNil(report.failure); XCTAssertNotNil(report.artifact)
            guard case .artifact(let handle, let digest) = report.observation?.echoedSamples["sample"]?.first else { return XCTFail("Missing opaque probe result") }
            XCTAssertEqual(digest, AutomationIntentFileMetadata.digest(AutomationIntentFileCalibration.data))
            do { _ = try await artifacts.resolve(handle: handle, scope: report.scope); XCTFail("Probe binary exposed") } catch {}
        }
        let index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self, from: Data(contentsOf: h.root.appendingPathComponent("file-probe-artifacts/artifact-index.json")))
        XCTAssertEqual(index.values.filter { $0.fileMetadata != nil }.count, tamper ? 0 : 1)
        for artifact in index.values where artifact.nativeOnly == true {
            do { _ = try await artifacts.resolve(handle: artifact.handle, scope: report.scope); XCTFail("Native probe evidence exposed") } catch {}
        }
        let next = try await h.leases.acquire(runID: "next", target: h.host.target, control: .system)
        try await h.leases.release(next, commandsDrained: true, ownedRunnerTerminated: true)
    }
    private func inputProbe(_ h: Harness, family: String = "text") throws -> AutomationInputAdapterProbePlan {
        let catalog = ApplicationSurfaceCatalog(app: h.host.app, systemActions: [.init(id: "Probe", typeName: "Probe", title: "Probe",
            parameters: [.init(name: "sample", family: family, optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: h.root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: h.host.testTarget, targetID: h.host.testTarget, bundleID: h.host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64)), host: h.host, catalog: catalog, buildLogPath: "synthetic", buildLogTruncated: false)
        return try .init(prepared: prepared, actionID: "Probe", parameterNames: ["sample"])
    }
    private func probeOwner(_ h: Harness, commands: InputProbeCommands, release: (any AutomationDeviceReleaseVerifier)? = nil) async throws -> AutomationInputAdapterProbeRunner {
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        let plan = try inputProbe(h)
        return try .init(plan: plan, approval: .init(runID: h.approval.runID, probeDigest: plan.digest, app: h.host.app, target: h.host.target),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), state: h.root.appendingPathComponent("probe-owner"), leases: h.leases,
            artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("probe-artifacts")), subject: Subject(app: h.host.app, target: h.host.target),
            release: release ?? h.release, commands: commands.adapter, validateTarget: { _ in })
    }
    func testSeparateProbeOwnerReturnsOnlyReleasedReadbackAndReleasesItsLease() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host), owner = try await probeOwner(h, commands: commands)
        let report = try await owner.run(attemptID: "probe")
        XCTAssertTrue(report.resourcesReleased); XCTAssertNil(report.failure); XCTAssertNotNil(report.artifact)
        XCTAssertEqual(report.observation?.echoedSamples["sample"], [.text("Intents adapter probe")])
        XCTAssertNil(report.observation?.runtimeObservation)
        let calls = await commands.calls; XCTAssertEqual(calls, ["xcodebuild", "xcresulttool"])
        let captured = await commands.testFile, file = try XCTUnwrap(captured)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_INPUT_PROBE_B64"))
        let next = try await h.leases.acquire(runID: "next", target: h.host.target, control: .system)
        try await h.leases.release(next, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testSeparateProbeOwnerRejectsDuplicateReceiptWithoutBusinessObservation() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host, duplicate: true), owner = try await probeOwner(h, commands: commands)
        let report = try await owner.run(attemptID: "probe")
        XCTAssertTrue(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertNotNil(report.failure)
    }
    func testSeparateProbeOwnerWithholdsReadbackAndLeaseWhenReleaseIsDenied() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host), owner = try await probeOwner(h, commands: commands)
        await h.release.deny()
        let report = try await owner.run(attemptID: "probe")
        XCTAssertFalse(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertNotNil(report.failure)
        do { _ = try await h.leases.acquire(runID: "next", target: h.host.target, control: .system); XCTFail("Unreleased probe lease was reused") } catch {}
    }
    func testSeparateProbeOwnerQuarantinesUnprovedInspectorBeforeAnyLaunch() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host), owner = try await probeOwner(h, commands: commands)
        await h.release.failPreparation(.terminationUnverified)
        let report = try await owner.run(attemptID: "probe"), calls = await commands.calls
        XCTAssertFalse(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertTrue(calls.isEmpty)
    }
    func testSeparateProbeStopRevokesSuspendedCommandAndCannotExportOrReturnReadback() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host, suspended: true), owner = try await probeOwner(h, commands: commands)
        let task = Task { try await owner.run(attemptID: "probe") }
        try await commands.wait()
        let stopped = await owner.cancel(); XCTAssertTrue(stopped)
        await commands.resume()
        let report = try await task.value, calls = await commands.calls
        XCTAssertTrue(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertNotNil(report.failure)
        XCTAssertEqual(calls, ["xcodebuild"])
    }
    func testSeparateProbeApprovalCannotAuthorizeDifferentSamplePlan() async throws {
        let h = try await fixture(), plan = try inputProbe(h)
        XCTAssertThrowsError(try AutomationInputAdapterProbeRunner(plan: plan,
            approval: .init(runID: h.approval.runID, probeDigest: String(repeating: "f", count: 64), app: h.host.app, target: h.host.target),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), state: h.root.appendingPathComponent("denied-probe"), leases: h.leases,
            artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("denied-artifacts")), subject: Subject(app: h.host.app, target: h.host.target), release: h.release))
    }
    actor SuspendedProbeRelease: AutomationDeviceReleaseVerifier {
        var continuation: CheckedContinuation<Void, Never>?
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) {}
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
            await withCheckedContinuation { continuation = $0 }; return true
        }
        func wait() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while continuation == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard continuation != nil else { throw AutomationContractError.missingEvidence("Probe cleanup fixture did not suspend") }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
    func testStopOrTaskCancellationDuringProbeCleanupWithholdsReadbackAndArtifact() async throws {
        for taskCancellation in [false, true] {
            let h = try await fixture(), commands = InputProbeCommands(host: h.host), release = SuspendedProbeRelease()
            let owner = try await probeOwner(h, commands: commands, release: release)
            let task = Task { try await owner.run(attemptID: "probe") }
            try await release.wait()
            if taskCancellation { task.cancel() } else { _ = await owner.cancel() }
            await release.resume()
            let report = try await task.value
            XCTAssertTrue(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertNil(report.artifact); XCTAssertNotNil(report.failure)
        }
    }
    func testFrozenProbeTestFileTamperAtFinalCommandGatePreventsLaunch() async throws {
        let h = try await fixture(), commands = InputProbeCommands(host: h.host, tamperBeforeStart: true), owner = try await probeOwner(h, commands: commands)
        let report = try await owner.run(attemptID: "probe"), calls = await commands.calls
        XCTAssertFalse(report.resourcesReleased); XCTAssertNil(report.observation); XCTAssertNil(report.artifact); XCTAssertNotNil(report.failure); XCTAssertTrue(calls.isEmpty)
        let captured = await commands.testFile, file = try XCTUnwrap(captured)
        XCTAssertEqual(try Data(contentsOf: file).last, 0)
        do { _ = try await h.leases.acquire(runID: "next", target: h.host.target, control: .system); XCTFail("Unsanitized payload ownership must remain") } catch {}
    }
    func testFrozenHostPurposeRemovesOtherPayloadAndProbeCannotSelectIOSHost() async throws {
        let h = try await fixture(), payload = try inputProbe(h).payload(scope: h.scope)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: h.host.xctestrunPath)), format: nil) as? [String: Any])
        var entry = try XCTUnwrap(plist[h.host.testTarget] as? [String: Any])
        entry["EnvironmentVariables"] = ["INTENTS_AUTOMATION_HOST_PLAN_B64": "stale-business", "INTENTS_AUTOMATION_INPUT_PROBE_B64": "stale-probe"]
        plist[h.host.testTarget] = entry
        func freeze(_ purpose: AutomationAppleHostFile.Purpose, platform: AutomationAssociatedHostPlatform = .macOS) throws -> [String: String] {
            let frozen = try AutomationAppleHostFile.freeze(plist, testRoot: URL(fileURLWithPath: h.host.xctestrunPath).deletingLastPathComponent(),
                expectedHost: URL(fileURLWithPath: h.host.hostBundlePath), expectedSubject: URL(fileURLWithPath: h.host.subjectProductPath),
                testTarget: h.host.testTarget, payload: payload, platform: platform, purpose: purpose)
            return try XCTUnwrap((frozen[h.host.testTarget] as? [String: Any])?["EnvironmentVariables"] as? [String: String])
        }
        XCTAssertEqual(try freeze(.inputAdapterProbe), ["INTENTS_AUTOMATION_INPUT_PROBE_B64": payload.base64EncodedString()])
        XCTAssertEqual(try freeze(.segment), ["INTENTS_AUTOMATION_HOST_PLAN_B64": payload.base64EncodedString()])
        XCTAssertThrowsError(try freeze(.inputAdapterProbe, platform: .iosSimulator))
    }
}
#endif
