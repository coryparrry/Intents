import XCTest

final class FreshRecordAutomationUITests: XCTestCase {
    /// Real, opt-in UI → App Intent → persisted entity-query workflow.
    @MainActor
    func testFreshDuplicateRecordsPreserveTheOtherOwner() throws {
        executionTimeAllowance = 600
        let fixture = try AutomationFixtureUITestSupport(requiresSimulator: true)
        let simulatorID = try XCTUnwrap(fixture.simulatorID)
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "native-fresh-automation")
        print("NATIVE_FRESH_STORAGE=\(storage.path)")
        let app = XCUIApplication()
        fixture.configure(app, storage: storage)
        app.launch()
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(app.popUpButtons["App"], item: "AutomationFixture")
        selectAutomationMenu(app.popUpButtons["automation.preparation.destination"], item: "simulator")
        selectAutomationMenu(app.popUpButtons["automation.preparation.simulator"], item: simulatorID, timeout: 30)
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "fresh")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        let build = app.buttons["Build private copy"]
        XCTAssertTrue(build.waitForExistence(timeout: 5)); build.click()
        let action = app.popUpButtons["automation.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 300), app.debugDescription)
        selectAutomationMenu(action, item: "Complete task")
        try fill(app, "How should the app create and save the record?",
                 "Create and save a task using the approved test record name and the specified account. Enter the name in Task title, select the specified Account if needed, and press Add task once. Finish when the new task row is visible.")
        try fill(app, "Visible destination after saving", "Automation Fixture")
        try fill(app, "Record name entry control", "id:task.title")
        try fill(app, "Save control", "id:task.add")
        try fill(app, "Test record name prefix", "Intents v3 record")
        try select(app, "Record name", "Title")
        app.checkBoxes["Check another record with the same name stays unchanged"].click()
        try select(app, "Distinguish records by", "Account")
        try fill(app, "Owner or list of the record to act on", "Personal")
        try fill(app, "Owner or list of the record to keep unchanged", "Work")
        try select(app, "State to check", "Completed")
        try select(app, "State before the action", "False")
        try select(app, "Expected state after the action", "True")
        try select(app, "Effects of this action", "Changes to test fixtures")
        app.checkBoxes["I confirm this action stays within these effects"].click()
        let disposable = app.checkBoxes["Disposable test environment"]
        if disposable.value as? Int != 1 { disposable.click() }
        let install = app.checkBoxes["Allow starting this simulator and installing the prepared app"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        if install.value as? Int != 1 { install.click() }
        XCTAssertEqual(install.value as? Int, 1)
        let run = app.buttons["Run test record workflow…"]
        XCTAssertTrue(run.isEnabled, app.debugDescription); run.click()
        let approve = app.buttons["Run approved workflow"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), app.debugDescription)
        try capture(app, storage: storage, name: "fresh-workflow-review")
        approve.click()
        let reportURL = storage.appendingPathComponent("Automation")
        let reportExists = NSPredicate { _, _ in !self.reports(in: reportURL).isEmpty }
        let completed = expectation(for: reportExists, evaluatedWith: nil)
        wait(for: [completed], timeout: 600)
        let reports = reports(in: reportURL)
        XCTAssertEqual(reports.count, 1)
        let report = try object(XCTUnwrap(reports.first))
        XCTAssertEqual(report["resourcesReleased"] as? Bool, true)
        let result = try XCTUnwrap(report["result"] as? [String: Any])
        XCTAssertEqual(result["summary"] as? String, "passed", String(describing: result))
        XCTAssertEqual(result["assessed"] as? Bool, true)
        XCTAssertEqual(result["subjectCompleted"] as? Bool, true)
        XCTAssertEqual(result["subjectDispatchUncertain"] as? Bool, false)
        let receipts = try XCTUnwrap(report["receipts"] as? [[String: Any]])
        XCTAssertFalse(receipts.isEmpty)
        for receipt in receipts {
            XCTAssertEqual((receipt["target"] as? [String: Any])?["id"] as? String, simulatorID)
            XCTAssertEqual((receipt["app"] as? [String: Any])?["bundleID"] as? String,
                           AutomationFixtureUITestSupport.iOSBundleID)
        }
        let saved = app.buttons["View saved result"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.click()
        XCTAssertTrue(app.staticTexts["Saved result · not reverified"].waitForExistence(timeout: 10))
        try capture(app, storage: storage, name: "fresh-saved-result")
        try fixture.assertSourceUnchanged()
    }

    private func reports(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("report.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    @MainActor
    private func select(_ app: XCUIApplication, _ label: String, _ value: String) throws {
        selectAutomationMenu(app.popUpButtons[label], item: value)
    }
    @MainActor
    private func fill(_ app: XCUIApplication, _ label: String, _ value: String) throws {
        let field = app.textFields[label]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(value)
    }
    @MainActor
    private func capture(_ app: XCUIApplication, storage: URL, name: String) throws {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: storage.appendingPathComponent(name + ".png"))
    }
}
