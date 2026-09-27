import XCTest

final class IntentLabGuidanceUITests: XCTestCase {
    @MainActor
    func testUnavailableSavedDestinationHasPickerLabel() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-missing-device")
        defer { try? FileManager.default.removeItem(at: storage) }
        let intentLab = storage.appendingPathComponent("IntentLab", isDirectory: true)
        try FileManager.default.createDirectory(at: intentLab, withIntermediateDirectories: true)
        let configuration: [String: Any] = [
            "containerPath": "", "isWorkspace": false, "scheme": "IntentLabFixture",
            "testTarget": "IntentLabFixtureUITests", "testBundleIdentifier": "com.coryparry.IntentLabFixtureUITests",
            "destinationIdentifier": "missing-device-for-ui-test", "generatedResourceDirectory": "",
            "configuration": "Debug", "xcodebuildPath": "/usr/bin/xcodebuild", "xcresulttoolPath": "/usr/bin/xcrun"
        ]
        try JSONSerialization.data(withJSONObject: configuration).write(
            to: intentLab.appendingPathComponent("execution-configuration.json")
        )

        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)

        let picker = app.popUpButtons["Run destination"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "Saved destination unavailable")
    }

    @MainActor
    func testGuidanceAndNavigationFitAvailableWindow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let storage = try UITestStorage.makeDirectory(prefix: "intent-guidance")
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        let width = window.frame.width
        XCTAssertGreaterThanOrEqual(width, 824, "Exercise available navigation width")

        app.radioButtons["Setup"].click()
        assertChromeFits(app, window: window)
        XCTAssertTrue(app.links["Apple’s guide to App Intents"].exists)
        app.radioButtons["Scenario"].click()
        assertChromeFits(app, window: window)
        XCTAssertTrue(app.textFields["Scenario name"].isHittable)

        selectPage("Parameters", app: app)
        XCTAssertTrue(app.buttons["Add parameter"].isHittable)
        if app.textFields.matching(identifier: "Parameter name").count == 0 { app.buttons["Add parameter"].click() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Missing leaves the input unset", "Missing leaves the input unset")).firstMatch.exists)
        assertChromeFits(app, window: window)
        capture(window, name: "Parameters at \(Int(width)) points")

        selectPage("Evidence", app: app)
        XCTAssertTrue(app.staticTexts["What should this test check?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "recognized text", "recognized text")).firstMatch.exists)
        assertChromeFits(app, window: window)

        selectPage("Run settings", app: app)
        let save = app.buttons["Freeze and save"]
        for _ in 0..<5 where !save.isHittable { app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp() }
        XCTAssertTrue(save.isHittable, "Long forms must scroll to their bottom controls")
        assertChromeFits(app, window: window)
        capture(window, name: "Scrolled settings at \(Int(width)) points")

        app.radioButtons["Results"].click()
        let disclosure = app.disclosureTriangles["What do the results mean?"]
        XCTAssertTrue(disclosure.isHittable)
        assertChromeFits(app, window: window)
        capture(window, name: "Results at \(Int(width)) points")
    }

    @MainActor
    private func selectPage(_ title: String, app: XCUIApplication) {
        UITestStorage.selectPane(title, heading: "Scenario", in: app)
    }

    @MainActor
    private func assertChromeFits(_ app: XCUIApplication, window: XCUIElement) {
        let title = app.staticTexts["Intent Lab page title"]
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThan(title.frame.minY, window.frame.minY + 45, "Header must stay below the toolbar")
        XCTAssertLessThan(title.frame.maxY, window.frame.minY + 145)
        XCTAssertTrue(app.radioButtons["Scenario"].isHittable)
        let status = app.descendants(matching: .any)["Workspace status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertLessThanOrEqual(status.frame.maxY, window.frame.maxY + 1, "Page content must not push the status bar below the window")
    }

    @MainActor
    private func capture(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let url = try? UITestStorage.screenshotURL(name: name.replacingOccurrences(of: " ", with: "-")) {
            try? window.screenshot().pngRepresentation.write(to: url)
        }
    }
}
