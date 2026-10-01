import XCTest

final class FoundationEvalsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSuiteEditorShowsPrimaryRunControls() throws {
        let app = XCUIApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += [
            "--disable-mcp-autostart",
            "--evaluation-storage-name", storageName
        ]
        app.launch()
        defer { app.terminate() }

        // XCTest launches with LSLaunchDoNotBringFrontmost and can create only the menu bar.
        // Exercise the user-facing editor command; normal launch is checked separately in the app.
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "The editor command must present the main window")
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 2))
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "The editor command must recover a closed main window")
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Case"].exists)
        XCTAssertTrue(app.buttons["Add Case"].isHittable)
        XCTAssertTrue(app.buttons["Run destination"].exists)

        selectSetup("Instructions", in: app)
        XCTAssertTrue(app.textViews["Model instructions"].exists)
        XCTAssertFalse(app.buttons["Add Files"].exists)
        let referenceFiles = app.disclosureTriangles
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Reference files"))
            .firstMatch
        referenceFiles.click()
        let addFiles = app.buttons["Add Files"]
        if !addFiles.waitForExistence(timeout: 2) {
            referenceFiles.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 27, dy: 0)).click()
        }
        XCTAssertTrue(addFiles.waitForExistence(timeout: 3))

        selectSetup("Model", in: app)
        XCTAssertTrue(app.popUpButtons["Model provider"].exists)
        XCTAssertTrue(app.popUpButtons["Sampling"].exists)
        XCTAssertFalse(app.popUpButtons["System model use case"].exists)
        let advancedOptions = app.disclosureTriangles["Advanced model options"]
        advancedOptions.click() // Let XCTest scroll the disclosure's enclosing editor into view.
        let useCase = app.popUpButtons["System model use case"]
        if !useCase.waitForExistence(timeout: 2) {
            // The recorded AX frame includes leading padding: its chevron is 27pt
            // from the left edge, while XCTest's default click lands on the label.
            advancedOptions.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 27, dy: 0)).click()
        }
        XCTAssertTrue(useCase.waitForExistence(timeout: 3))
        XCTAssertTrue(app.popUpButtons["System model guardrails"].exists)

        selectSetup("Scoring", in: app)
        XCTAssertTrue(app.staticTexts["Scoring and repetitions"].exists)
        XCTAssertTrue(app.radioButtons["AI rubric"].exists)

        for (mode, expectedCount) in [("Collect only", 0), ("Exact text", 1), ("Contains text", 1), ("AI rubric", 1)] {
            selectSetup("Scoring", in: app)
            app.radioButtons[mode].click()
            app.buttons["Cases"].click()
            XCTAssertTrue(app.textViews["Case prompt"].exists)
            XCTAssertEqual(app.textViews.matching(identifier: "Scoring expected text").count, expectedCount)
        }

        selectSetup("Tools", in: app)
        XCTAssertTrue(app.buttons["Add Tool"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Sample"].exists)

        selectSetup("Structured output", in: app)
        XCTAssertTrue(app.buttons["Add Field"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Definition"].exists)

        selectSetup("Session profile", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["Use an evaluation profile"].waitForExistence(timeout: 3))

        selectSetup("Performance", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["Prewarm the model before each sample"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["Stream the response"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Refined suite editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSetupPagesRenderInDarkAppearance() throws {
        let app = XCUIApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += [
            "--disable-mcp-autostart",
            "--evaluation-storage-name", storageName,
            "-AppleInterfaceStyle", "Dark",
            "-AppleInterfaceStyleSwitchesAutomatically", "NO"
        ]
        app.launch()
        defer { app.terminate() }

        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))

        app.buttons["Setup"].click()

        for title in ["Scoring", "Tools", "Structured output", "Session profile", "Performance"] {
            selectSetup(title, in: app)
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 3), "Missing setup page: \(title)")
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Dark setup - \(title)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try screenshot.pngRepresentation.write(
                to: UITestStorage.screenshotURL(
                    name: "pr47-dark-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
                ),
                options: .atomic
            )
        }
    }

    @MainActor
    func testCaseSelectionSurvivesSetupNavigation() throws {
        let app = XCUIApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 5))

        app.buttons["Add Case"].click()
        let caseName = app.textFields["Case name"]
        XCTAssertTrue(caseName.waitForExistence(timeout: 2))
        caseName.click()
        app.typeKey("a", modifierFlags: .command)
        caseName.typeText("Selection regression case")

        selectSetup("Scoring", in: app)
        app.buttons["Cases"].click()
        XCTAssertEqual(caseName.value as? String, "Selection regression case")

        app.buttons["Example"].click()
        XCTAssertEqual(caseName.value as? String, "Example")
        selectSetup("Scoring", in: app)
        app.buttons["Cases"].click()
        XCTAssertEqual(caseName.value as? String, "Example")

    }

    @MainActor
    func testCaseSearchKeepsEditorAndScoringSelectionAligned() throws {
        let app = XCUIApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 5))
        app.buttons["Add Case"].click()
        let name = app.textFields["Case name"]
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Search target")

        let search = app.textFields["Search cases"]
        search.click()
        search.typeText("Example")
        XCTAssertEqual(name.value as? String, "Example")
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Renamed case")
        XCTAssertEqual(search.value as? String, "", "Editing out of a search preserves the visible editor")
        selectSetup("Scoring", in: app)
        app.buttons["Cases"].click()
        XCTAssertEqual(name.value as? String, "Renamed case")

        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("No matching case 582")
        XCTAssertTrue(app.staticTexts["No matching cases"].exists)
        XCTAssertFalse(name.exists, "An invisible case must not remain editable")
        app.buttons["Add Case"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        XCTAssertEqual(search.value as? String, "", "Selecting a new case clears an incompatible search")
    }

    @MainActor
    private func selectSetup(_ title: String, in app: XCUIApplication) {
        app.buttons["Setup"].click()
        let menu = app.popUpButtons["Suite setup"]
        if menu.exists {
            menu.click()
            app.menuItems[title].click()
        } else {
            app.buttons[title].click()
        }
    }

    private func uiTestStorage(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/FoundationEvalsUITests", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

}
