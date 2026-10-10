import XCTest

final class WorkspacePolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSettingsTabsKeepTheirPrimaryControlsAccessible() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "settings-polish")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        for page in ["MCP Connector", "Judges", "Privacy"] {
            let tab = app.buttons[page]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.click()
            let screenshotURL = try UITestStorage.screenshotURL(
                name: "settings-\(page.lowercased().replacingOccurrences(of: " ", with: "-"))")
            try app.windows.firstMatch.screenshot().pngRepresentation.write(to: screenshotURL)
            try app.debugDescription.write(to: screenshotURL.deletingPathExtension().appendingPathExtension("txt"),
                                           atomically: true, encoding: .utf8)
            switch page {
            case "MCP Connector":
                XCTAssertTrue(app.buttons["Codex install or update"].isHittable)
            case "Judges":
                let name = app.textFields["Judge connection name"]
                XCTAssertTrue(name.isHittable)
                XCTAssertEqual(name.label, "Connection name")
                XCTAssertTrue(app.buttons["Save"].exists)
            default:
                XCTAssertTrue(app.descendants(matching: .any)["Share usage statistics"].firstMatch.exists)
            }
        }
    }

    @MainActor
    func testImportIssuesKeepCancelAndImportVisible() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "import-polish")
        defer { try? FileManager.default.removeItem(at: storage) }
        let csv = storage.appending(path: "invalid-cases.csv")
        let rows = (1...30).map { "Case \($0),,Expected" }.joined(separator: "\n")
        try ("name,prompt,expected\n" + rows).write(to: csv, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1000", "--evaluation-window-height", "700"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("1", modifierFlags: .command)
        let importCases = app.buttons["Import Cases"]
        XCTAssertTrue(importCases.waitForExistence(timeout: 5))
        XCTAssertTrue(importCases.isHittable)
        importCases.click()
        app.buttons["Choose File…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 3))
        path.typeText(csv.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.buttons["OKButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.click()

        let issue = app.staticTexts["Line 2: The mapped prompt value is empty."]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        let submit = app.buttons["Import 0 Cases"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled)
        XCTAssertLessThanOrEqual(submit.frame.maxY, app.windows.firstMatch.frame.maxY)
        let preview = app.scrollViews["Case import preview"]
        preview.scroll(byDeltaX: 0, deltaY: -1400)
        XCTAssertTrue(cancel.isHittable, "Validation messages must scroll independently of the action bar")
        XCTAssertLessThanOrEqual(submit.frame.maxY, app.windows.firstMatch.frame.maxY)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Import validation with persistent actions"
        shot.lifetime = .keepAlways
        add(shot)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: UITestStorage.screenshotURL(name: "import-validation-actions"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(importCases.waitForExistence(timeout: 3))
    }
}
