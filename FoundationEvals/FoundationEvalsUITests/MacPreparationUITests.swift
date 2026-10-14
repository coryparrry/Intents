import XCTest

final class MacPreparationUITests: XCTestCase {
    /// Opt-in: prepares the committed Mac fixture and inspects its metadata.
    @MainActor
    func testSelectedToolchainPreparesMacCopyForInspection() throws {
        executionTimeAllowance = 600
        let fixture = try AutomationFixtureUITestSupport(requiresSimulator: false)
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "native-mac-preparation")
        print("NATIVE_MAC_PREPARATION_STORAGE=\(storage.path)")
        // Keep build provenance and screenshots for inspection.
        let app = XCUIApplication()
        fixture.configure(app, storage: storage)
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(app.popUpButtons["App"], item: "AutomationFixtureMac")
        selectAutomationMenu(app.popUpButtons["automation.preparation.destination"], item: "macOS")
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "ui")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        let build = app.buttons["Build private copy"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "build-review")
        build.click()
        let ready = app.staticTexts["Prepared a private Mac copy for inspection. Mac workflow execution is not available yet."]
        XCTAssertTrue(ready.waitForExistence(timeout: 300), app.debugDescription)

        let automation = storage.appendingPathComponent("Automation")
        let preparations = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("prepare-") }
        XCTAssertEqual(preparations.count, 1)
        let prepared = try object(try XCTUnwrap(preparations.first).appendingPathComponent("prepared-application.json"))
        let host = try XCTUnwrap(prepared["host"] as? [String: Any])
        let identity = try XCTUnwrap(host["app"] as? [String: Any])
        XCTAssertEqual(identity["bundleID"] as? String, AutomationFixtureUITestSupport.macBundleID)
        XCTAssertEqual(identity["platform"] as? String, "macos")
        XCTAssertEqual((host["target"] as? [String: Any])?["kind"] as? String, "nativeMac")
        let product = URL(fileURLWithPath: try XCTUnwrap(host["subjectProductPath"] as? String))
        let metadata = try object(product.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata"))
        XCTAssertEqual(metadata["version"] as? Int, 1)
        let catalog = try XCTUnwrap(prepared["catalog"] as? [String: Any])
        let actions = try XCTUnwrap(catalog["systemActions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains { ($0["typeName"] as? String)?.hasSuffix("EchoIntegerArrayIntent") == true })
        XCTAssertTrue(actions.contains { ($0["typeName"] as? String)?.hasSuffix("CompleteTaskIntent") == true })

        XCTAssertTrue(app.staticTexts["Mac workflow execution is unavailable."].exists)
        XCTAssertFalse(app.buttons["Run workflow…"].exists)
        XCTAssertFalse(app.buttons["Review Mac workflow…"].exists)
        try capture(app, storage: storage, name: "prepared-mac-copy")
        try fixture.assertSourceUnchanged()
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    @MainActor
    private func capture(_ app: XCUIApplication, storage: URL, name: String) throws {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: storage.appendingPathComponent(name + ".png"))
    }
}
