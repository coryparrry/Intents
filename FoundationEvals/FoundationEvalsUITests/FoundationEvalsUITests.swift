import XCTest

final class FoundationEvalsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDebugAppDoesNotOfferSelfUpdates() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let appMenu = app.menuBars.menuBarItems["Intents"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        XCTAssertTrue(app.menuItems["About Intents"].waitForExistence(timeout: 5),
                      "The app menu must be open before checking its update commands")
        XCTAssertFalse(app.menuItems["Check for Updates…"].exists,
                       "Debug verification must not start or expose the release updater")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testIntentLabOpensWithScenarioAndConnectionControls() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts["Intent Lab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect an app"].exists)
        XCTAssertTrue(app.buttons["Choose Project…"].exists)

        app.radioButtons["Create test"].click()
        XCTAssertTrue(app.staticTexts["What should happen?"].exists)
        XCTAssertTrue(app.buttons["Run test"].exists)

        app.radioButtons["Results"].click()
        XCTAssertTrue(app.staticTexts["No results yet"].waitForExistence(timeout: 3))
        let title = app.staticTexts["Intent Lab page title"]
        XCTAssertGreaterThan(title.frame.minY - app.windows.firstMatch.frame.minY, 45,
                             "The page header must remain below the window toolbar")
        XCTAssertLessThan(title.frame.minY - app.windows.firstMatch.frame.minY, 120,
                          "Results must keep the page header at the top of the window")
        XCTAssertLessThan(app.staticTexts["No results yet"].frame.minY - title.frame.minY, 180,
                          "The empty state must sit directly beneath page navigation")
        let resultsAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        resultsAttachment.name = "Intent Lab results"
        resultsAttachment.lifetime = .keepAlways
        add(resultsAttachment)
        app.radioButtons["Create test"].click()

        XCTAssertTrue(app.textFields["Test name"].isHittable)
        XCTAssertTrue(app.buttons["Run test"].isHittable)

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Intent Lab initial state"
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(
            to: FileManager.default.temporaryDirectory.appending(path: "foundation-evals-intent-lab.png"),
            options: .atomic
        )
    }

    @MainActor
    func testDuplicateParameterDraftsRemoveOneAtATime() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Create test"].click()
        let window = app.windows.firstMatch
        let editor = app.scrollViews["Intent Lab scenario scroll"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 3))
            for _ in 0..<12 {
                let viewport = editor.frame.intersection(window.frame)
                if element.isHittable && viewport.contains(element.frame) { return }
                // macOS swipes can jump past a control; wheel steps can recover in either direction.
                let delta: CGFloat = element.frame.minY < viewport.minY ? 180 : -180
                editor.scroll(byDeltaX: 0, deltaY: delta)
            }
            let viewport = editor.frame.intersection(window.frame)
            XCTAssertTrue(element.isHittable && viewport.contains(element.frame),
                          "Parameter control \(element.frame) must be visible inside editor \(viewport) before clicking")
        }
        let inputs = app.disclosureTriangles.matching(NSPredicate(format: "label BEGINSWITH %@", "Inputs ·")).firstMatch
        reveal(inputs)
        inputs.click()

        let names = app.textFields.matching(identifier: "Parameter name")
        XCTAssertEqual(names.count, 1)
        let addButton = app.buttons["Add parameter"]
        for expectedCount in 2...3 {
            reveal(addButton)
            addButton.click()
            XCTAssertTrue(names.element(boundBy: expectedCount - 1).waitForExistence(timeout: 3))
            XCTAssertEqual(names.count, expectedCount)
        }

        let remove = app.buttons.matching(identifier: "Remove parameter")
        XCTAssertEqual(remove.count, 3)
        let thirdRemove = remove.element(boundBy: 2)
        reveal(thirdRemove)
        thirdRemove.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in names.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        XCTAssertEqual(names.count, 2)

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Intent Lab parameter rows after removal"
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(
            to: FileManager.default.temporaryDirectory.appending(path: "foundation-evals-parameter-rows.png"),
            options: .atomic
        )
    }

    @MainActor
    func testRunCommandsMatchInvalidSuiteControls() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        let prompt = app.textViews["Case prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertEqual(prompt.value as? String, "", "The edit must clear the case prompt")
        // Prompt edits reach suite validation after the debounced save.
        let runDisabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"),
            object: app.buttons["Run evaluation"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [runDisabled], timeout: 3), .completed)

        app.menuBars.menuBarItems["Evaluation"].click()
        XCTAssertFalse(app.menuItems["Run Evaluation"].isEnabled)
        XCTAssertFalse(app.menuItems["Cancel Run"].isEnabled)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(to: FileManager.default.temporaryDirectory
            .appending(path: "foundation-evals-shortcut-menu.png"), options: .atomic)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    @MainActor
    func testSuiteEditorShowsPrimaryRunControls() throws {
        let app = verificationApplication()
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
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "The editor command must present the main window")
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 2))
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "The editor command must recover a closed main window")
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Case"].exists)
        XCTAssertTrue(app.buttons["Add Case"].isHittable)
        XCTAssertTrue(app.buttons["This Mac"].exists)

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
            app.radioButtons["Cases"].click()
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
        let app = verificationApplication()
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
        app.activate()
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5))

        app.radioButtons["Setup"].click()

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
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 5))

        addCaseToVisibleList(in: app)
        let caseName = app.textFields["Case name"]
        XCTAssertTrue(caseName.waitForExistence(timeout: 2))
        caseName.click()
        app.typeKey("a", modifierFlags: .command)
        caseName.typeText("Selection regression case")

        selectSetup("Scoring", in: app)
        app.radioButtons["Cases"].click()
        XCTAssertEqual(caseName.value as? String, "Selection regression case")

        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "Select case ", "Example"
        )).firstMatch.click()
        XCTAssertEqual(caseName.value as? String, "Example")
        selectSetup("Scoring", in: app)
        app.radioButtons["Cases"].click()
        XCTAssertEqual(caseName.value as? String, "Example")

    }

    @MainActor
    func testSameNamedCasesHaveDistinctAccessibilityLabels() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 5))

        addCaseToVisibleList(in: app)
        let name = app.textFields["Case name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Example")

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Select case "))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Example"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("Example"))
        XCTAssertNotEqual(rows.element(boundBy: 0).label, rows.element(boundBy: 1).label)
    }

    @MainActor
    func testCaseSearchKeepsEditorAndScoringSelectionAligned() throws {
        let app = verificationApplication()
        let storageName = UUID().uuidString
        let storage = uiTestStorage(name: storageName)
        defer { try? FileManager.default.removeItem(at: storage) }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 5))
        addCaseToVisibleList(in: app)
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
        app.radioButtons["Cases"].click()
        XCTAssertEqual(name.value as? String, "Renamed case")

        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText("No matching case 582")
        XCTAssertTrue(app.staticTexts["No matching cases"].exists)
        XCTAssertFalse(name.exists, "An invisible case must not remain editable")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: UITestStorage.screenshotURL(name: "empty-case-search"))
        XCTAssertLessThanOrEqual(app.buttons["Add Case"].frame.maxY, app.windows.firstMatch.frame.maxY,
                                 "Empty search results must keep the case actions inside the window")
        app.buttons["Add Case"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        XCTAssertEqual(search.value as? String, "", "Selecting a new case clears an incompatible search")
        XCTAssertLessThanOrEqual(app.buttons["Add Case"].frame.maxY, app.windows.firstMatch.frame.maxY)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: UITestStorage.screenshotURL(name: "case-search-recovered"))
    }

    @MainActor
    private func selectSetup(_ title: String, in app: XCUIApplication) {
        app.radioButtons["Setup"].click()
        let menu = app.popUpButtons["Suite setup"]
        if menu.exists {
            menu.click()
            app.menuItems[title].click()
        } else {
            app.buttons[title].click()
        }
    }

    @MainActor
    private func addCaseToVisibleList(in app: XCUIApplication) {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Select case "))
        let previousCount = rows.count
        let add = app.buttons["Add Case"]
        app.activate()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in add.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                       "The case action must be reachable before clicking")
        add.click()
        let added = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in rows.count == previousCount + 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 5), .completed,
                       "Adding a case must create a row before its editor is changed")
    }

    @MainActor
    private func verificationApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--evaluation-window-width", "1000", "--evaluation-window-height", "700"]
        return app
    }

    private func uiTestStorage(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/FoundationEvalsUITests", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

}
