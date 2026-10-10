import XCTest
@testable import IntentsAutomationCore

final class AutomationInstalledUIApplicationTests: XCTestCase, @unchecked Sendable {
    private func bundle(platform: String = "iPhoneSimulator") throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.UIOnly", "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": [platform]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        // Intake-only Mach-O header fixture; never executable or hardware proof.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0]).write(to: root.appendingPathComponent("Fixture"))
        return root
    }
    func testSimulatorBundleSelectionNeedsNoCatalogOrAppleHostButRetainsExactBytes() throws {
        let installed = try AutomationInstalledUIApplication(bundleURL: bundle(), target: .init(id: UUID().uuidString, kind: .simulator))
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.label, "Ready"))])
        let plan = AutomationCase(id: "ui-only", app: installed.app, target: installed.target, environmentID: "owned", execution: subject)
        let chosen = AutomationApplicationSubject.installedUI(installed)
        try chosen.validate(plan: plan)
        XCTAssertNil(chosen.prepared); XCTAssertEqual(chosen.productPath, installed.bundleURL.path)
        XCTAssertNotNil(installed.app.productDigest)
        try Data("changed".utf8).write(to: installed.bundleURL.appendingPathComponent("resource.txt"))
        XCTAssertThrowsError(try chosen.validate(plan: plan))
    }
    func testPhysicalProductsTargetsAndSystemRouteCannotEnterUIOnlyExecution() throws {
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: bundle(platform: "iPhoneOS"), target: .init(id: UUID().uuidString, kind: .simulator)))
        let root = try bundle()
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: root, target: .init(id: "device", kind: .physical)))
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: root, target: .init(id: "invalid", kind: .simulator)))
        let installed = try AutomationInstalledUIApplication(bundleURL: root, target: .init(id: UUID().uuidString, kind: .simulator))
        let plan = AutomationCase(id: "system", app: installed.app, target: installed.target, environmentID: "owned",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ActualIntent"))
        XCTAssertThrowsError(try AutomationApplicationSubject.installedUI(installed).validate(plan: plan))
    }
    func testPhysicalSelectionRetainsLocalBytesButDoesNotClaimDeviceInstallation() throws {
        let root = try bundle(platform: "iPhoneOS")
        try AutomationPhysicalExecutableTests.binary().write(to: root.appendingPathComponent("Fixture"))
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let selected = try AutomationInstalledUIApplication(bundleURL: root, target: target)
        XCTAssertEqual(selected.target, target); XCTAssertEqual(selected.app.architecture, "arm64")
        XCTAssertNotNil(selected.app.productDigest); try selected.verifySelectedProduct()
        try Data("changed".utf8).write(to: root.appendingPathComponent("resource.txt"))
        XCTAssertThrowsError(try selected.verifySelectedProduct())
    }
    func testPhysicalIntakeRejectsSimulatorExecutableEvenWithPhonePlatformPlist() throws {
        let root = try bundle(platform: "iPhoneOS")
        try AutomationPhysicalExecutableTests.binary(platform: 7).write(to: root.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: root,
            target: .init(id: "00008140-001049013EF3401C", kind: .physical)))
    }
    func testExecutableReplacementAfterIntakeCannotQualifyDifferentBytes() throws {
        let root = try bundle(platform: "iPhoneOS")
        try AutomationPhysicalExecutableTests.binary(platform: 7).write(to: root.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: root,
            target: .init(id: "00008140-001049013EF3401C", kind: .physical), afterIntake: {
                try AutomationPhysicalExecutableTests.binary().write(to: root.appendingPathComponent("Fixture"))
            })) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
    }
    func testPlistExecutableSelectionIsBoundToTheSelectedProduct() throws {
        let root = try bundle(platform: "iPhoneOS")
        try AutomationPhysicalExecutableTests.binary(platform: 7).write(to: root.appendingPathComponent("Fixture"))
        try AutomationPhysicalExecutableTests.binary().write(to: root.appendingPathComponent("OtherPhone"))
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        info["CFBundleExecutable"] = "OtherPhone"
        let replacement = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        XCTAssertThrowsError(try AutomationInstalledUIApplication(bundleURL: root,
            target: .init(id: "00008140-001049013EF3401C", kind: .physical), afterIntake: {
                try replacement.write(to: root.appendingPathComponent("Info.plist"))
            })) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
    }
    #if os(macOS)
    func testPhysicalRunnerRequiresInstallationEvidenceBeforeSimulatorInventoryOrAttempt() async throws {
        let root = try bundle(platform: "iPhoneOS")
        try AutomationPhysicalExecutableTests.binary().write(to: root.appendingPathComponent("Fixture"))
        let selected = try AutomationInstalledUIApplication(bundleURL: root,
            target: .init(id: "00008140-001049013EF3401C", kind: .physical))
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect",
            effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.label, "Ready"))])
        let plan = AutomationCase(id: "physical", app: selected.app, target: selected.target, environmentID: "owned", execution: segment)
        let approval = RunApproval(runID: "owned", app: selected.app, target: selected.target, environmentID: "owned",
            effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        let support = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        let calls = PhysicalSelectionInventoryCalls()
        let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: URL(fileURLWithPath: "/private/tmp"),
            simulatorInventory: { _, _ in await calls.increment(); throw AutomationContractError.invalidIdentity })
        do {
            _ = try await runner.run(subject: .installedUI(selected), plan: plan, approval: approval,
                capabilities: .init(), attemptID: "attempt", allowBootAndInstall: true)
            XCTFail("Physical execution needs installed evidence")
        } catch {
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Physical execution requires owned installation evidence and its qualified device route"))
        }
        let count = await calls.value; XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("attempt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases").path))
    }
    #endif
}

#if os(macOS)
private actor PhysicalSelectionInventoryCalls {
    var value = 0
    func increment() { value += 1 }
}
#endif
