import XCTest

final class IntentLabFeatureGateUITests: XCTestCase {
    @MainActor func testDisabledReleaseExplainsIntentLabAndKeepsAutomation() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-lab-flag-off")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments = ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        app.menuBars.menuBarItems["Evaluation"].click()
        XCTAssertTrue(app.menuItems["Show Model Evaluations"].exists)
        XCTAssertTrue(app.menuItems["Show App Intents & Siri"].exists)
        app.typeKey(.escape, modifierFlags: [])
        try UITestStorage.openIntentLab(in: app)
        XCTAssertTrue(app.staticTexts["Intent Lab unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.radioButtons["Connect app"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Intent Lab unavailable explanation with flag off"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Choose app…"].waitForExistence(timeout: 5))
    }

    @MainActor func testExplicitTestDecisionEnablesIntentLab() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-lab-flag-on")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments = ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                               "--enable-intent-lab-for-testing"]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        try UITestStorage.openIntentLab(in: app)
        XCTAssertTrue(app.radioButtons["Connect app"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Intent Lab enabled by explicit test decision"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
