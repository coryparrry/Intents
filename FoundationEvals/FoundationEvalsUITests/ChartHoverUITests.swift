import Foundation
import XCTest

final class ChartHoverUITests: XCTestCase {
    private static let suiteName = "Pass rate hover regression fixture"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOverviewHoverCapturesFirstMiddleAndLastRunDetails() throws {
        for appearance in ["Light", "Dark"] {
            try withWorkspace(appearance: appearance) { app in
                try assertHoverDetails(in: app, chartLabel: "Pass rate over time", screenshotPrefix: "overview-\(appearance.lowercased())")
            }
        }
    }

    @MainActor
    func testHistoryHoverCapturesFirstMiddleAndLastRunDetails() throws {
        for appearance in ["Light", "Dark"] {
            try withWorkspace(appearance: appearance) { app in
                let suite = app.groups["Suite overview \(Self.suiteName)"].buttons.firstMatch
                XCTAssertTrue(suite.waitForExistence(timeout: 5), app.debugDescription)
                suite.click()
                let history = app.radioGroups["Editor page"].radioButtons["History"]
                XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
                history.click()
                try assertHoverDetails(in: app, chartLabel: "Pass rate trend", screenshotPrefix: "history-\(appearance.lowercased())")
            }
        }
    }

    @MainActor
    private func assertHoverDetails(
        in app: XCUIApplication,
        chartLabel: String,
        screenshotPrefix: String
    ) throws {
        let chart = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", chartLabel)).firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(chart.frame.width, 100)
        XCTAssertGreaterThan(chart.frame.height, 70)
        // Charts exposes its selected rule through AX, but omits annotation
        // views. Verify selection here and retain images for visual regression
        // review of the tooltip text, containment, and background compositing.
        var previousX: CGFloat?
        for (position, rate) in [(0.18, 0), (0.54, 50), (0.90, 100)] {
            chart.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.8)).hover()
            func selectionRule() -> XCUIElement? {
                chart.descendants(matching: .other).allElementsBoundByIndex.first {
                    $0.frame.width <= 2 && $0.frame.height > chart.frame.height * 0.5
                }
            }
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let frame = selectionRule()?.frame else { return false }
                return previousX.map { frame.midX > $0 + chart.frame.width * 0.2 } ?? true
            }, object: nil)
            let result = XCTWaiter.wait(for: [selected], timeout: 5)

            let screenshot = app.windows.firstMatch.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(screenshotPrefix) hover \(rate) percent"
            attachment.lifetime = .keepAlways
            add(attachment)
            try screenshot.pngRepresentation.write(
                to: UITestStorage.screenshotURL(name: "chart-hover-\(screenshotPrefix)-\(rate)"))
            XCTAssertEqual(result, .completed, "Hover must move selection to the \(rate)% run")
            let rule = try XCTUnwrap(selectionRule())
            XCTAssertTrue(chart.frame.insetBy(dx: -1, dy: -1).contains(rule.frame))
            let normalizedX = (rule.frame.midX - chart.frame.minX) / chart.frame.width
            XCTAssertEqual(normalizedX, position, accuracy: 0.22)
            previousX = rule.frame.midX
        }
    }

    @MainActor
    private func withWorkspace(appearance: String, _ body: (XCUIApplication) throws -> Void) throws {
        let storage = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments = [
            "--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1360", "--evaluation-window-height", "900",
            "-AppleInterfaceStyle", appearance, "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.openSuiteEditor(in: app)
        // The window-opening command selects the suite editor. Start both
        // journeys explicitly on Overview so the chart and suite tile exist.
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.exists { showSidebar.click() }
        let overview = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Overview", "Overview")).firstMatch
        try UITestStorage.waitFor(overview, in: app, timeout: 5)
        overview.click()
        try body(app)
    }

    private func makeWorkspace() throws -> URL {
        let storage = try UITestStorage.makeDirectory(prefix: "chart-hover")
        do {
            let projectID = UUID().uuidString
            let suiteID = UUID().uuidString
            let date = "2026-01-01T12:00:00Z"
            let cases: [[String: Any]] = (1...2).map { index in
                ["id": UUID().uuidString, "name": "Case \(index)", "prompt": "Return yes", "expected": "yes"]
            }
            let suite: [String: Any] = [
                "id": suiteID, "name": Self.suiteName, "version": "v1",
                "scoringMode": "exactMatch", "cases": cases
            ]
            let catalog: [String: Any] = [
                "formatVersion": 1, "selectedProjectID": projectID,
                "projects": [[
                    "id": projectID, "name": "Chart hover verification",
                    "createdAt": date, "updatedAt": date, "selectedSuiteID": suiteID,
                    "suites": [["id": suiteID, "name": Self.suiteName, "createdAt": date, "updatedAt": date]]
                ]]
            ]
            let suiteDirectory = storage.appending(path: "Projects/\(projectID)/Suites/\(suiteID)")
            let runsDirectory = suiteDirectory.appending(path: "Runs")
            try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: suiteDirectory.appending(path: "Attachments"), withIntermediateDirectories: true)
            try write(catalog, to: storage.appending(path: "workspace-v1.json"))
            try write(suite, to: suiteDirectory.appending(path: "suite.json"))

            for passedCount in 0...2 {
                let runID = UUID().uuidString
                let results: [[String: Any]] = cases.enumerated().map { index, testCase in
                    [
                        "id": UUID().uuidString, "caseID": testCase["id"]!, "caseName": testCase["name"]!,
                        "repetition": 1, "prompt": "Return yes", "expected": "yes",
                        "response": index < passedCount ? "yes" : "no",
                        "status": index < passedCount ? "passed" : "failed", "durationMilliseconds": 1,
                        "usage": ["inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0, "reasoningTokens": 0]
                    ]
                }
                let run: [String: Any] = [
                    "id": runID, "suiteID": suiteID, "projectID": projectID,
                    "suiteName": Self.suiteName, "suiteVersion": "v1", "instructions": "Return yes",
                    "criteria": "Exact text", "scoringMode": "exactMatch", "repetitions": 1,
                    "plannedSampleCount": 2, "plannedCases": cases, "historySequence": passedCount + 1,
                    "startedAt": "2026-01-0\(passedCount + 1)T12:00:00Z",
                    "completedAt": "2026-01-0\(passedCount + 1)T12:00:01Z", "cancelled": false,
                    "environment": ["operatingSystem": "macOS", "locale": "en_GB", "model": "UI fixture", "modelContextSize": 4096],
                    "attachments": [], "results": results
                ]
                try write(run, to: runsDirectory.appending(path: "\(runID).json"))
            }
            return storage
        } catch {
            try? FileManager.default.removeItem(at: storage)
            throw error
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
