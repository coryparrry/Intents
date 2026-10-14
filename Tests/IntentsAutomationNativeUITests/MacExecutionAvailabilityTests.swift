#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class MacExecutionAvailabilityTests: XCTestCase {
    private actor ExecutionTrap {
        var calls = 0
        func invoked() throws -> AutomationAttemptReport { calls += 1; throw AutomationContractError.invalidIdentity }
        func count() -> Int { calls }
    }
    private func fixture() async throws -> (AppAutomationStore, URL, ExecutionTrap) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        var app = root.appendingPathComponent("Selected.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        app = try AutomationPath.canonical(app)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.SelectedMac", "CFBundleExecutable": "Fixture",
            "CFBundleName": "Selected", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["MacOSX"]], format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        var binary = Data(repeating: 0, count: 56)
        for (offset, value) in [(0, UInt32(0xfeedfacf)), (4, 0x0100000c), (12, 2), (16, 1), (20, 24), (32, 0x32), (36, 24), (40, 1)] {
            for byte in 0..<4 { binary[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        try binary.write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        _ = try AutomationApplicationIntake.assess(app)
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session-A")
        let trap = ExecutionTrap()
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            runExecutor: { _, _, _, _, _, _ in try await trap.invoked() }, nativeMacTargetReader: { target })
        model.select(app); await model.task?.value
        model.uiInstruction = "Open Settings"; model.uiEndpoint = "Settings"
        model.effectChoice = "navigation"; model.effectsConfirmed = true
        return (model, root, trap)
    }
    func testUnavailableMacExecutionCannotQueueOrInvokeInjectedExecutor() async throws {
        let (model, root, trap) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.simulatorID = UUID().uuidString
        XCTAssertTrue(model.isInstalledMacUI); XCTAssertTrue(model.isMacWorkflowUnavailable)
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: String(repeating: "a", count: 64)))
        model.run()
        XCTAssertFalse(model.canRun)
        XCTAssertNil(model.pendingCommandStatus)
        let calls = await trap.count(); XCTAssertEqual(calls, 0)
    }
}
#endif
