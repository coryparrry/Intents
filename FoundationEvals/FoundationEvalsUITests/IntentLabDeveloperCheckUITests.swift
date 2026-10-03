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
        app.radioButtons["Scenario"].click()

        let create = app.buttons["Create developer check"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        create.click()
        UITestStorage.selectPane("Intent & fixture", heading: "Scenario", in: app)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Rebuild and check support to load the app's actions"
        )).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Connect the app's developer runner"
        )).firstMatch.exists)
        XCTAssertFalse(app.textFields["Optional feature run UUID"].exists)
        XCTAssertFalse(app.textFields["Feature ID from the evaluation"].exists)

        UITestStorage.selectPane("Assertions", heading: "Scenario", in: app)
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
