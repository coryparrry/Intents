import XCTest

final class IntentLabArrayEntryUITests: XCTestCase {
    @MainActor
    func testNumericAndBooleanArraysAcceptIncrementalTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let storage = try UITestStorage.makeDirectory(prefix: "intent-arrays")
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        app.buttons["Scenario"].click()
        app.buttons["Parameters"].click()

        let parameterType = app.popUpButtons.matching(identifier: "Parameter type").firstMatch
        XCTAssertTrue(parameterType.waitForExistence(timeout: 5), app.debugDescription)
        parameterType.click()
        app.menuItems["Array"].click()

        let presence = app.popUpButtons.matching(identifier: "Parameter presence").firstMatch
        presence.click()
        app.menuItems["Set value"].click()

        let itemType = app.popUpButtons.matching(identifier: "Array item type").firstMatch
        XCTAssertTrue(itemType.waitForExistence(timeout: 5), app.debugDescription)
        itemType.click()
        app.menuItems["Integer"].click()

        let values = app.textFields["Comma-separated values"]
        XCTAssertTrue(values.waitForExistence(timeout: 5), app.debugDescription)
        values.click()
        values.typeText("1,")
        XCTAssertEqual(values.value as? String, "1,", "A partial second item must remain editable")
        values.typeText("2")
        XCTAssertEqual(values.value as? String, "1,2")

        itemType.click()
        app.menuItems["Boolean"].click()
        values.click()
        values.typeText("true,")
        XCTAssertEqual(values.value as? String, "true,", "A partial Boolean item must remain editable")
        values.typeText("false")
        XCTAssertEqual(values.value as? String, "true,false")
    }
}
