#if os(macOS)
import Foundation
import XCTest
import Synchronization
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class ApplicationSelectionResponsivenessTests: XCTestCase {
    private func fixture(intakeGate: SelectionReadGate? = nil, catalogGate: SelectionReadGate? = nil) throws -> (AppAutomationStore, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/selection-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "selection-fixture", bundleID: "example.Selection", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let candidate = AutomationApplicationCandidate(id: app.logicalID, name: "Selected", kind: .installedProduct,
            containerPath: root.path, bundleID: app.bundleID, platform: app.platform, architectures: ["arm64"], app: app)
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            intakeAssessor: { _ in
                intakeGate?.hold()
                return .init(candidates: [candidate], gaps: [], requiresBuildApproval: false)
            }, selectionCatalogReader: { app, _ in
                catalogGate?.hold()
                return .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
            })
        return (model, root)
    }
    func testIntakeAllowsMainActorHeartbeatAndPublishesWhenFinished() async throws {
        let gate = SelectionReadGate(), (model, root) = try fixture(intakeGate: gate)
        defer { gate.release() }
        model.select(root); let selection = model.task
        XCTAssertTrue(model.busy); XCTAssertNil(model.intake)
        await gate.waitForEntry()
        let heartbeat = await Task { @MainActor in true }.value
        XCTAssertTrue(heartbeat); XCTAssertTrue(gate.isBlocked)
        gate.release(); await selection?.value
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.candidate); XCTAssertNotNil(model.catalog)
    }
    func testCancellingIntakeDiscardsItsResultAndReleasesBusyState() async throws {
        let gate = SelectionReadGate(), (model, root) = try fixture(intakeGate: gate)
        defer { gate.release() }
        model.select(root); let selection = model.task
        await gate.waitForEntry(); model.cancel(); gate.release(); await selection?.value
        XCTAssertFalse(model.busy); XCTAssertNil(model.intake); XCTAssertNil(model.catalog)
        XCTAssertTrue(model.message?.contains("Cancelled") == true)
        model.select(root); await model.task?.value
        XCTAssertNotNil(model.candidate); XCTAssertNotNil(model.catalog)
    }
    func testCatalogAllowsHeartbeatAndCancellationDiscardsIt() async throws {
        let gate = SelectionReadGate(), (model, root) = try fixture(catalogGate: gate)
        defer { gate.release() }
        model.select(root); let selection = model.task
        await gate.waitForEntry()
        let heartbeat = await Task { @MainActor in true }.value
        XCTAssertTrue(heartbeat); XCTAssertTrue(model.busy); XCTAssertTrue(gate.isBlocked)
        XCTAssertNotNil(model.candidate); XCTAssertNil(model.catalog)
        model.cancel(); gate.release(); await selection?.value
        XCTAssertFalse(model.busy); XCTAssertNil(model.catalog)
    }
    func testCandidateCatalogCannotPublishAfterSelectionEpochChanges() async throws {
        let gate = SelectionReadGate(), (model, root) = try fixture()
        model.select(root); await model.task?.value
        // Use a second store with a held catalog to exercise selectCandidate directly.
        let (held, _) = try fixture(catalogGate: gate)
        held.intake = model.intake; held.candidateID = model.candidateID
        defer { gate.release() }
        held.selectCandidate(); let selection = held.task
        await gate.waitForEntry(); held.preparationSelectionChanged()
        gate.release(); await selection?.value
        XCTAssertFalse(held.busy); XCTAssertNil(held.catalog)
    }
    func testClosingDuringIntakeCannotPublishSelection() async throws {
        let gate = SelectionReadGate(), (model, root) = try fixture(intakeGate: gate)
        defer { gate.release() }
        model.select(root); let selection = model.task
        await gate.waitForEntry(); model.close(); gate.release(); await selection?.value
        XCTAssertFalse(model.busy); XCTAssertNil(model.intake); XCTAssertNil(model.catalog)
        XCTAssertEqual(model.candidateID, "")
    }
}

private final class SelectionReadGate: Sendable {
    private struct State { var entered = false; var blocked = false; var calls = 0 }
    private let state = Mutex(State())
    private let completion = DispatchSemaphore(value: 0)
    var isBlocked: Bool { state.withLock { $0.blocked } }
    func hold() {
        XCTAssertFalse(Thread.isMainThread)
        let first = state.withLock { value in
            value.calls += 1
            guard value.calls == 1 else { return false }
            value.entered = true; value.blocked = true; return true
        }
        guard first else { return }
        _ = completion.wait(timeout: .now() + 10)
        state.withLock { $0.blocked = false }
    }
    func release() { completion.signal() }
    func waitForEntry() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !state.withLock({ $0.entered }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.withLock { $0.entered })
    }
}
#endif
