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
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
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
