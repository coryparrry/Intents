import Foundation
import XCTest

final class EvaluationReviewUITests: XCTestCase {
    @MainActor
    func testBlindReviewPersistsAndPromotesRegression() throws {
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        openReview(app)
        let note = app.textViews["Review note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Automated judgment: unscored"].exists)
        reveal(app.popUpButtons["Human verdict"], in: app)
        app.popUpButtons["Human verdict"].click()
        app.menuItems["Failed"].click()
        reveal(note, in: app)
        note.click(); note.typeText("The meeting date is incorrect.")
        reveal(app.textFields["Review tags"], in: app)
        app.textFields["Review tags"].click(); app.textFields["Review tags"].typeText("wrong date")
        reveal(app.buttons["Save review"], in: app)
        app.buttons["Save review"].click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        app.terminate(); launchWorkspace(app); openReview(app)
        XCTAssertEqual(app.textViews["Review note"].value as? String, "The meeting date is incorrect.")
        reveal(app.buttons["Create regression case"], in: app)
        app.buttons["Create regression case"].click()
        let expected = app.sheets.textViews["Regression expected answer"]
        XCTAssertTrue(expected.waitForExistence(timeout: 3))
        XCTAssertEqual(expected.value as? String, "")
        expected.click(); expected.typeText("Friday")
        app.sheets.buttons["Create case"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Regression: Meeting date")).firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testDraftNavigationPatternsAndNarrowReviewLayout() throws {
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        openReview(app)
        let note = app.textViews["Review note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        reveal(note, in: app)
        note.click(); note.typeText("The meeting date is incorrect.")
        app.radioGroups["Editor page"].radioButtons["Setup"].click()
        app.radioGroups["Editor page"].radioButtons["Review"].click()
        XCTAssertEqual(app.textViews["Review note"].value as? String, "The meeting date is incorrect.")
        reveal(app.popUpButtons["Human verdict"], in: app)
        app.popUpButtons["Human verdict"].click(); app.menuItems["Failed"].click()
        reveal(app.textFields["Review tags"], in: app)
        app.textFields["Review tags"].click(); app.textFields["Review tags"].typeText("wrong date")
        reveal(app.buttons["Save review"], in: app)
        app.buttons["Save review"].click()
        choosePane("Patterns", app: app)
        XCTAssertTrue(app.staticTexts["wrong date"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 reviewed example · 1 unique case"].exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Meeting date")).firstMatch.click()
        XCTAssertTrue(app.textViews["Review note"].waitForExistence(timeout: 3))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = corner.withOffset(CGVector(dx: 1000 - window.frame.width, dy: 0))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertLessThanOrEqual(window.frame.width, 1050, "Resize must actually exercise the narrow layout")
        XCTAssertTrue(app.popUpButtons["Review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save review"].exists)
        choosePane("Patterns", app: app)
        XCTAssertTrue(app.staticTexts["wrong date"].waitForExistence(timeout: 3))
        try window.screenshot().pngRepresentation.write(to: UITestStorage.screenshotURL(name: "eval-review-narrow"))
    }

    @MainActor
    func testSidebarEvaluationsAndTracesOpenSavedEvidence() throws {
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        openReview(app)
        XCTAssertTrue(app.textViews["Review note"].waitForExistence(timeout: 5))
        sidebarDestination("Sidebar traces", in: app).click()
        XCTAssertTrue(app.staticTexts["Saved traces"].waitForExistence(timeout: 3), app.debugDescription)
        let trace = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Open saved trace ")).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 3))
        trace.click()
        let workflow = app.radioGroups["Run view"].radioButtons["Workflow trace"]
        XCTAssertTrue(workflow.waitForExistence(timeout: 3), app.debugDescription)
        workflow.click()
        XCTAssertTrue(app.popUpButtons["Trace case"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue((app.popUpButtons["Trace case"].value as? String)?.contains("Meeting date") == true)
        openReview(app)
        XCTAssertTrue(app.textViews["Review note"].waitForExistence(timeout: 3))
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: UITestStorage.screenshotURL(name: "eval-sidebar"))
    }

    @MainActor
    func testSidebarDestinationsHandleNoSavedRuns() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "eval-sidebar-empty")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        sidebarDestination("Sidebar traces", in: app).click()
        XCTAssertTrue(emptyState("No saved traces yet", in: app).waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Open evaluations"].click()
        XCTAssertTrue(emptyState("Choose a saved output", in: app).waitForExistence(timeout: 3))
        assertReviewSelected(in: app)
    }

    @MainActor private func launchWorkspace(_ app: XCUIApplication) {
        app.launch()
        // Hosted XCTest can launch only the menu bar until the editor command runs.
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "The editor command must present the main window")
    }

    @MainActor private func choosePane(_ title: String, app: XCUIApplication) {
        let picker = app.popUpButtons["Review"]
        if picker.exists {
            reveal(picker, in: app)
            picker.click(); app.menuItems[title].click()
        } else {
            reveal(app.buttons[title], in: app)
            app.buttons[title].click()
        }
    }

    @MainActor private func sidebarDestination(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts[identifier]
    }

    @MainActor private func openReview(_ app: XCUIApplication) {
        let destination = sidebarDestination("Sidebar evaluations", in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
        destination.click()
        assertReviewSelected(in: app)
    }

    @MainActor private func assertReviewSelected(in app: XCUIApplication) {
        let review = app.radioGroups["Editor page"].radioButtons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        // Native segmented controls expose numeric AX values on the hosted Mac.
        XCTAssertTrue(review.isSelected || (review.value as? NSNumber)?.intValue == 1
                      || (review.value as? String) == "1", "The Review editor page must be selected")
    }

    @MainActor private func emptyState(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // The empty-state title and explanation share one combined AX static text.
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", title)).firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let page = app.scrollViews["Suite editor scroll"]
        XCTAssertTrue(page.exists)
        let initialFrame = element.frame
        for _ in 0..<16 {
            let viewport = page.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 12)
            let target = element.frame
            if element.isHittable && viewport.contains(target) { return }
            let delta: CGFloat = target.minY < viewport.minY ? 180 : -180
            // The page center overlaps nested sample-list and text-editor scroll views.
            // Send the wheel through its outer padding so only the page receives it.
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(element.isHittable && page.frame.intersection(app.windows.firstMatch.frame).contains(element.frame),
                      "The review control must be visible inside the outer editor scroll view: \(element); initial: \(initialFrame), final: \(element.frame), page: \(page.frame)")
    }

    @MainActor private func application(storage: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                               "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"]
        return app
    }
    private func reviewStorage() throws -> URL {
        let storage = try UITestStorage.makeDirectory(prefix: "eval-review")
        let fixtureURL = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/Review/review-fixture.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let suite = fixture["suite"] as! [String: Any]
        let run = fixture["run"] as! [String: Any]
        try JSONSerialization.data(withJSONObject: suite).write(to: storage.appending(path: "suite.json"))
        let runs = storage.appending(path: "Runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: run).write(to: runs.appending(path: "\(run["id"] as! String).json"))
        return storage
    }
}
