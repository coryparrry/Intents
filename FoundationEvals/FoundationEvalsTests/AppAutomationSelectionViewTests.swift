import AppKit
import Foundation
import SwiftUI
import Synchronization
import XCTest
@testable import IntentsAutomationCore
@testable import FoundationEvals

@MainActor final class AppAutomationSelectionViewTests: XCTestCase {
    func testSlowCatalogAfterConfigurationInitializationPublishesWithoutInvalidatingSelection() async throws {
        let fixture = try SelectionViewFixture(initialConfiguration: "Debug")
        defer { fixture.close() }
        await waitUntil { fixture.viewTasksStarted }
        fixture.model.select(fixture.root)
        let selection = fixture.model.task
        await waitUntil { fixture.catalogGate.isBlocked }
        let epoch = fixture.model.selectionEpoch
        // Give the actual SwiftUI configuration observer a render turn while the read is held.
        fixture.hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.model.configuration, "")
        XCTAssertEqual(fixture.model.selectionEpoch, epoch)
        fixture.catalogGate.release()
        await selection?.value
        XCTAssertNotNil(fixture.model.catalog)
        await fixture.model.closeAndWait()
    }

    func testSimulatorInventoryRetriesAfterSlowCatalogClearsBusyState() async throws {
        let fixture = try SelectionViewFixture()
        defer { fixture.close() }
        await waitUntil { fixture.viewTasksStarted }
        fixture.model.select(fixture.root)
        let selection = fixture.model.task
        await waitUntil { fixture.catalogGate.isBlocked }
        fixture.hostingView.layoutSubtreeIfNeeded()
        // The selection task remains busy long enough for the initial inventory task to exit.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fixture.model.busy)
        XCTAssertEqual(fixture.inventoryReads, 0)
        fixture.catalogGate.release()
        await selection?.value
        await waitUntil { fixture.model.simulators.contains { $0.id == fixture.simulator.id } }
        XCTAssertFalse(fixture.model.busy)
        XCTAssertGreaterThan(fixture.inventoryReads, 0)
        XCTAssertEqual(fixture.model.simulatorID, fixture.simulator.id)
        await fixture.model.closeAndWait()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Hosted App automation view did not reach the expected state", file: file, line: line)
    }
}

@MainActor private final class SelectionViewFixture {
    let root: URL
    let model: AppAutomationStore
    let catalogGate: SelectionViewCatalogGate
    let simulator: AutomationSimulator
    let hostingView: NSHostingView<AppAutomationView>
    let window: NSWindow
    private let activity: SelectionViewActivity
    var viewTasksStarted: Bool { activity.viewTasksStarted }
    var inventoryReads: Int { activity.inventoryReads }

    init(initialConfiguration: String = "") throws {
        let root = URL(fileURLWithPath: "/private/tmp/selection-view-" + UUID().uuidString); self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = SelectionViewCatalogGate(); catalogGate = gate
        let simulator = AutomationSimulator(id: UUID().uuidString, name: "Fixture simulator", runtime: "fixture-runtime", state: "Shutdown"); self.simulator = simulator
        let activity = SelectionViewActivity(); self.activity = activity
        let app = AppIdentity(logicalID: "selection-view-fixture", bundleID: "example.Selection", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let candidate = AutomationApplicationCandidate(id: app.logicalID, name: "Selected", kind: .installedProduct,
            containerPath: root.path, bundleID: app.bundleID, platform: app.platform, architectures: ["arm64"], app: app)
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            savedCasesReader: { activity.viewStarted(); return [] },
            simulatorInventoryReader: { _, _ in activity.readInventory(); return [simulator] },
            installedToolchainReader: { _ in [] },
            intakeAssessor: { _ in .init(candidates: [candidate], gaps: [], requiresBuildApproval: false) },
            selectionCatalogReader: { app, _ in
                gate.hold()
                return .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
            })
        self.model = model
        model.configuration = initialConfiguration
        let hostingView = NSHostingView(rootView: AppAutomationView(model: model)); self.hostingView = hostingView
        // Host the real view outside every display without making it key or activating the app.
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let bottom = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let window = NSWindow(contentRect: NSRect(x: left - 2_000, y: bottom - 2_000, width: 850, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
    }
    func close() {
        catalogGate.release(); model.close()
        window.orderOut(nil); window.contentView = nil; window.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SelectionViewCatalogGate: Sendable {
    private let blocked = Mutex(false)
    private let completion = DispatchSemaphore(value: 0)
    var isBlocked: Bool { blocked.withLock { $0 } }
    func hold() {
        XCTAssertFalse(Thread.isMainThread)
        blocked.withLock { $0 = true }
        _ = completion.wait(timeout: .now() + 10)
        blocked.withLock { $0 = false }
    }
    func release() { completion.signal() }
}

private final class SelectionViewActivity: Sendable {
    private let state = Mutex((viewStarted: false, inventoryReads: 0))
    var viewTasksStarted: Bool { state.withLock { $0.viewStarted } }
    var inventoryReads: Int { state.withLock { $0.inventoryReads } }
    func viewStarted() { state.withLock { $0.viewStarted = true } }
    func readInventory() { state.withLock { $0.inventoryReads += 1 } }
}
