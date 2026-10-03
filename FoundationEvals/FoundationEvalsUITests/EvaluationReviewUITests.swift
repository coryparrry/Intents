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
        app.segmentedControls["Editor page"].buttons["Setup"].click()
        app.segmentedControls["Editor page"].buttons["Review"].click()
        XCTAssertEqual(app.textViews["Review note"].value as? String, "The meeting date is incorrect.")
        app.popUpButtons["Human verdict"].click(); app.menuItems["Failed"].click()
        app.textFields["Review tags"].click(); app.textFields["Review tags"].typeText("wrong date")
        app.buttons["Save review"].click()
        choosePane("Patterns", app: app)
        XCTAssertTrue(app.staticTexts["wrong date"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 reviewed examples · 1 unique cases"].exists)
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

    @MainActor private func choosePane(_ title: String, app: XCUIApplication) {
        let picker = app.popUpButtons["Review"]
        if picker.exists { picker.click(); app.menuItems[title].click() }
        else { app.buttons[title].click() }
    }

    @MainActor private func openReview(_ app: XCUIApplication) {
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        let review = app.segmentedControls["Editor page"].buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        review.click()
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
