import Foundation
import XCTest

final class EvaluationReviewUITests: XCTestCase {
    @MainActor
    func testBlindReviewPersistsAndPromotesRegression() throws {
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        app.launch()
        defer { app.terminate() }
        openReview(app)
        let note = app.textViews["Review note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Automated judgment: unscored"].exists)
        app.popUpButtons["Human verdict"].click()
        app.menuItems["Failed"].click()
        note.click(); note.typeText("The meeting date is incorrect.")
        app.textFields["Review tags"].click(); app.textFields["Review tags"].typeText("wrong date")
        app.buttons["Save review"].click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        app.terminate(); app.launch(); openReview(app)
        XCTAssertEqual(app.textViews["Review note"].value as? String, "The meeting date is incorrect.")
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
        app.launch()
        defer { app.terminate() }
        openReview(app)
        let note = app.textViews["Review note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.click(); note.typeText("The meeting date is incorrect.")
        app.radioButtons["Setup"].click()
        app.radioButtons["Review"].click()
        XCTAssertEqual(app.textViews["Review note"].value as? String, "The meeting date is incorrect.")
        app.popUpButtons["Human verdict"].click(); app.menuItems["Failed"].click()
        app.textFields["Review tags"].click(); app.textFields["Review tags"].typeText("wrong date")
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
        app.launch()
        defer { app.terminate() }
        openReview(app)
        XCTAssertTrue(app.textViews["Review note"].waitForExistence(timeout: 5))
        sidebarDestination("Traces", in: app).click()
        XCTAssertTrue(app.staticTexts["Saved traces"].waitForExistence(timeout: 3), app.debugDescription)
        let trace = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Open saved trace ")).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 3))
        trace.click()
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
        app.launch()
        defer { app.terminate() }
        sidebarDestination("Traces", in: app).click()
        XCTAssertTrue(app.staticTexts["No saved traces yet"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Open evaluations"].click()
        XCTAssertTrue(app.staticTexts["Choose a saved output"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.radioButtons["Review"].value as? String, "1")
    }

    @MainActor private func choosePane(_ title: String, app: XCUIApplication) {
        let picker = app.popUpButtons["Review"]
        if picker.exists { picker.click(); app.menuItems[title].click() }
        else { app.buttons[title].click() }
    }

    @MainActor private func sidebarDestination(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor private func openReview(_ app: XCUIApplication) {
        let destination = sidebarDestination("Evaluations", in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
        destination.click()
        XCTAssertTrue(app.radioButtons["Review"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.radioButtons["Review"].value as? String, "1")
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
