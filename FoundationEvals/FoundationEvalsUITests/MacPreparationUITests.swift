import XCTest

final class MacPreparationUITests: XCTestCase {
    /// Opt-in: prepares the committed Mac fixture, then saves an unexecuted draft.
    @MainActor
    func testSelectedToolchainPreparesMacCopyAndSavesReviewedDraft() throws {
        executionTimeAllowance = 600
        let fixture = try AutomationFixtureUITestSupport(requiresSimulator: false)
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "native-mac-preparation")
        print("NATIVE_MAC_PREPARATION_STORAGE=\(storage.path)")
        // Keep build provenance, saved draft and screenshots for inspection.
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

        let instruction = app.textFields["What should the app do?"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        instruction.click(); instruction.typeText("Show the task list")
        let endpoint = app.textFields["Destination control"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.click(); endpoint.typeText("Automation Fixture")
        selectAutomationMenu(app.popUpButtons["Effects of this workflow"], item: "Observation and navigation")
        app.checkBoxes["I confirm this workflow stays within these effects"].click()
        let review = app.buttons["Review Mac workflow…"]
        XCTAssertTrue(review.isEnabled); review.click()
        let save = app.buttons["Save draft"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.staticTexts["This draft has no execution result. Saving it does not approve or run the app."].exists)
        try capture(app, storage: storage, name: "workflow-review")
        save.click()
        XCTAssertTrue(app.staticTexts["Mac workflow draft saved. It has no execution result or approval."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Run workflow…"].exists)
        try capture(app, storage: storage, name: "saved-draft")
        let cases = automation.appendingPathComponent("Cases")
        let definitions = try jsonFiles(in: cases.appendingPathComponent("Definitions"))
        XCTAssertEqual(definitions.count, 1)
        let draft = try object(XCTUnwrap(definitions.first))
        XCTAssertEqual(draft["schemaVersion"] as? Int, 1)
        let plan = try XCTUnwrap(draft["plan"] as? [String: Any])
        XCTAssertEqual(plan["schemaVersion"] as? Int, 3)
        XCTAssertEqual((plan["app"] as? [String: Any])?["bundleID"] as? String, AutomationFixtureUITestSupport.macBundleID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cases.appendingPathComponent("Attempts").path))
        XCTAssertTrue(try jsonFiles(in: automation).allSatisfy { $0.lastPathComponent != "report.json" })
        try fixture.assertSourceUnchanged()
    }
    private func jsonFiles(in directory: URL) throws -> [URL] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
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
