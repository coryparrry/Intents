#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class MacWorkflowStoreTests: XCTestCase {
    private final class TargetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session-A")
        func read() -> TargetIdentity { lock.withLock { target } }
        func change() { lock.withLock { target.loginSession = "synthetic-session-B" } }
    }
    private actor ExecutionTrap {
        var calls = 0
        func invoked() throws -> AutomationAttemptReport { calls += 1; throw AutomationContractError.invalidIdentity }
        func count() -> Int { calls }
    }
    private func fixture() throws -> (AppAutomationStore, URL, URL, TargetBox, ExecutionTrap) {
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
        let target = TargetBox(), trap = ExecutionTrap()
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            runExecutor: { _, _, _, _, _, _ in try await trap.invoked() }, nativeMacTargetReader: { target.read() })
        model.select(app)
        model.uiInstruction = "Open Settings"; model.uiEndpoint = "Settings"
        model.effectChoice = "navigation"; model.effectsConfirmed = true
        return (model, root, app, target, trap)
    }
    func testExactMacSelectionProducesSessionBoundUnqualifiedWorkflowReview() throws {
        let (model, root, app, target, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.isInstalledMacUI); XCTAssertTrue(model.isUIWorkflow)
        XCTAssertTrue(model.canReviewMacWorkflow); XCTAssertFalse(model.canRun)
        let reviewed = try model.reviewMacWorkflow()
        XCTAssertEqual(reviewed.plan.app, model.candidate?.app)
        XCTAssertEqual(reviewed.plan.app.canonicalBundlePath, app.path)
        XCTAssertEqual(reviewed.plan.target, target.read())
        XCTAssertEqual(reviewed.plan.provenance["ui.executionAvailability"], "unqualified")
        XCTAssertEqual(reviewed.approval.approvedCaseDigest, reviewed.id)
        XCTAssertTrue(reviewed.plan.requirements.isEmpty)
    }
    func testIndependentVisibleRequirementIsSavedWithNoAttemptOrExecutionApproval() async throws {
        let (model, root, _, _, trap) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.uiExpectedText = "Saved"
        let reviewed = try model.reviewMacWorkflow()
        XCTAssertEqual(reviewed.plan.requirements.first?.expected, .text("Saved"))
        XCTAssertEqual(reviewed.plan.observations.count, 1)
        try await model.saveMacWorkflowDraft(reviewed)
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
        let attempts = try await cases.attempts(for: definitions[0]); XCTAssertTrue(attempts.isEmpty)
        XCTAssertNil(model.pendingCommandStatus); XCTAssertNil(model.report)
        XCTAssertEqual(model.savedCases.first?.digest, reviewed.id)
        let calls = await trap.count(); XCTAssertEqual(calls, 0)
    }
    func testMacDraftCannotQueueOrRunEvenWithInjectedExecutorAndSimulatorSelection() async throws {
        let (model, root, _, _, trap) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.simulatorID = UUID().uuidString
        let review = try model.reviewMacWorkflow()
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: review.id))
        model.run()
        XCTAssertFalse(model.canRun); XCTAssertNil(model.pendingCommandStatus)
        let calls = await trap.count(); XCTAssertEqual(calls, 0)
    }
    func testReviewShowsTheControlAndRejectsChangedObserverLabel() async throws {
        let (model, root, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.uiObservationProperty = "value"; model.uiObservationLabel = "Display name"; model.uiExpectedText = "Saved"
        let review = try model.reviewMacWorkflow()
        XCTAssertEqual(review.visibleCheck, "Display name · value: Saved")
        model.uiObservationLabel = "Other control"
        do { try await model.saveMacWorkflowDraft(review); XCTFail() } catch {}
    }
    func testChangedSessionOrProductRejectsReviewAndSave() async throws {
        let (model, root, app, target, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try model.reviewMacWorkflow()
        target.change()
        XCTAssertThrowsError(try model.reviewMacWorkflow())
        do { try await model.saveMacWorkflowDraft(original); XCTFail() } catch {}
        model.select(app); model.uiInstruction = "Open Settings"; model.uiEndpoint = "Settings"
        model.effectChoice = "navigation"; model.effectsConfirmed = true
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertThrowsError(try model.reviewMacWorkflow())
    }
    func testChangedWorkflowRefusesOldDraftAndUnsupportedTextIsNotApproved() async throws {
        let (model, root, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try model.reviewMacWorkflow()
        model.uiEndpoint = "Other screen"
        do { try await model.saveMacWorkflowDraft(original); XCTFail() } catch {}
        model.uiApprovedText = "ordinary text"
        XCTAssertFalse(model.canReviewMacWorkflow)
        XCTAssertThrowsError(try model.reviewMacWorkflow())
        model.uiApprovedText = ""; model.effectsConfirmed = false
        XCTAssertFalse(model.canReviewMacWorkflow)
    }
    func testSourceOrOtherProductSelectionClearsCachedMacSession() throws {
        let (model, root, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(model.selectedMacTarget)
        model.intake = .init(candidates: [], gaps: [], requiresBuildApproval: false)
        model.selectCandidate()
        XCTAssertNil(model.selectedMacTarget); XCTAssertFalse(model.canReviewMacWorkflow)
    }
}
#endif
