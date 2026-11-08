import XCTest

final class MacIntentTestingUITests: XCTestCase {
    /// Keeps the expected-value editor visibly labeled after choosing a synthetic App Intent.
    @MainActor
    func testMacIntentTestingShowsInstalledAppAndExplicitCaseControls() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "mac-intent-testing")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["-appIntentTesting.mode", "direct", "--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1000", "--evaluation-window-height", "700"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        XCTAssertFalse(app.menuItems["Show Intent Lab"].exists)
        XCTAssertFalse(app.menuItems["Show App Automation"].exists)
        app.menuItems["Show App Intents"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sidebar app intents"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 1"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 2"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 3"].exists)
        XCTAssertTrue(app.staticTexts["Choose an app to inspect its actions and inputs."].exists)
        XCTAssertTrue(app.staticTexts["Choose an app to prepare a native test run."].exists)
        XCTAssertTrue(app.buttons["Choose built macOS app…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines.staticTexts["Intent Lab"].exists)
        XCTAssertFalse(app.outlines.staticTexts["App automation"].exists)
        let installationText = "Install and launch the app normally"
        let installationCopy = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                           installationText, installationText)
        XCTAssertTrue(app.staticTexts.matching(installationCopy).firstMatch.exists)
        let supported = app.disclosureTriangles["Supported inputs and results"]
        XCTAssertTrue(supported.exists)
        supported.click()
        let capabilityCopy = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                          "Compiled metadata discovery", "Compiled metadata discovery")
        XCTAssertTrue(app.staticTexts.matching(capabilityCopy).firstMatch.waitForExistence(timeout: 3))
        supported.click()

        // Read compiled metadata from a synthetic bundle. This does not install,
        // launch, sign, or dispatch the fixture through the native test runner.
        app.buttons["Choose built macOS app…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(fixture.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        let inputs = app.textViews["Inputs JSON"]
        XCTAssertTrue(inputs.waitForExistence(timeout: 5), app.debugDescription)
        let buildDetails = app.disclosureTriangles["Build details"]
        XCTAssertTrue(buildDetails.exists)
        buildDetails.click()
        let bundle = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                 "example.MacIntentUITestFixture", "example.MacIntentUITestFixture")
        XCTAssertTrue(app.staticTexts.matching(bundle).firstMatch.waitForExistence(timeout: 3))
        buildDetails.click()
        XCTAssertEqual(inputs.value as? String, "{}")
        XCTAssertFalse(app.textViews["Expected value JSON"].exists)
        let compare = app.switches["Compare returned value"]
        if !compare.exists {
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Missing compare control"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(compare.exists, app.debugDescription)
        compare.click()
        XCTAssertTrue(app.textViews["Expected value JSON"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Expected value JSON"].exists)
        XCTAssertEqual(app.textViews["Expected value JSON"].value as? String, "null")
        let advanced = app.disclosureTriangles["Advanced: build and signing"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["Developer directory"].exists)
        let page = app.scrollViews["App Intent steps"]
        XCTAssertTrue(page.waitForExistence(timeout: 3), app.debugDescription)
        let viewport = page.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 12)
        for _ in 0..<16 {
            if advanced.isHittable && viewport.contains(advanced.frame) { break }
            let delta: CGFloat = advanced.frame.minY < viewport.minY ? 180 : -180
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(advanced.isHittable && viewport.contains(advanced.frame), app.debugDescription)
        advanced.click()
        XCTAssertTrue(app.textFields["Developer directory"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.textFields["Signing identity"].exists)
        XCTAssertTrue(app.textFields["Team identifier"].exists)
        XCTAssertTrue(app.buttons["Run native test"].exists)
        XCTAssertFalse(app.buttons["Cancel"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Mac App Intent testing explicit case controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Saves a two-turn scenario, reopens the workspace, and keeps the direct mode accessible.
    @MainActor
    func testSiriStudioSavesAndReopensTwoTurnScenario() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-studio")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart",
                                "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        let newScenario = app.buttons["siri-studio-new-scenario"]
        XCTAssertTrue(newScenario.waitForExistence(timeout: 5), app.debugDescription)
        newScenario.click()
        try enter("Open the fixture.", in: "siri-studio-utterance-1", app: app)
        app.buttons["Add turn"].click()
        try enter("What is its status?", in: "siri-studio-utterance-2", app: app)
        app.buttons["Add reply check"].click()
        try enter("ready", in: "siri-studio-reply-check-0", app: app)
        app.buttons["Save"].click()
        let documentURL = storage.appending(path: "Workspace/SiriStudio/Scenarios/example.MacIntentUITestFixture.json")
        let bytes = try Data(contentsOf: documentURL)
        app.buttons["Save"].click()
        XCTAssertEqual(try Data(contentsOf: documentURL), bytes)

        app.terminate()
        app.launch()
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        let reopened = app.descendants(matching: .any)["siri-studio-utterance-2"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(reopened.value as? String, "What is its status?")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Siri Studio two-turn conversation"
        attachment.lifetime = .keepAlways
        add(attachment)
        chooseMode("Direct Action", in: app)
        XCTAssertTrue(app.textViews["Inputs JSON"].waitForExistence(timeout: 5))
    }

    /// Recovers unsaved authoring on relaunch and requires a choice before removing a turn's expectations.
    @MainActor
    func testSiriStudioRecoversUnsavedEditsAndConfirmsTurnRemoval() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-studio-recovery")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        app.buttons["siri-studio-new-scenario"].click()
        try enter("Open the fixture.", in: "siri-studio-utterance-1", app: app)
        app.buttons["Add turn"].click()
        try enter("Check its status.", in: "siri-studio-utterance-2", app: app)
        app.buttons["Add reply check"].click()
        try enter("ready", in: "siri-studio-reply-check-0", app: app)
        XCTAssertTrue(app.staticTexts["siri-studio-unsaved"].exists)
        let removals = app.buttons.matching(identifier: "Remove turn")
        XCTAssertEqual(removals.count, 2)
        removals.element(boundBy: 1).click()
        let confirmation = app.sheets.containing(.button, identifier: "Remove turn and expectations").firstMatch
        XCTAssertTrue(confirmation.buttons["Remove turn and expectations"].waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(app.descendants(matching: .any)["siri-studio-reply-check-0"].firstMatch.value as? String, "ready")
        app.terminate()
        app.launch()
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        let second = app.descendants(matching: .any)["siri-studio-utterance-2"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(second.value as? String, "Check its status.")
        app.buttons["Turn 2"].click()
        XCTAssertEqual(app.descendants(matching: .any)["siri-studio-reply-check-0"].firstMatch.value as? String, "ready")
        app.buttons.matching(identifier: "Remove turn").element(boundBy: 1).click()
        confirmation.buttons["Remove turn and expectations"].click()
        XCTAssertFalse(second.exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Siri Studio recovered authoring and confirmed turn removal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the app workspace and loads synthetic catalog metadata without executing an intent.
    @MainActor
    private func openWorkspace(in app: XCUIApplication, fixture: URL) throws {
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show App Intents"].click()
        let choose = app.buttons["Choose built macOS app…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(fixture.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
    }

    /// Selects a segment by its accessibility label.
    @MainActor
    private func chooseMode(_ label: String, in app: XCUIApplication) {
        let segment = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), app.debugDescription)
        segment.click()
    }

    /// Enters text using its control identifier across native text-field and text-view representations.
    @MainActor
    private func enter(_ text: String, in identifier: String, app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        field.typeText(text)
    }

    /// Creates an isolated catalog-only app bundle with no executable App Intent behavior.
    private func makeCatalogFixture(in directory: URL) throws -> URL {
        let app = directory.appending(path: "CatalogFixture.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let metadata = contents.appending(path: "Resources/Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "example.MacIntentUITestFixture", "CFBundlePackageType": "APPL",
                                   "CFBundleExecutable": "CatalogFixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Data("catalog-only fixture".utf8).write(to: contents.appending(path: "MacOS/CatalogFixture"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.appending(path: "MacOS/CatalogFixture").path)
        try Data(#"{"version":1,"actions":{"EchoIntent":{"identifier":"EchoIntent","title":{"key":"Echo"},"parameters":[]}}}"#.utf8)
            .write(to: metadata.appending(path: "extract.actionsdata"))
        return app
    }
}
