#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalRunnerVerifierTests: XCTestCase, @unchecked Sendable {
    typealias Verifier = AutomationPhysicalRunnerVerifier
    private let target = TargetIdentity(id: "00008140-000E4D803C0B001C", kind: .physical)
    private let controllers = [Verifier.Controller(bundleID: "example.Runner", executableName: "Runner"),
                               Verifier.Controller(bundleID: "example.Tests.xctrunner", executableName: "Tests-Runner")]
    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("physical-inspector-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        return try AutomationPath.canonical(root)
    }
    private actor Commands {
        var invocations: [Verifier.InventoryInvocation] = []
        var stops = 0
        var stopResult = true, wrongOutput = false, failRun = false
        var gate: CheckedContinuation<Void, Never>?
        var started: AsyncStream<Void>.Continuation?
        init(stopResult: Bool = true, wrongOutput: Bool = false, failRun: Bool = false, started: AsyncStream<Void>.Continuation? = nil) {
            self.stopResult = stopResult; self.wrongOutput = wrongOutput; self.failRun = failRun; self.started = started
        }
        func run(_ invocation: Verifier.InventoryInvocation) async throws -> AutomationOwnedCommand.Result {
            invocations.append(invocation)
            if let started { self.started = nil; await withCheckedContinuation { gate = $0; started.yield(()) } }
            if failRun { throw AutomationContractError.invalidIdentity }
            let arguments = invocation.arguments, kind = arguments[3]
            guard let outputIndex = arguments.firstIndex(of: "--json-output") else { throw AutomationContractError.invalidIdentity }
            let output = URL(fileURLWithPath: arguments[outputIndex + 1])
            var declared = arguments
            if wrongOutput { declared[outputIndex + 1] = output.deletingLastPathComponent().appendingPathComponent("stale.json").path }
            var result: [String: Any] = ["deviceIdentifier": "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"]
            if kind == "apps" {
                result["apps"] = []
                for flag in ["defaultAppsIncluded", "hiddenAppsIncluded", "internalAppsIncluded", "removableAppsIncluded"] { result[flag] = true }
            } else { result["runningProcesses"] = [["processIdentifier": 1, "executable": "file:///sbin/launchd"]] }
            let data = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "jsonVersion": 5,
                "commandType": "devicectl.device.info." + kind, "arguments": declared], "result": result])
            try data.write(to: output, options: .withoutOverwriting)
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func stop() -> Bool { stops += 1; return stopResult }
        func resume() { gate?.resume(); gate = nil }
        func snapshot() -> ([Verifier.InventoryInvocation], Int) { (invocations, stops) }
    }
    private func verifier(_ root: URL, commands: Commands) throws -> Verifier {
        try .init(workspace: root, developerDirectory: root.appendingPathComponent("Developer"),
            commands: .init(run: { invocation, _ in try await commands.run(invocation) }, stop: { await commands.stop() }))
    }
    func testThreeSegmentsCanEachPrepareAndReleaseWithoutExhaustingInventory() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(), verifier = try verifier(root, commands: commands)
        for _ in 0..<6 {
            let observation = try await verifier.inspect(target: target, controllers: controllers)
            XCTAssertTrue(observation.controllers.allSatisfy(\.absent))
        }
        let (invocations, _) = await commands.snapshot()
        XCTAssertEqual(invocations.count, 12)
        let outputs = invocations.map { $0.arguments[$0.arguments.firstIndex(of: "--json-output")! + 1] }
        XCTAssertEqual(Set(outputs).count, 12)
        for output in outputs { XCTAssertTrue(FileManager.default.fileExists(atPath: output)) }
    }
    func testAllControllersShareTwoExactDeviceInventoriesAndSelectedToolchain() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(), verifier = try verifier(root, commands: commands)
        let observation = try await verifier.inspect(target: target, controllers: controllers)
        XCTAssertEqual(observation.controllers.map(\.controller), controllers)
        XCTAssertTrue(observation.controllers.allSatisfy(\.absent))
        let (invocations, _) = await commands.snapshot(); XCTAssertEqual(invocations.count, 2)
        for (index, invocation) in invocations.enumerated() {
            XCTAssertEqual(invocation.executable.path, "/usr/bin/xcrun")
            XCTAssertEqual(invocation.directory, root)
            XCTAssertEqual(invocation.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": root.appendingPathComponent("Developer").path])
            XCTAssertEqual(invocation.timeout, .seconds(15))
            XCTAssertEqual(Array(invocation.arguments.prefix(6)), ["devicectl", "device", "info", index == 0 ? "apps" : "processes", "--device", target.id])
            XCTAssertEqual(invocation.arguments.contains("--include-all-apps"), index == 0)
        }
        XCTAssertNotEqual(observation.appsSHA256, observation.processesSHA256)
    }
    func testCopiedInventoryWithAnotherOutputPathFailsBeforeProcessInspection() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(wrongOutput: true), verifier = try verifier(root, commands: commands)
        do { _ = try await verifier.inspect(target: target, controllers: controllers); XCTFail("Stale declaration accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let (invocations, _) = await commands.snapshot(); XCTAssertEqual(invocations.count, 1)
    }
    func testFailedDrainLatchesAndPreventsFurtherCommands() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(stopResult: false, failRun: true), verifier = try verifier(root, commands: commands)
        do { _ = try await verifier.inspect(target: target, controllers: controllers); XCTFail("Command failure accepted") } catch {}
        let drained = await verifier.drainInspector(); XCTAssertFalse(drained)
        do { _ = try await verifier.inspect(target: target, controllers: controllers); XCTFail("Unproved inspector reused") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let (invocations, stops) = await commands.snapshot(); XCTAssertEqual(invocations.count, 1); XCTAssertEqual(stops, 2)
    }
    func testRunnerRejectsOverlappingBatchesBeforeAnotherCommandStarts() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let started = AsyncStream<Void>.makeStream(), commands = Commands(started: started.continuation)
        let verifier = try verifier(root, commands: commands), target = self.target, controllers = self.controllers
        let first = Task { try await verifier.inspect(target: target, controllers: controllers) }
        for await _ in started.stream { break }
        do { _ = try await verifier.inspect(target: target, controllers: controllers); XCTFail("Overlapping batch accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let (during, _) = await commands.snapshot(); XCTAssertEqual(during.count, 1)
        await commands.resume(); _ = try await first.value; started.continuation.finish()
        let (finished, _) = await commands.snapshot(); XCTAssertEqual(finished.count, 2)
    }
    func testInvalidControllerOrTargetCannotStartInventory() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(), verifier = try verifier(root, commands: commands)
        for controllers in [[], [self.controllers[0], self.controllers[0]], [.init(bundleID: "example.Invalid_Runner", executableName: "Runner")]] {
            do { _ = try await verifier.inspect(target: target, controllers: controllers); XCTFail("Invalid controllers accepted") } catch {}
        }
        do { _ = try await verifier.inspect(target: .init(id: target.id, kind: .simulator), controllers: self.controllers); XCTFail("Wrong kind accepted") } catch {}
        let (invocations, _) = await commands.snapshot(); XCTAssertTrue(invocations.isEmpty)
    }
}
#endif
