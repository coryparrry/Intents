import XCTest

final class MacPreparationUITests: XCTestCase {
    /// Opt-in: prepares the committed Mac fixture and runs approved native routes.
    @MainActor
    func testSelectedToolchainPreparesMacCopyAndRunsApprovedWorkflows() throws {
        executionTimeAllowance = 900
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
        let ready = app.staticTexts["Prepared a private Mac copy. Choose a system action or exact UI steps and review their permitted effects."]
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

        try capture(app, storage: storage, name: "prepared-mac-copy")
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "system")
        selectAutomationMenu(app.popUpButtons["automation.action"], item: "Echo integer array")
        let input = app.textFields["value (JSON list of whole numbers)"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("[1,2]")
        selectAutomationMenu(app.popUpButtons["Effects of this action"], item: "Observation and navigation")
        app.checkBoxes["I confirm this action stays within these effects"].click()
        XCTAssertFalse(app.checkBoxes["Allow starting this simulator and installing the prepared app"].exists)
        let runAction = app.buttons["Run action…"]
        XCTAssertTrue(runAction.isEnabled); runAction.click()
        let approveAction = app.buttons["Run approved workflow"]
        XCTAssertTrue(approveAction.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "typed-action-review")
        approveAction.click()
        XCTAssertTrue(app.staticTexts["Executed · unassessed"].waitForExistence(timeout: 180), app.debugDescription)
        try capture(app, storage: storage, name: "typed-action-result")

        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "ui")
        let instruction = app.textFields["What should the app do?"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 5)); instruction.click(); instruction.typeText("Observe the fixture controls")
        let endpoint = app.textFields["Destination control"]
        endpoint.click(); endpoint.typeText("id:fixture.control")
        let expected = app.textFields["Expected property value (optional)"]
        expected.click(); expected.typeText("Control")
        selectAutomationMenu(app.popUpButtons["Effects of this workflow"], item: "Observation and navigation")
        if app.checkBoxes["I confirm this workflow stays within these effects"].value as? Int != 1 {
            app.checkBoxes["I confirm this workflow stays within these effects"].click()
        }
        let runWorkflow = app.buttons["Run workflow…"]
        XCTAssertTrue(runWorkflow.isEnabled); runWorkflow.click()
        let approveUI = app.buttons["Run approved workflow"]
        XCTAssertTrue(approveUI.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "ui-workflow-review")
        approveUI.click()
        XCTAssertTrue(app.staticTexts["Passed the approved requirements"].waitForExistence(timeout: 180), app.debugDescription)
        try capture(app, storage: storage, name: "ui-workflow-result")
        let reports = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("report.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(reports.count, 2)
        for reportURL in reports {
            XCTAssertEqual(try object(reportURL)["resourcesReleased"] as? Bool, true)
        }
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
