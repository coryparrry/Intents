import XCTest

final class IntentLabDeveloperCheckUITests: XCTestCase {
    @MainActor
    func testNewCheckGuidesMissingAppSupportWithoutInventingObservations() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-developer-check")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Create test"].click()
        let create = app.buttons["New test"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        create.click()
        if app.sheets.buttons["Discard draft and continue"].waitForExistence(timeout: 2) {
            app.sheets.buttons["Discard draft and continue"].click()
        }

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Rebuild and check support to load the app's actions"
        )).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.popUpButtons["Feature control backend"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "project-local Feature control"
        )).firstMatch.exists)
        XCTAssertFalse(app.textFields["Optional feature run UUID"].exists)
        XCTAssertFalse(app.textFields["Feature ID from the evaluation"].exists)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Rebuild and check support to choose an observable result"
        )).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add assertion"].exists)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Developer check missing support"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
