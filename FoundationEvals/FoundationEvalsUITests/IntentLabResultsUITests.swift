import XCTest

final class IntentLabResultsUITests: XCTestCase {
    @MainActor
    func testSavedResultsExplainOutcomeAndKeepRawEvidenceCollapsed() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-results")
        defer { try? FileManager.default.removeItem(at: storage) }
        try writeRun(to: storage, outcome: "passed")
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        try UITestStorage.requireNoAlert(in: app)
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Results"].click()

        XCTAssertTrue(app.descendants(matching: .any)["Intent Lab result summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What was checked"].exists)
        XCTAssertFalse(text("invocationContext", in: app).exists)
        let evidence = app.disclosureTriangles["Checks and evidence"]
        reveal(evidence, in: app)
        evidence.click()
        XCTAssertTrue(text("The requested item was returned.", in: app).exists)
        XCTAssertFalse(text("invocationContext", in: app).exists)
        let technical = app.disclosureTriangles["Technical details"]
        reveal(technical, in: app)
        technical.click()
        XCTAssertTrue(text("invocationContext", in: app).exists)
        XCTAssertTrue(text("fixture-invocation", in: app).exists)
        capture(app, name: "lab-evidence-details")
    }

    @MainActor
    func testFailedCheckAndDiagnosticRemainAccessible() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "intent-failed-result")
        defer { try? FileManager.default.removeItem(at: storage) }
        try writeRun(to: storage, outcome: "failed")
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        try UITestStorage.requireNoAlert(in: app)
        app.typeKey("2", modifierFlags: .command)
        app.radioButtons["Results"].click()
        XCTAssertTrue(app.descendants(matching: .any)["Intent Lab result summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("At least one check did not match the expected result.", in: app).exists)
        capture(app, name: "lab-failed-summary")
        let evidence = app.disclosureTriangles["Checks and evidence"]
        reveal(evidence, in: app)
        evidence.click()
        XCTAssertTrue(text("The app returned a different item.", in: app).exists)
        let technical = app.disclosureTriangles["Technical details"]
        reveal(technical, in: app)
        technical.click()
        XCTAssertTrue(text("The captured identifier did not match the expected item.", in: app).exists)
    }

    @MainActor
    private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let url = try? UITestStorage.screenshotURL(name: name) {
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    private func writeRun(to storage: URL, outcome: String) throws {
        let scenarioID = "B0000000-0000-0000-0000-000000000001"
        let runID = "B0000000-0000-0000-0000-000000000002"
        let date = "2026-09-30T10:00:00Z"
        let run: [String: Any] = [
            "id": runID, "scenarioID": scenarioID, "scenarioVersion": 1, "scenarioDigest": "fixture",
            "startedAt": date, "completedAt": date, "importedAt": date,
            "executionStatus": "completed", "outcome": outcome,
            "invocation": [
                "id": runID, "nonce": "fixture", "issuedAt": date, "harnessVersion": "intent-lab-v1",
                "destinationIdentifier": "fixture-mac", "scenarioDigest": "fixture", "resultBundleIdentity": "fixture",
                "testIdentity": ["bundleIdentifier": "dev.example.Tests", "className": "Tests", "methodName": "testItem"]
            ],
            "environment": [
                "xcodeVersion": "Test Xcode", "sdkVersion": "Test SDK", "deviceModel": "Test Mac",
                "operatingSystem": "Test OS", "languageCode": "en", "regionCode": "GB",
                "timeZoneIdentifier": "Europe/London", "executedAt": date
            ],
            "laneResults": [[
                "id": "B0000000-0000-0000-0000-000000000003", "caseID": scenarioID,
                "attempt": 1, "lane": "intentIntegration", "executionStatus": "completed", "outcome": outcome,
                "startedAt": date, "completedAt": date, "artifacts": [],
                "observations": ["invocationContext": ["string": ["_0": "fixture-invocation"]]],
                "diagnostic": "The captured identifier did not match the expected item.",
                "assertionResults": [[
                    "id": "B0000000-0000-0000-0000-000000000004", "assertionID": "B0000000-0000-0000-0000-000000000005",
                    "passed": outcome == "passed",
                    "message": outcome == "passed" ? "The requested item was returned." : "The app returned a different item."
                ]]
            ]]
        ]
        let directory = storage.appending(path: "IntentLab/Runs/\(scenarioID)/\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "run.json"))
    }
}
