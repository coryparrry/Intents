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
    func testGuidanceAndNavigationFitWideWindow() throws {
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

        app.radioButtons["Connect app"].click()
        assertChromeFits(app, window: window)
        XCTAssertTrue(app.buttons["Choose Project…"].isHittable)
        XCTAssertFalse(app.textFields["AppUITests"].exists, "Technical fields start collapsed")
        app.disclosureTriangles["About App Intents"].click()
        XCTAssertTrue(app.links["Apple’s guide to App Intents"].waitForExistence(timeout: 3))
        capture(window, name: "Connect app")

        app.buttons["Create test"].click()
        assertChromeFits(app, window: window)
        XCTAssertTrue(app.textFields["Test name"].isHittable)
        XCTAssertTrue(app.buttons["Save test"].isHittable, "Save is available beside the test")
        XCTAssertFalse(app.textFields["Stable fixture digest"].exists, "Implementation details start collapsed")
        XCTAssertTrue(app.staticTexts["What should this test check?"].exists)
        capture(window, name: "Create test")

        let inputs = app.disclosureTriangles.matching(NSPredicate(format: "label BEGINSWITH %@", "Inputs ·")).firstMatch
        reveal(inputs, app: app)
        inputs.click()
        let add = app.buttons["Add parameter"]
        reveal(add, app: app)
        XCTAssertTrue(add.isHittable)
        assertChromeFits(app, window: window)

        app.radioButtons["Results"].click()
        XCTAssertTrue(app.staticTexts["No results yet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.disclosureTriangles["What do the results mean?"].isHittable)
        app.buttons["Connect app"].click()
        XCTAssertTrue(app.buttons["Choose Project…"].isHittable, "Empty results link returns to setup")
        assertChromeFits(app, window: window)
    }

    @MainActor
    func testNewTestRemainsAvailableAndCancelKeepsDraft() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "intent-new-test")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Create test"].click()
        let name = app.textFields["Test name"]
        let original = name.value as? String
        app.buttons["New test"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.waitForExistence(timeout: 3))
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(name.value as? String, original)
        app.buttons["New test"].click()
        app.buttons["Discard draft and continue"].click()
        XCTAssertEqual(name.value as? String, "New intent check")
        XCTAssertTrue(app.buttons["New test"].isHittable, "A reusable test must not hide New test")
        app.buttons["New test"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.waitForExistence(timeout: 3))
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(name.value as? String, "New intent check")
    }

    @MainActor
    func testNewDeveloperCheckShowsGuidedControls() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "intent-guided-check")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Create test"].click()
        app.buttons["New test"].click()
        if app.sheets.buttons["Discard draft and continue"].waitForExistence(timeout: 2) {
            app.sheets.buttons["Discard draft and continue"].click()
        }

        XCTAssertTrue(app.popUpButtons["Declared app action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.popUpButtons["Declared app feature"].exists)
        XCTAssertFalse(app.textFields["OpenNoteIntent"].exists, "Stable checks select the compiled action")
        XCTAssertTrue(app.staticTexts["Rebuild and check support to choose an observable result."].exists)
        XCTAssertFalse(app.textFields["Optional feature run UUID"].exists)
        capture(app.windows.firstMatch, name: "Guided developer check")
    }

    @MainActor
    func testChoosingProjectOffersConnectionAndCancelDoesNotApprove() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-connect-project")
        defer { try? FileManager.default.removeItem(at: storage) }
        let project = storage.appendingPathComponent("Preview.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Choose Project…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Check project…"].exists)
        app.buttons["Choose Project…"].click()
        XCTAssertTrue(app.sheets["open-panel"].waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 3))
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(project.path)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["OKButton"].click()
        let connect = app.sheets.buttons["Connect app"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "Choosing the file should offer connection immediately")
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.buttons["Connect app…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Project connected"].exists)
        XCTAssertFalse(app.buttons["Run test"].isEnabled)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable {
            app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
        }
    }

    @MainActor
    private func assertChromeFits(_ app: XCUIApplication, window: XCUIElement) {
        let title = app.staticTexts["Intent Lab page title"]
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThan(title.frame.minY, window.frame.minY + 45, "Header must stay below the toolbar")
        XCTAssertLessThan(title.frame.maxY, window.frame.minY + 145)
        XCTAssertTrue(app.radioButtons["Create test"].isHittable)
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
