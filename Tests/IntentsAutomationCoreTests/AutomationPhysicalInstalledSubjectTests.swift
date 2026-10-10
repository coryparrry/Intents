#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalInstalledSubjectTests: XCTestCase, @unchecked Sendable {
    private let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
    private static let device = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"
    private static let bundleURL = "file:///private/var/containers/Bundle/Application/Example/Fixture.app"
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("physical-presence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private static func data(arguments: [String], device: String = device, bundleURL: String = bundleURL, present: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "jsonVersion": 5,
            "commandType": "devicectl.device.info.apps", "arguments": arguments], "result": ["deviceIdentifier": device,
            "defaultAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true,
            "apps": present ? [["bundleIdentifier": "example.App", "url": bundleURL]] : []]])
    }
    private func selected() throws -> AutomationPhysicalInstalledUIApplication {
        let args = ["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps",
            "--json-output", "/private/tmp/discovery.json", "--timeout", "10", "--quiet"]
        return try .init(bundleID: "example.App", target: target, inventory: .parse(Self.data(arguments: args), targetID: target.id))
    }
    private actor Commands {
        enum Mode { case normal, missing, wrongDevice, wrongURL, staleOutput, nonzero, truncated, failedDrain, failedRunner }
        let mode: Mode
        var calls: [AutomationPhysicalRunnerVerifier.InventoryInvocation] = []
        var stops = 0
        init(_ mode: Mode = .normal) { self.mode = mode }
        func run(_ invocation: AutomationPhysicalRunnerVerifier.InventoryInvocation,
                 didStart: @Sendable (AutomationProcessIdentity) async throws -> Void) async throws -> AutomationOwnedCommand.Result {
            calls.append(invocation)
            if mode == .failedRunner { try await didStart(.init(pid: 0, startIdentity: "invalid")) }
            let index = try XCTUnwrap(invocation.arguments.firstIndex(of: "--json-output"))
            let output = URL(fileURLWithPath: invocation.arguments[index + 1]); var declared = invocation.arguments
            if mode == .staleOutput { declared[index + 1] += ".stale" }
            try AutomationPhysicalInstalledSubjectTests.data(arguments: declared,
                device: mode == .wrongDevice ? "AD1EA67C-E436-4D33-B095-B59400275D35" : AutomationPhysicalInstalledSubjectTests.device,
                bundleURL: mode == .wrongURL ? "file:///private/var/Other/Fixture.app" : AutomationPhysicalInstalledSubjectTests.bundleURL,
                present: mode != .missing).write(to: output, options: .withoutOverwriting)
            return .init(exitStatus: mode == .nonzero ? 1 : 0, stdout: Data(), stderr: Data(), logsTruncated: mode == .truncated)
        }
        func stop() -> Bool { stops += 1; return mode != .failedDrain }
        func snapshot() -> ([AutomationPhysicalRunnerVerifier.InventoryInvocation], Int) { (calls, stops) }
    }
    private func verifier(_ selected: AutomationPhysicalInstalledUIApplication, root: URL, commands: Commands,
                          didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) throws -> AutomationPhysicalInstalledSubjectVerifier {
        try .init(selected: selected, workspace: root, developerDirectory: root.appendingPathComponent("Developer"),
            commands: .init(run: { invocation, start in try await commands.run(invocation, didStart: start) }, stop: { await commands.stop() }), didStart: didStart)
    }
    func testWeakSelectionRetainsActualDeviceScopeWithoutInventingBuildBytes() throws {
        let selected = try selected()
        XCTAssertNil(selected.app.productDigest); XCTAssertNil(selected.app.canonicalBundlePath)
        XCTAssertEqual(selected.app.provenanceStrength, "installedIdentity"); XCTAssertEqual(selected.target, target)
        XCTAssertEqual(selected.deviceIdentifier, Self.device)
        let args = ["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps",
            "--json-output", "/private/tmp/discovery.json", "--timeout", "10", "--quiet"]
        let inventory = try AutomationPhysicalAppInventory.parse(Self.data(arguments: args), targetID: target.id)
        XCTAssertThrowsError(try AutomationPhysicalInstalledUIApplication(bundleID: "example.App", target: .init(id: "00008140-0000000000000000", kind: .physical), inventory: inventory))
        XCTAssertThrowsError(try AutomationPhysicalInstalledUIApplication(bundleID: "example.Other", target: target, inventory: inventory))
    }
    func testLivePresenceUsesExactToolchainFreshOutputAndExplicitWeakEvidence() async throws {
        let root = try root(), selected = try selected(), commands = Commands(), verifier = try verifier(selected, root: root, commands: commands)
        try await verifier.verify(app: selected.app, target: target)
        try await verifier.verify(app: selected.app, target: target)
        let (calls, stops) = await commands.snapshot(); XCTAssertEqual(calls.count, 2); XCTAssertEqual(stops, 2)
        XCTAssertEqual(calls[0].environment["DEVELOPER_DIR"], root.appendingPathComponent("Developer").path)
        XCTAssertEqual(Array(calls[0].arguments.prefix(7)), ["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps"])
        XCTAssertNotEqual(calls[0].arguments[8], calls[1].arguments[8])
        let evidence = try JSONDecoder().decode(AutomationJSON.self, from: Data(contentsOf: root.appendingPathComponent("physical-subject-presence-1.json")))
        XCTAssertEqual(evidence.object?["installedBytesVerified"], .bool(false))
        XCTAssertEqual(evidence.object?["evidenceScope"], .string("installedBundlePresence"))
    }
    func testMissingChangedStaleAndFailedInventoryCannotProducePresenceEvidence() async throws {
        for mode in [Commands.Mode.missing, .wrongDevice, .wrongURL, .staleOutput, .nonzero, .truncated] {
            let root = try root(), selected = try selected(), commands = Commands(mode), verifier = try verifier(selected, root: root, commands: commands)
            do { try await verifier.verify(app: selected.app, target: target); XCTFail("Unproved presence") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("physical-subject-presence-1.json").path))
            let (_, stops) = await commands.snapshot(); XCTAssertEqual(stops, 1)
        }
    }
    func testStrongOrForeignIdentityCannotUseWeakVerifier() async throws {
        let root = try root(), selected = try selected(), commands = Commands(), verifier = try verifier(selected, root: root, commands: commands)
        var strong = selected.app; strong.productDigest = String(repeating: "a", count: 64)
        for app in [strong, AppIdentity(logicalID: "foreign", bundleID: "example.Other", platform: "ios")] {
            do { try await verifier.verify(app: app, target: target); XCTFail("Foreign identity") } catch {}
        }
        let (calls, _) = await commands.snapshot(); XCTAssertTrue(calls.isEmpty)
    }
    func testFailedDrainLatchesAndRunnerCallbackFailureRetainsOwnershipBoundary() async throws {
        let root = try root(), selected = try selected(), commands = Commands(.failedDrain), verifier = try verifier(selected, root: root, commands: commands)
        for _ in 0..<2 { do { try await verifier.verify(app: selected.app, target: target); XCTFail("Failed drain") } catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) } }
        let (calls, _) = await commands.snapshot(); XCTAssertEqual(calls.count, 1)
        let runnerCommands = Commands(.failedRunner), failedRunner = try self.verifier(selected, root: root, commands: runnerCommands, didStart: { _ in throw AutomationContractError.unknownLease })
        do { try await failedRunner.verify(app: selected.app, target: target); XCTFail("Runner callback") } catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let (_, stops) = await runnerCommands.snapshot(); XCTAssertEqual(stops, 1)
    }
    func testGenericVerifierCannotTurnMissingPhysicalDigestIntoUncheckedSuccess() async throws {
        let root = try root(), selected = try selected(), generic = AutomationInstalledSubjectVerifier(developerDirectory: root.appendingPathComponent("Developer"), workspace: root)
        do { try await generic.verify(app: selected.app, target: target); XCTFail("Unchecked physical app") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Physical apps require positive installed-bundle presence evidence")) }
    }
    func testWeakSubjectAllowsVisibleStatePlanButRefusesMutationSystemRouteAndLocalInstallPath() throws {
        let selected = try selected(), subject = AutomationApplicationSubject.installedPhysicalUI(selected)
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect", effects: [.observe, .navigate])
        segment.uiProgram = .init(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.label, "Ready"))])
        var plan = AutomationCase(id: "weak", app: selected.app, target: target, environmentID: "test", execution: segment)
        try subject.validate(plan: plan); XCTAssertNil(subject.productPath); XCTAssertNil(subject.prepared)
        plan.execution.effects.insert(.fixtureWrite); XCTAssertThrowsError(try subject.validate(plan: plan))
        plan.execution.effects = [.observe]; plan.execution.kind = .systemIntent; XCTAssertThrowsError(try subject.validate(plan: plan))
    }
    func testCoreComparisonRefusesEitherUnreadableBuildEvenWhenUIAdmissionIsBypassed() throws {
        let selected = try selected()
        var plan = AutomationCase(id: "weak", app: selected.app, target: target, environmentID: "test",
            execution: .init(id: "subject", kind: .ui, phase: .subject, operation: "inspect"))
        let weak = try AutomationFrozenCase(plan: plan)
        var strong = selected.app; strong.productDigest = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: weak, app: strong))
        plan.app = strong; plan.revision += 1; let strongCase = try AutomationFrozenCase(plan: plan)
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: weak, candidate: strongCase))
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: strongCase, candidate: weak))
    }
}
#endif
