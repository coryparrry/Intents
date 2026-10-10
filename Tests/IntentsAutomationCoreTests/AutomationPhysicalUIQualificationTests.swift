#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalUIQualificationTests: XCTestCase, @unchecked Sendable {
    private static let device = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"
    private static let bundleURL = "file:///private/var/containers/Bundle/Application/Example/Fixture.app"
    private struct Harness {
        let root: URL; let payload: AutomationInstalledUIApplication; let runner: AutomationApplicationRunner
        let trace: Trace; let runtime: AutomationUIRuntime
        let installStarted: AsyncStream<Void>
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func expire() { lock.withLock { instant = instant.advanced(by: .seconds(100)) } }
    }
    private actor Trace {
        var calls: [String] = []
        var releaseCounts: [String: Int] = [:]
        let failRelease: Bool, wrongSubjectDevice: Bool, failInstallDrain: Bool, wrongReleaseDevice: Bool, cancelDuringInstall: Bool
        let afterRelease: @Sendable () -> Void
        let installStarted: AsyncStream<Void>.Continuation
        var installGate: CheckedContinuation<Void, Never>?
        init(failRelease: Bool, wrongSubjectDevice: Bool, failInstallDrain: Bool, wrongReleaseDevice: Bool,
             afterRelease: @escaping @Sendable () -> Void, cancelDuringInstall: Bool, installStarted: AsyncStream<Void>.Continuation) {
            self.failRelease = failRelease; self.wrongSubjectDevice = wrongSubjectDevice; self.failInstallDrain = failInstallDrain
            self.wrongReleaseDevice = wrongReleaseDevice; self.afterRelease = afterRelease
            self.cancelDuringInstall = cancelDuringInstall; self.installStarted = installStarted
        }
        func record(_ value: String) { calls.append(value) }
        func snapshot() -> [String] { calls }
        func releaseInstall() { installGate?.resume(); installGate = nil }
        func inventory(_ invocation: AutomationPhysicalRunnerVerifier.InventoryInvocation) async throws -> AutomationOwnedCommand.Result {
            let args = invocation.arguments
            guard args[0] == "devicectl", args.contains("--device"), args.contains("00008140-000E4D803C0B001C") else { throw AutomationContractError.invalidIdentity }
            if args[2] == "install" {
                calls.append("owned-install")
                if cancelDuringInstall { await withCheckedContinuation { installGate = $0; installStarted.yield(()) }; try Task.checkCancellation() }
                return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
            }
            let index = try XCTUnwrap(args.firstIndex(of: "--json-output")), output = URL(fileURLWithPath: args[index + 1])
            let subject = output.lastPathComponent.hasPrefix("physical-subject-")
            calls.append(subject ? "subject-presence" : "install-inventory")
            try AutomationPhysicalUIQualificationTests.apps(arguments: args,
                device: subject && wrongSubjectDevice ? "AD1EA67C-E436-4D33-B095-B59400275D35" : AutomationPhysicalUIQualificationTests.device).write(to: output, options: .withoutOverwriting)
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func installDrain() -> Bool { calls.append("install-drain"); return !failInstallDrain }
        func release(_ target: TargetIdentity, controllers: [AutomationPhysicalRunnerVerifier.Controller], state: URL) -> AutomationPhysicalRunnerVerifier.BatchObservation {
            if Task.isCancelled { calls.append("FORBIDDEN-cancelled-cleanup") }
            calls.append("controller-inventory"); releaseCounts[state.path, default: 0] += 1
            afterRelease()
            let absent = !(failRelease && state.lastPathComponent == "ui-attempt" && releaseCounts[state.path, default: 0] > 1)
            return .init(targetID: target.id, deviceIdentifier: wrongReleaseDevice ? "AD1EA67C-E436-4D33-B095-B59400275D35" : AutomationPhysicalUIQualificationTests.device,
                controllers: controllers.map { .init(controller: $0, absent: absent) },
                appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
        }
    }
    private actor Driver: AutomationRouteDriver {
        let context: AutomationPhysicalUIQualification.DriverContext
        let subject: AutomationPhysicalInstalledSubjectVerifier
        let releaseVerifier: AutomationPhysicalDeviceReleaseVerifier
        let trace: Trace
        init(context: AutomationPhysicalUIQualification.DriverContext, subject: AutomationPhysicalInstalledSubjectVerifier,
             release: AutomationPhysicalDeviceReleaseVerifier, trace: Trace) {
            self.context = context; self.subject = subject; releaseVerifier = release; self.trace = trace
        }
        func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
            XCTAssertEqual(lease.target, plan.target); XCTAssertEqual(lease.control, .ui)
            try await subject.verify(app: plan.app, target: plan.target)
            try await releaseVerifier.prepare(target: plan.target, controllerBundleIDs: AutomationPhysicalUIQualification.controllers.map(\.bundleID))
            await trace.record("ui-acquire")
        }
        func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
            await trace.record("ui-execute")
            return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .ui,
                dispatched: true, completed: true, environmentID: plan.environmentID)
        }
        func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
            let drained = await subject.drain()
            let released = await releaseVerifier.verifyReleased(target: context.approval.target,
                controllerBundleIDs: AutomationPhysicalUIQualification.controllers.map(\.bundleID))
            return .init(commandsDrained: drained, runnerTerminated: released)
        }
    }
    private static func apps(arguments: [String], device: String = device) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "jsonVersion": 5,
            "commandType": "devicectl.device.info.apps", "arguments": arguments], "result": ["deviceIdentifier": device,
            "defaultAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true,
            "apps": [["bundleIdentifier": "example.PhysicalUI", "url": bundleURL]]]])
    }
    private func harness(failRelease: Bool = false, wrongSubjectDevice: Bool = false, failInstallDrain: Bool = false, enabled: Bool = true,
                         wrongReleaseDevice: Bool = false, afterRelease: @escaping @Sendable () -> Void = {}, cancelDuringInstall: Bool = false) throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("physical-compose-" + UUID().uuidString)
        let developer = root.appendingPathComponent("Developer"), bundle = root.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.PhysicalUI",
            "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"]], format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try AutomationPhysicalExecutableTests.binary().write(to: bundle.appendingPathComponent("Fixture"))
        var target = TargetIdentity(id: "00008140-000E4D803C0B001C", kind: .physical); target.toolchain = "qualification-toolchain"
        let payload = try AutomationInstalledUIApplication(bundleURL: bundle, target: target)
        let (installStarted, started) = AsyncStream<Void>.makeStream()
        let trace = Trace(failRelease: failRelease, wrongSubjectDevice: wrongSubjectDevice, failInstallDrain: failInstallDrain,
            wrongReleaseDevice: wrongReleaseDevice, afterRelease: afterRelease, cancelDuringInstall: cancelDuringInstall, installStarted: started)
        let dependencies = AutomationPhysicalUIQualification.Dependencies(runtimeDigest: { _, _ in String(repeating: "c", count: 64) },
            installer: { state, dev in try .init(workspace: state, developerDirectory: dev, commands: .init(run: { invocation, willStart, _ in
                try await willStart(); return try await trace.inventory(invocation)
            }, stop: { await trace.installDrain() }, logs: { .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false) })) },
            subject: { selected, state, dev in try .init(selected: selected, workspace: state, developerDirectory: dev,
                commands: .init(run: { invocation, _ in try await trace.inventory(invocation) }, stop: { true })) },
            release: { state, _ in try .init(controllers: AutomationPhysicalUIQualification.controllers,
                inspect: { target, controllers in await trace.release(target, controllers: controllers, state: state) }, drain: { true }) },
            driver: { context, subject, release in Driver(context: context, subject: subject, release: release, trace: trace) })
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("Support"), developerDirectory: developer,
            simulatorInventory: { _, _ in await trace.record("FORBIDDEN-simulator"); throw AutomationContractError.invalidIdentity },
            physicalQualification: enabled ? dependencies : nil)
        return .init(root: root, payload: payload, runner: runner, trace: trace, runtime: .init(bundleURL: root, expectedTeamID: "synthetic"), installStarted: installStarted)
    }
    private func installApproval(_ h: Harness) -> RunApproval { .init(runID: "run", app: h.payload.app, target: h.payload.target,
        environmentID: "test", effects: [.observe, .navigate], maximumActions: 10, disposable: true) }
    private func selected(_ h: Harness) throws -> AutomationPhysicalInstalledUIApplication {
        let args = ["devicectl", "device", "info", "apps", "--device", h.payload.target.id, "--include-all-apps",
            "--json-output", "/private/tmp/discovery.json", "--timeout", "10", "--quiet"]
        return try .init(bundleID: h.payload.app.bundleID, target: h.payload.target, inventory: .parse(Self.apps(arguments: args), targetID: h.payload.target.id))
    }
    private func run(_ h: Harness, selected: AutomationPhysicalInstalledUIApplication, attempt: String = "ui-attempt") async throws -> AutomationAttemptReport {
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.label, "Ready"))])
        let plan = AutomationCase(id: "physical-ui", app: selected.app, target: selected.target, environmentID: "test", execution: segment)
        let approval = RunApproval(runID: "run", app: selected.app, target: selected.target, environmentID: "test", effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        return try await h.runner.run(subject: .installedPhysicalUI(selected), plan: plan, approval: approval, capabilities: .init(),
            attemptID: attempt, allowBootAndInstall: false, uiRuntime: h.runtime)
    }
    func testOwnedInstallationThenWeakUIUsesSameDeviceAndNeverSimulatorOrAppleHost() async throws {
        let h = try harness()
        let prepared = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: true)
        XCTAssertEqual(prepared.installation.app, h.payload.app); XCTAssertFalse(prepared.installation.installedBytesVerified)
        XCTAssertNil(prepared.subject.app.productDigest); XCTAssertEqual(prepared.subject.deviceIdentifier, prepared.installation.deviceIdentifier)
        let report = try await run(h, selected: prepared.subject)
        XCTAssertTrue(report.resourcesReleased); XCTAssertEqual(report.result.summary, .executedUnassessed)
        XCTAssertEqual(report.receipts.map(\.route), [.ui]); XCTAssertNil(report.receipts.first?.app.productDigest)
        let trace = await h.trace.snapshot(); XCTAssertEqual(trace.filter { $0 == "owned-install" }.count, 1)
        XCTAssertTrue(trace.contains("subject-presence")); XCTAssertFalse(trace.contains("FORBIDDEN-simulator"))
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
    }
    func testAlreadyInstalledWeakSubjectNeverRequestsLocalInstallation() async throws {
        let h = try harness(), report = try await run(h, selected: selected(h))
        XCTAssertTrue(report.resourcesReleased); XCTAssertEqual(report.result.summary, .executedUnassessed)
        let trace = await h.trace.snapshot(); XCTAssertFalse(trace.contains("owned-install")); XCTAssertFalse(trace.contains("FORBIDDEN-simulator"))
    }
    func testFailedPhysicalReleaseRetainsUnresolvedReportAndLease() async throws {
        let h = try harness(failRelease: true), report = try await run(h, selected: selected(h))
        XCTAssertFalse(report.resourcesReleased); XCTAssertEqual(report.result.summary, .unresolved)
        let saved = try JSONDecoder().decode(AutomationAttemptReport.self, from: Data(contentsOf: h.root.appendingPathComponent("Support/ui-attempt/report.json")))
        XCTAssertEqual(saved, report)
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertFalse(records.isEmpty)
    }
    func testChangedDevicePreventsUISubjectDispatch() async throws {
        let h = try harness(wrongSubjectDevice: true), report = try await run(h, selected: selected(h))
        XCTAssertFalse(report.result.subjectDispatched)
        let trace = await h.trace.snapshot(); XCTAssertFalse(trace.contains("ui-execute"))
    }
    func testFailedInstallDrainRetainsPreparationLeaseAndFailureRecord() async throws {
        let h = try harness(failInstallDrain: true)
        do { _ = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: true); XCTFail("Unproved install") } catch {}
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/physical-preparation-install-attempt/failure.json").path))
    }
    func testCustomerFenceAndUnapprovedPreparationPrecedeInventoryAndAttempt() async throws {
        for enabled in [false, true] {
            let h = try harness(enabled: enabled)
            do { _ = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: false); XCTFail("Unapproved") } catch {}
            if !enabled { do { _ = try await run(h, selected: selected(h)); XCTFail("Unqualified route") } catch {} }
            let trace = await h.trace.snapshot(); XCTAssertTrue(trace.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/ui-attempt").path))
        }
    }
    func testExhaustedBudgetDoesNotCreateOwnershipOrAttempt() async throws {
        let h = try harness(); var limits = AutomationCampaignLimits(); limits.setupOperations = 0
        let budget = try AutomationCampaignBudget(limits: limits)
        do { _ = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: true, campaignBudget: budget); XCTFail("Exhausted") } catch {}
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
        let calls = await h.trace.snapshot(); XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/physical-preparation-install-attempt").path))
    }
    func testDeadlineExpiryDuringControllerInventoryPreventsInstallationDispatch() async throws {
        let clock = Clock(), h = try harness(afterRelease: { clock.expire() }); var limits = AutomationCampaignLimits(); limits.wallClockSeconds = 5
        let budget = try AutomationCampaignBudget(limits: limits, now: { clock.now() })
        do { _ = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: true, campaignBudget: budget); XCTFail("Expired") } catch {}
        let calls = await h.trace.snapshot(); XCTAssertFalse(calls.contains("owned-install")); XCTAssertFalse(calls.contains("install-inventory"))
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
    }
    func testForeignReleaseDeviceCannotAuthorizeInstallationOrUI() async throws {
        let h = try harness(wrongReleaseDevice: true)
        do { _ = try await h.runner.preparePhysicalUI(selected: h.payload, approval: installApproval(h), attemptID: "install-attempt", allowInstall: true); XCTFail("Foreign device") } catch {}
        let before = await h.trace.snapshot(); XCTAssertFalse(before.contains("owned-install"))
        let report = try await run(h, selected: selected(h))
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.resourcesReleased)
        let calls = await h.trace.snapshot(); XCTAssertFalse(calls.contains("ui-execute"))
    }
    func testCancellationAfterInstallDispatchCollectsReleaseOutsideCancelledTask() async throws {
        let h = try harness(cancelDuringInstall: true), approval = installApproval(h)
        let task = Task { try await h.runner.preparePhysicalUI(selected: h.payload, approval: approval, attemptID: "install-attempt", allowInstall: true) }
        var iterator = h.installStarted.makeAsyncIterator(); _ = await iterator.next()
        task.cancel(); await h.trace.releaseInstall()
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await h.trace.snapshot(); XCTAssertFalse(calls.contains("FORBIDDEN-cancelled-cleanup")); XCTAssertEqual(calls.filter { $0 == "owned-install" }.count, 1)
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
    }
}
#endif
