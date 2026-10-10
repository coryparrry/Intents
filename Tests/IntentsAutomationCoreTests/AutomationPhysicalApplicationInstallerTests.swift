#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalApplicationInstallerTests: XCTestCase, @unchecked Sendable {
    typealias Installer = AutomationPhysicalApplicationInstaller
    private struct Harness {
        let root: URL; let selected: AutomationInstalledUIApplication; let approval: RunApproval
        let leases: AutomationDeviceLeaseManager; let lease: AutomationDeviceLeaseManager.Lease
        let scope: AutomationScope; let journal: AutomationJournal
    }
    private func harness() async throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("physical-install-test-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Developer"), withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.Install",
            "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"]], format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try AutomationPhysicalExecutableTests.binary().write(to: bundle.appendingPathComponent("Fixture"))
        try Data("selected".utf8).write(to: bundle.appendingPathComponent("resource"))
        let nested = bundle.appendingPathComponent("Frameworks/Helper.framework/Helper")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nested executable".utf8).write(to: nested)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
        var target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        target.toolchain = "test-toolchain"; target.osBuild = "test-build"; target.transport = "usb"
        let selected = try AutomationInstalledUIApplication(bundleURL: bundle, target: target)
        let approval = RunApproval(runID: "run", app: selected.app, target: target, environmentID: "test", effects: [.navigate], maximumActions: 10, disposable: true)
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let lease = try await leases.acquire(runID: "run", target: target, control: .system)
        return Harness(root: root, selected: selected, approval: approval, leases: leases, lease: lease,
            scope: .init(runID: "run", attemptID: "attempt", segmentID: "prepare.install", leaseGeneration: lease.generation),
            journal: try AutomationJournal(url: root.appendingPathComponent("journal.json")))
    }
    private actor Commands {
        enum Mode { case normal, nonzero, truncated, missingBundle, changedDevice, changedPayload, staleOutput, failedDrain, runnerRecord, invalidRunner }
        let mode: Mode
        var calls: [Installer.Invocation] = []
        var stops = 0
        var started: AsyncStream<Void>.Continuation?
        var gate: CheckedContinuation<Void, Never>?
        init(_ mode: Mode = .normal, started: AsyncStream<Void>.Continuation? = nil) { self.mode = mode; self.started = started }
        func run(_ invocation: Installer.Invocation, willStart: @Sendable () async throws -> Void,
                 didStart: @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> AutomationOwnedCommand.Result {
            try await willStart()
            calls.append(invocation)
            if let started { self.started = nil; await withCheckedContinuation { gate = $0; started.yield(()) } }
            try Task.checkCancellation()
            if calls.count == 1, mode == .runnerRecord { try await didStart(AutomationProcessIdentity.current()) }
            if calls.count == 1, mode == .invalidRunner { try await didStart(.init(pid: 0, startIdentity: "invalid")) }
            let args = invocation.arguments
            if args[2] == "install" {
                if mode == .changedPayload { try Data("mutated".utf8).write(to: URL(fileURLWithPath: args[6]).appendingPathComponent("resource")) }
                return .init(exitStatus: mode == .nonzero ? 1 : 0, stdout: Data("install output".utf8), stderr: Data("diagnostic".utf8), logsTruncated: mode == .truncated)
            }
            let outputIndex = try XCTUnwrap(args.firstIndex(of: "--json-output"))
            let output = URL(fileURLWithPath: args[outputIndex + 1])
            var declared = args
            if mode == .staleOutput { declared[outputIndex + 1] += ".old" }
            let after = calls.count > 1
            let installed = after && mode != .missingBundle
            let identifier = after && mode == .changedDevice ? "AD1EA67C-E436-4D33-B095-B59400275D35" : "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"
            let result: [String: Any] = ["deviceIdentifier": identifier,
                "defaultAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true,
                "apps": installed ? [["bundleIdentifier": "example.Install", "url": "file:///private/var/containers/Bundle/Application/Example/Fixture.app"]] : []]
            try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "jsonVersion": 5,
                "commandType": "devicectl.device.info.apps", "arguments": declared], "result": result]).write(to: output, options: .withoutOverwriting)
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func stop() -> Bool { stops += 1; return mode != .failedDrain }
        func logs() -> AutomationOwnedCommand.Result { .init(exitStatus: -1, stdout: Data("retained".utf8), stderr: Data(), logsTruncated: false) }
        func snapshot() -> ([Installer.Invocation], Int) { (calls, stops) }
        func resume() { gate?.resume(); gate = nil }
    }
    private func installer(_ h: Harness, commands: Commands) throws -> Installer {
        try Installer(workspace: h.root, developerDirectory: h.root.appendingPathComponent("Developer"), commands: .init(
            run: { invocation, willStart, didStart in try await commands.run(invocation, willStart: willStart, didStart: didStart) },
            stop: { await commands.stop() }, logs: { await commands.logs() }))
    }
    private func install(_ installer: Installer, _ h: Harness, allow: Bool = true) async throws -> AutomationPhysicalInstallationReceipt {
        try await installer.install(selected: h.selected, approval: h.approval, lease: h.lease, scope: h.scope,
            leases: h.leases, journal: h.journal, allowInstall: allow)
    }
    func testOwnedInstallStagesExactBytesAndBindsReceiptToRealCommandScope() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        let receipt = try await install(installer, h)
        let (calls, stops) = await commands.snapshot()
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(stops, 1)
        XCTAssertEqual(calls[1].arguments, ["devicectl", "device", "install", "app", "--device", h.selected.target.id, receipt.stagedBundlePath, "--timeout", "60", "--quiet"])
        XCTAssertEqual(calls[1].environment["DEVELOPER_DIR"], try AutomationPath.canonical(h.root.appendingPathComponent("Developer")).path)
        XCTAssertNotEqual(receipt.stagedBundlePath, h.selected.bundleURL.path)
        XCTAssertEqual(receipt.scope, h.scope); XCTAssertEqual(receipt.app, h.selected.app); XCTAssertEqual(receipt.target, h.selected.target)
        XCTAssertFalse(receipt.installedBytesVerified); XCTAssertEqual(receipt.evidenceScope, "ownedInstallCommandAndBundlePresence")
        XCTAssertEqual(receipt.stdoutSHA256, AutomationArtifactRegistry.digest(Data("install output".utf8)))
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: receipt.stagedBundlePath), version: receipt.app.productDigestVersion), receipt.app.productDigest)
        let mode = try FileManager.default.attributesOfItem(atPath: receipt.stagedBundlePath + "/Frameworks/Helper.framework/Helper")[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        let encoded = try JSONEncoder().encode(receipt)
        XCTAssertEqual(try JSONDecoder().decode(AutomationPhysicalInstallationReceipt.self, from: encoded), receipt)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["installedBytesVerified"] as? Bool, false)
        XCTAssertEqual(json["evidenceScope"] as? String, receipt.evidenceScope)
        json["installedBytesVerified"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationPhysicalInstallationReceipt.self, from: JSONSerialization.data(withJSONObject: json)))
        let unresolved = try await h.journal.unresolvedEntries(); XCTAssertTrue(unresolved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: receipt.stagedBundlePath).deletingLastPathComponent().appendingPathComponent("receipt.json").path))
    }
    func testInstallPermissionIsRequiredBeforeStagingOrAnyCommand() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        do { _ = try await install(installer, h, allow: false); XCTFail("Unapproved install") } catch {}
        let (calls, _) = await commands.snapshot(); XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: h.root.path).contains { $0.hasPrefix("physical-install-") })
    }
    func testChangedSourceIsRejectedBeforeInventoryOrInstall() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        try Data("changed".utf8).write(to: h.selected.bundleURL.appendingPathComponent("resource"))
        do { _ = try await install(installer, h); XCTFail("Changed source") } catch {}
        let (calls, _) = await commands.snapshot(); XCTAssertTrue(calls.isEmpty)
    }
    func testNonzeroAndTruncatedInstallerResultsRemainUnresolvedWithoutPostInventory() async throws {
        for mode in [Commands.Mode.nonzero, .truncated] {
            let h = try await harness(), commands = Commands(mode), installer = try installer(h, commands: commands)
            do { _ = try await install(installer, h); XCTFail("Bad install result") } catch {}
            let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.count, 2)
            let unresolved = try await h.journal.unresolvedEntries(); XCTAssertEqual(unresolved.count, 1)
            let state = calls[1].directory
            XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("install.stderr")), Data("diagnostic".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("receipt.json").path))
        }
    }
    func testMissingAppChangedDeviceAndChangedStagedBytesDoNotMintReceipt() async throws {
        for mode in [Commands.Mode.missingBundle, .changedDevice, .changedPayload] {
            let h = try await harness(), commands = Commands(mode), installer = try installer(h, commands: commands)
            do { _ = try await install(installer, h); XCTFail("Unbound install accepted") } catch {}
            let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.count, 3)
            let unresolved = try await h.journal.unresolvedEntries(); XCTAssertEqual(unresolved.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls[1].directory.appendingPathComponent("receipt.json").path))
        }
    }
    func testStaleInventoryCannotDispatchInstall() async throws {
        let h = try await harness(), commands = Commands(.staleOutput), installer = try installer(h, commands: commands)
        do { _ = try await install(installer, h); XCTFail("Stale inventory") } catch {}
        let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.count, 1)
        let unresolved = try await h.journal.unresolvedEntries(); XCTAssertTrue(unresolved.isEmpty)
    }
    func testFailedDrainLatchesInstallerAndCannotDispatchAgain() async throws {
        let h = try await harness(), commands = Commands(.failedDrain), installer = try installer(h, commands: commands)
        do { _ = try await install(installer, h); XCTFail("Undrained installation") } catch {}
        do { _ = try await install(installer, h); XCTFail("Failed drain reused") } catch {}
        let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.count, 3)
        let drained = await installer.drain(); XCTAssertFalse(drained)
    }
    func testSameAttemptCannotInstallAgainAfterAcknowledgedDispatch() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        _ = try await install(installer, h)
        do { _ = try await install(installer, h); XCTFail("Repeated mutation") } catch {}
        let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.filter { $0.arguments[2] == "install" }.count, 1)
    }
    func testRevokedLeaseCannotStageOrRun() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        do { _ = try await install(installer, h); XCTFail("Revoked lease") } catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let (calls, _) = await commands.snapshot(); XCTAssertTrue(calls.isEmpty)
    }
    func testConcurrentInstallAndDrainCannotStopTheActiveCommand() async throws {
        let h = try await harness(), stream = AsyncStream<Void>.makeStream(), commands = Commands(started: stream.continuation)
        let installer = try installer(h, commands: commands)
        let active = Task { try await self.install(installer, h) }
        var events = stream.stream.makeAsyncIterator(); _ = await events.next()
        do { _ = try await install(installer, h); XCTFail("Concurrent install") } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        let drained = await installer.drain(); XCTAssertFalse(drained)
        let (calls, stops) = await commands.snapshot(); XCTAssertEqual(calls.count, 1); XCTAssertEqual(stops, 0)
        await commands.resume(); _ = try await active.value
    }
    func testForeignApprovalCannotUseTheOwnedLease() async throws {
        let h = try await harness(), commands = Commands(), installer = try installer(h, commands: commands)
        var foreign = h.approval; foreign.target.osBuild = "another-build"
        do {
            _ = try await installer.install(selected: h.selected, approval: foreign, lease: h.lease, scope: h.scope, leases: h.leases, journal: h.journal, allowInstall: true)
            XCTFail("Foreign target approval")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        let (calls, _) = await commands.snapshot(); XCTAssertTrue(calls.isEmpty)
    }
    func testStartedRunnerIsRegisteredUnderTheExactLeaseAndScope() async throws {
        let h = try await harness(), commands = Commands(.runnerRecord), installer = try installer(h, commands: commands)
        _ = try await install(installer, h)
        let record = try await h.leases.currentRecord(h.lease)
        XCTAssertEqual(record.runners.count, 1); XCTAssertEqual(record.runners[0].scope, h.scope)
        XCTAssertEqual(record.runners[0].process, try AutomationProcessIdentity.current())
        XCTAssertEqual(record.runners[0].role, .nativeCommand)
    }
    func testRejectedRunnerRegistrationStopsBeforeInstallAndRetainsFailure() async throws {
        let h = try await harness(), commands = Commands(.invalidRunner), installer = try installer(h, commands: commands)
        do { _ = try await install(installer, h); XCTFail("Invalid runner") } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        let (calls, stops) = await commands.snapshot(); XCTAssertEqual(calls.count, 1); XCTAssertEqual(stops, 1)
        let record = try await h.leases.currentRecord(h.lease); XCTAssertTrue(record.runners.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: calls[0].directory.appendingPathComponent("failure.outcome.json").path))
    }
    func testCancellationDrainsWithoutInstallingOrReleasingTheCallersLease() async throws {
        let h = try await harness(), stream = AsyncStream<Void>.makeStream(), commands = Commands(started: stream.continuation)
        let installer = try installer(h, commands: commands), active = Task { try await self.install(installer, h) }
        var events = stream.stream.makeAsyncIterator(); _ = await events.next()
        active.cancel(); await commands.resume()
        do { _ = try await active.value; XCTFail("Cancelled install") } catch { XCTAssertTrue(error is CancellationError) }
        let (calls, stops) = await commands.snapshot(); XCTAssertEqual(calls.count, 1); XCTAssertEqual(stops, 1)
        let current = await h.leases.isCurrent(h.lease); XCTAssertTrue(current)
        let drained = await installer.drain(); XCTAssertTrue(drained)
    }
}
#endif
