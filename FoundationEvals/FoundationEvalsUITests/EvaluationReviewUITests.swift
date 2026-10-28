import Foundation
import CryptoKit
import XCTest

final class EvaluationReviewUITests: XCTestCase {
    /// Removes a deleted-source judge example, collects a replacement through human review, and verifies both changes survive relaunch.
    @MainActor
    func testUnavailableJudgeExampleCanBeRemovedAndReplacedAfterRelaunch() throws {
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let source = try seedUnavailableJudgeExample(in: storage)
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        openReview(app)
        choosePane("Judge checks", app: app)
        let unavailable = app.staticTexts["Source unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5), app.debugDescription)
        let remove = app.buttons["Remove judge example"]
        reveal(remove, in: app)
        let before = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        before.name = "Judge checks unavailable source and removal control"
        before.lifetime = .keepAlways
        add(before)
        remove.click()
        XCTAssertTrue(emptyState("No reviewed judge examples", in: app).waitForExistence(timeout: 3), app.debugDescription)
        let removedState = try currentReviewState(in: storage)
        XCTAssertTrue(try XCTUnwrap(removedState["reviewedJudgeExamples"] as? [[String: Any]]).isEmpty)

        choosePane("Samples", app: app)
        let verdict = app.popUpButtons["Human verdict"]
        reveal(verdict, in: app)
        verdict.click(); app.menuItems["Failed"].click()
        let note = app.textViews["Review note"]
        reveal(note, in: app)
        note.click(); note.typeText("The replacement judge check preserves the human failure.")
        reveal(app.buttons["Save review"], in: app)
        app.buttons["Save review"].click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3), app.debugDescription)
        let collect = app.menuButtons.matching(NSPredicate(format: "title == %@", "Use as judge check")).firstMatch
        reveal(collect, in: app)
        XCTAssertTrue(collect.isEnabled)
        collect.click()
        let development = app.menuItems["Development"]
        XCTAssertTrue(development.waitForExistence(timeout: 3), app.debugDescription)
        development.click()
        choosePane("Judge checks", app: app)
        XCTAssertTrue(app.staticTexts["Meeting date"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(unavailable.exists)
        let replacementState = try currentReviewState(in: storage)
        let replacements = try XCTUnwrap(replacementState["reviewedJudgeExamples"] as? [[String: Any]])
        XCTAssertEqual(replacements.count, 1)
        let replacement = try XCTUnwrap(replacements.first)
        XCTAssertNotEqual(replacement["id"] as? String, source.orphanID)
        XCTAssertEqual(replacement["sourceRunID"] as? String, source.runID)
        XCTAssertEqual(replacement["partition"] as? String, "development")
        XCTAssertEqual(replacement["expectedStatus"] as? String, "failed")

        app.terminate(); launchWorkspace(app); openReview(app)
        choosePane("Judge checks", app: app)
        XCTAssertTrue(app.staticTexts["Meeting date"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Source unavailable"].exists)
        XCTAssertTrue(app.buttons["Remove judge example"].exists)
        let reloadedState = try currentReviewState(in: storage)
        let reloadedExamples = try XCTUnwrap(reloadedState["reviewedJudgeExamples"] as? [[String: Any]])
        XCTAssertEqual(reloadedExamples.count, 1)
        let reloaded = try XCTUnwrap(reloadedExamples.first)
        XCTAssertEqual(reloaded["id"] as? String, replacement["id"] as? String)
        let recovered = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        recovered.name = "Judge checks replacement persisted after relaunch"
        recovered.lifetime = .keepAlways
        add(recovered)
    }

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
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        let target = edge.withOffset(CGVector(dx: 1000 - window.frame.width, dy: 0))
        edge.hover()
        edge.click(forDuration: 0.25, thenDragTo: target)
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

    /// Adds a matching synthetic assessment to the bundled single-case run and a held-out example whose source run was deleted.
    private func seedUnavailableJudgeExample(in storage: URL) throws -> (orphanID: String, runID: String) {
        let suite = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.appending(path: "suite.json"))) as? [String: Any])
        let runs = storage.appending(path: "Runs")
        let runURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var run = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: runURL)) as? [String: Any])
        let runID = try XCTUnwrap(run["id"] as? String)
        let samples = try XCTUnwrap(run["results"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        let sampleID = try XCTUnwrap(sample["id"] as? String)
        let cases = try XCTUnwrap(run["plannedCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 1)
        let evaluationCase = try XCTUnwrap(cases.first)
        let conversation = try XCTUnwrap(evaluationCase["conversation"] as? [String: Any])
        XCTAssertEqual(conversation["historyPolicy"] as? String, "keepAll")
        XCTAssertTrue(try XCTUnwrap(conversation["setupTurns"] as? [[String: Any]]).isEmpty)
        let scoringCase: [String: Any] = [
            "id": try XCTUnwrap(evaluationCase["id"]), "prompt": try XCTUnwrap(evaluationCase["prompt"]),
            "expected": try XCTUnwrap(evaluationCase["expected"]), "fieldAssertions": [],
            "conversation": ["setupPrompts": [], "historyPolicy": "keepAll",
                             "modelHistoryProjection": ["policy": "keepAll", "retainedTurnCount": 2]]
        ]
        let casesDigest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: [scoringCase], options: .sortedKeys))
            .map { String(format: "%02x", $0) }.joined()
        let promptVersion = "rubric-v13-document-question-context"
        let assessmentID = UUID().uuidString
        let judge: [String: Any] = ["mode": "sameModel", "connectionName": "Synthetic UI judge",
                                  "requestedModelID": "fixture", "reportedModelID": "fixture", "providerOrder": []]
        let criteria = try XCTUnwrap(suite["criteria"] as? String)
        run["assessments"] = [[
            "id": assessmentID, "runID": runID, "createdAt": "2026-10-28T00:00:00Z", "origin": "initialRun",
            "judge": judge, "observedJudgeIdentities": [judge], "promptVersion": promptVersion,
            "rubric": criteria, "passingScore": 3,
            "samples": [["id": UUID().uuidString, "sampleID": sampleID, "status": "failed", "score": 1,
                         "rationale": "Synthetic saved judgment", "durationMilliseconds": 0]],
            "durationMilliseconds": 0, "cost": ["availability": "known", "usd": 0, "explanation": "Synthetic fixture"],
            "scoringContract": ["scoringMode": "modelJudge", "rubricCriteria": criteria.split(separator: "\n").map(String.init),
                                "judgePromptVersion": promptVersion, "judgePassingScore": 3, "casesDigest": casesDigest],
            "subjectEvidenceDigest": try XCTUnwrap((run["subjectEvidence"] as? [String: Any])?["digest"])
        ]]
        run["selectedAssessmentID"] = assessmentID
        try JSONSerialization.data(withJSONObject: run).write(to: runURL, options: .atomic)
        let orphanID = UUID().uuidString
        let state: [String: Any] = ["baselineApprovals": [], "humanCorrections": [], "experiments": [],
            "reviewedJudgeExamples": [["id": orphanID, "partition": "test", "sourceRunID": UUID().uuidString,
                "sourceAssessmentID": UUID().uuidString, "sampleID": UUID().uuidString, "expectedStatus": "failed",
                "reason": "Deleted calibration source", "createdAt": "2026-10-28T00:00:00Z"]]]
        try JSONSerialization.data(withJSONObject: state).write(to: storage.appending(path: "state.json"), options: .atomic)
        return (orphanID, runID)
    }

    /// Reads the selected suite's migrated local state so UI mutations must be durable before the test continues.
    private func currentReviewState(in storage: URL) throws -> [String: Any] {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.appending(path: "workspace-v1.json"))) as? [String: Any])
        let projectID = try XCTUnwrap(catalog["selectedProjectID"] as? String)
        let projects = try XCTUnwrap(catalog["projects"] as? [[String: Any]])
        let project = try XCTUnwrap(projects.first { $0["id"] as? String == projectID })
        let suiteID = try XCTUnwrap(project["selectedSuiteID"] as? String)
        let stateURL = storage.appending(path: "Projects/\(projectID)/Suites/\(suiteID)/state.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    }

    /// Copies the bundled generic source run into isolated legacy storage for automatic workspace migration.
    private func reviewStorage() throws -> URL {
        let storage = try UITestStorage.makeDirectory(prefix: "eval-review")
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "review-fixture", withExtension: "json"),
            "The UI test bundle must include its generic review-fixture.json resource."
        )
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
