import XCTest

final class SimplificationUITests: XCTestCase {
    @MainActor
    func testIndividualAndCoordinatedAssertionRowsKeepTheirOrder() throws {
        continueAfterFailure = false
        for format in ["individual", "coordinated"] { try inspectReport(format) }
    }

    @MainActor
    private func inspectReport(_ format: String) throws {
        let storage = try UITestStorage.makeDirectory(prefix: "simplification-report")
        defer { try? FileManager.default.removeItem(at: storage) }
        let resource = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "SimplificationReport-\(format)", withExtension: "json"
        ))
        let files = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: resource))
        for (path, contents) in files {
            let destination = storage.appending(path: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: destination)
        }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        let results = app.radioButtons["Results"]
        XCTAssertTrue(results.waitForExistence(timeout: 10), app.debugDescription)
        results.click()
        let passed = app.staticTexts["Returned value matched"].firstMatch
        let failed = app.staticTexts["Saved state did not match"].firstMatch
        XCTAssertTrue(passed.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(failed.exists)
        for _ in 0..<12 where !failed.isHittable {
            app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
        }
        XCTAssertTrue(passed.isHittable)
        XCTAssertTrue(failed.isHittable)
        XCTAssertLessThan(passed.frame.minY, failed.frame.minY)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Saved \(format) report assertion rows"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
