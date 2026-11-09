import XCTest

final class WorkspacePolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Offers a direct route to saved jobs from both batch evidence empty states.
    @MainActor
    func testBatchEmptyStatesOpenJobs() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "batch-empty-navigation")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        let batch = app.staticTexts["Sidebar batch runs"]
        XCTAssertTrue(batch.waitForExistence(timeout: 5))
        batch.click()
        let panes = app.radioGroups["Batch workspace"]
        for title in ["Results", "Reports"] {
            panes.radioButtons[title].click()
            let showJobs = app.buttons["Show Jobs"]
            XCTAssertTrue(showJobs.waitForExistence(timeout: 3))
            showJobs.click()
            XCTAssertTrue(app.staticTexts["Saved batches"].waitForExistence(timeout: 3))
        }
    }

    /// Worker scheduling stays discoverable while its setup is collapsed by default.
    @MainActor
    func testWorkersRevealSchedulingWhenNeeded() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "worker-options")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        app.staticTexts["Sidebar batch runs"].click()
        app.radioGroups["Batch workspace"].radioButtons["Workers"].click()
        let schedule = app.disclosureTriangles["Schedule a batch"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        let instruction = app.staticTexts["Select a batch in Jobs to schedule it."]
        XCTAssertFalse(instruction.exists)
        schedule.click()
        XCTAssertTrue(instruction.waitForExistence(timeout: 3))
        schedule.click()
        XCTAssertFalse(instruction.exists)
    }

    /// Waits for a completed captured batch before verifying cohort expansion, collapse, and search.
    @MainActor
    func testBatchReportExpandsAndSearchesCohorts() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "cohort-display")
        defer { try? FileManager.default.removeItem(at: storage) }
        let file = storage.appending(path: "cohort-fixture.jsonl")
        let rows = try (0..<12).map { index -> String in
            let example: [String: Any] = ["id": "case-\(index)", "prompt": "Question \(index)",
                "capturedOutput": "Answer \(index)", "metadata": ["task": String(format: "segment-%02d", index)]]
            return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: example), encoding: .utf8))
        }
        try rows.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        app.staticTexts["Sidebar batch runs"].click()
        let empty = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "No datasets yet")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "The test must use an empty isolated workspace")
        app.buttons["Import examples…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(file.path)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["OKButton"].click()
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == YES"), object: importButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        importButton.click()
        let options = app.menuButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Dataset options ")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.click()
        app.menuItems["Review captured outputs"].click()
        let run = app.buttons["Run on this Mac"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        // Completion removes the progress toolbar and repositions the pane picker.
        // Wait for durable results before XCTest resolves the Reports click location.
        let completed = app.staticTexts["12 of 12 saved · completed"].firstMatch
        try UITestStorage.waitFor(completed, in: app, timeout: 20)
        app.radioGroups["Batch workspace"].radioButtons["Reports"].click()
        let more = app.buttons["Show more cohorts"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        let target = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "task=segment-11", "task=segment-11")).firstMatch
        XCTAssertFalse(target.exists)
        more.click()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        app.buttons["Show fewer cohorts"].click()
        XCTAssertFalse(target.exists)
        let search = app.textFields["Search batch cohorts"]
        search.click()
        search.typeText("segment-11")
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        let screenshot = try UITestStorage.screenshotURL(name: "batch-cohort-search")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: screenshot)
    }

    /// Settings keep primary controls and the optional request policy accessible.
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
                let requestPolicy = app.buttons["Judge request policy"]
                XCTAssertTrue(requestPolicy.exists)
                XCTAssertFalse(app.popUpButtons["Judge generation policy"].exists)
                let form = app.scrollViews.containing(.textField, identifier: "Judge connection name").firstMatch
                XCTAssertTrue(form.waitForExistence(timeout: 3))
                let scroll = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.20))
                scroll.scroll(byDeltaX: 0, deltaY: -400)
                XCTAssertTrue(requestPolicy.isHittable && form.frame.contains(requestPolicy.frame), app.debugDescription)
                requestPolicy.click()
                scroll.scroll(byDeltaX: 0, deltaY: -250)
                let generationPolicy = app.popUpButtons["Judge generation policy"]
                XCTAssertTrue(generationPolicy.waitForExistence(timeout: 3), app.debugDescription)
                XCTAssertTrue(generationPolicy.isHittable && form.frame.contains(generationPolicy.frame), app.debugDescription)
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
        app.typeKey("3", modifierFlags: .command)
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
    /// Archived suites remain discoverable and can be restored without recreating their identity.
    @MainActor
    func testManagerRestoresArchivedSuite() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "archive-restore")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        let chooser = app.menuButtons.matching(identifier: "Choose project").firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        chooser.click()
        app.menuItems["Manage projects…"].click()
        app.buttons["New suite"].click()
        let names = app.textFields.matching(identifier: "Suite name")
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 3))
        let name = try XCTUnwrap(names.allElementsBoundByIndex.last)
        name.click(); name.typeText("Archive recovery fixture")
        app.buttons["Create suite"].click()
        let suiteActions = app.menuButtons["Suite actions"]
        XCTAssertTrue(suiteActions.waitForExistence(timeout: 3))
        suiteActions.click()
        app.menuItems["Archive suite"].click()
        let disclosure = app.disclosureTriangles["Archived projects and suites"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        // SwiftUI's accessibility frame precedes the visible chevron by the manager's 24-point inset.
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 24, dy: 0)).click()
        XCTAssertEqual((disclosure.value as? NSNumber)?.intValue, 1)
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Restore suite ")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        let restoreID = restore.identifier
        let screenshot = try UITestStorage.screenshotURL(name: "archive-recovery-manager")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: screenshot)
        restore.click()
        XCTAssertFalse(app.buttons[restoreID].exists)
        XCTAssertTrue(app.staticTexts["Archive recovery fixture"].exists)
    }

    /// A capacity-limited import requires a deliberate partial choice and offers a full import into an empty suite.
    @MainActor
    func testImportDisclosesOmissionsAndOffersBlankDestination() throws {
        try verifyImportContinuation(fromEvaluations: false)
    }

    /// Switching the import destination also preserves a sheet opened from Evaluations' Cases page.
    @MainActor
    func testImportContinuationPreservesEvaluationsHost() throws {
        try verifyImportContinuation(fromEvaluations: true)
    }

    /// Runs partial-import confirmation and empty-destination continuation in either editor navigation branch.
    @MainActor
    private func verifyImportContinuation(fromEvaluations: Bool) throws {
        let storage = try UITestStorage.makeDirectory(prefix: "import-capacity")
        defer { try? FileManager.default.removeItem(at: storage) }
        let csv = storage.appending(path: "complete-dataset.csv")
        let rows = (1...100).map { "Case \($0),Prompt \($0),Expected \($0)" }.joined(separator: "\n")
        try ("name,prompt,expected\n" + rows).write(to: csv, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        if fromEvaluations {
            app.staticTexts["Sidebar evaluations"].click()
            let cases = app.radioGroups["Editor page"].radioButtons["Cases"]
            XCTAssertTrue(cases.waitForExistence(timeout: 3))
            cases.click()
        }
        app.buttons["Import Cases"].click()
        let importer = app.sheets.firstMatch
        XCTAssertTrue(importer.waitForExistence(timeout: 5), app.debugDescription)
        let chooseFile = importer.buttons["Choose File…"]
        XCTAssertTrue(chooseFile.waitForExistence(timeout: 5), app.debugDescription)
        chooseFile.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 3))
        path.typeText(csv.path)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["OKButton"].click()
        let partial = app.buttons["Import 99 Cases"]
        XCTAssertTrue(partial.waitForExistence(timeout: 5))
        XCTAssertFalse(partial.isEnabled)
        XCTAssertTrue(app.staticTexts["100 valid source rows · 99 fit · 1 omitted"].exists)
        let choice = app.checkBoxes["Import only the first 99 rows"]
        XCTAssertTrue(choice.exists)
        choice.click()
        XCTAssertTrue(partial.isEnabled)
        choice.click()
        XCTAssertFalse(partial.isEnabled)
        app.buttons["Use a new blank suite for this file"].click()
        let full = importer.buttons["Import 100 Cases"]
        XCTAssertTrue(full.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(full.isEnabled)
        XCTAssertTrue(app.staticTexts["100 valid source rows · 100 fit · 0 omitted"].exists)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: UITestStorage.screenshotURL(name: "complete-import-destination"))
        full.click()
        XCTAssertTrue(app.buttons["Import Cases"].waitForExistence(timeout: 5))
    }

}
