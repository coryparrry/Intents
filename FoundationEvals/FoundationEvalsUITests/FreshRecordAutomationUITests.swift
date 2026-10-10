import XCTest
import CryptoKit

final class FreshRecordAutomationUITests: XCTestCase {
    /// Real, opt-in UI → App Intent → persisted entity-query workflow.
    @MainActor
    func testFreshDuplicateRecordsPreserveTheOtherOwner() throws {
        executionTimeAllowance = 600
        struct Profile: Decodable {
            let sourceProject: String
            let sourceDigest: String
            let simulatorID: String
            let simulatorLabel: String
            let developerDirectory: String
        }
        let profileURL = UITestStorage.root.appendingPathComponent("automation-native-fresh-approved-profile.json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("Requires an explicitly approved disposable fresh-record fixture profile")
        }
        continueAfterFailure = false
        let bytes = try Data(contentsOf: profileURL)
        XCTAssertLessThanOrEqual(bytes.count, 16_384)
        let profile = try JSONDecoder().decode(Profile.self, from: bytes)
        let project = URL(fileURLWithPath: profile.sourceProject).resolvingSymlinksInPath()
        XCTAssertTrue(project.path.hasPrefix(UITestStorage.root.resolvingSymlinksInPath().path + "/"))
        XCTAssertEqual(project.lastPathComponent, "DuplicateTasks.xcodeproj")
        XCTAssertNotNil(UUID(uuidString: profile.simulatorID))
        let source = project.deletingLastPathComponent().appendingPathComponent("App/TaskIntents.swift")
        XCTAssertEqual(try digest(source), profile.sourceDigest)
        let storage = try UITestStorage.makeDirectory(prefix: "native-fresh-automation")
        print("NATIVE_FRESH_STORAGE=\(storage.path)")
        let app = XCUIApplication()
        app.launchEnvironment["DEVELOPER_DIR"] = profile.developerDirectory
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launch()
        defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let choose = app.buttons["Choose app…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15)); choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5)); path.typeText(project.path)
        app.typeKey(.return, modifierFlags: [])
        let panelChoose = app.buttons["Choose app"]
        XCTAssertTrue(panelChoose.waitForExistence(timeout: 5)); panelChoose.click()
        try select(app, "Simulator", profile.simulatorLabel)
        try select(app, "What to test", "Action on a new test record")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        app.buttons["Build private copy"].click()
        XCTAssertTrue(app.popUpButtons["Action"].waitForExistence(timeout: 300), app.debugDescription)
        try select(app, "Action", "Complete task")
        try fill(app, "How should the app create and save the record?",
                 "Create and save a task using the approved test record name and the specified account. Enter the name in Task title, select the specified Account if needed, and press Add task once. Finish when the new task row is visible.")
        try fill(app, "Visible destination after saving", "Duplicate Tasks")
        try fill(app, "Save button label (optional)", "Add task")
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
            XCTAssertEqual((receipt["target"] as? [String: Any])?["id"] as? String, profile.simulatorID)
            XCTAssertEqual((receipt["app"] as? [String: Any])?["bundleID"] as? String,
                           "com.coryparry.IntentsAutomation.DuplicateTasks")
        }
        let saved = app.buttons["View saved result"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.click()
        XCTAssertTrue(app.staticTexts["Saved result · not reverified"].waitForExistence(timeout: 10))
        try capture(app, storage: storage, name: "fresh-saved-result")
        XCTAssertEqual(try digest(source), profile.sourceDigest)
    }

    private func reports(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("report.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor
    private func select(_ app: XCUIApplication, _ label: String, _ value: String) throws {
        let picker = app.popUpButtons[label]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription); picker.click()
        let item = app.menuItems[value]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.click()
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
