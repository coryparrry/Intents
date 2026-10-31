import Foundation
import CryptoKit
import XCTest

final class EvaluationReviewUITests: XCTestCase {
    /// The overview starts with a short recent list and reveals the remaining saved runs on request.
    @MainActor
    func testOverviewRevealsMoreRecentRuns() throws {
        continueAfterFailure = false
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let directory = storage.appending(path: "Runs")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var run = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: original)) as? [String: Any])
        let oldestID = try XCTUnwrap(run["id"] as? String)
        run["suiteVersion"] = "search-target"
        try JSONSerialization.data(withJSONObject: run).write(to: original)
        for index in 2...6 {
            let id = UUID().uuidString
            run["id"] = id
            run["suiteVersion"] = "v\(index)"
            run["startedAt"] = "1970-01-01T00:00:0\(index)Z"
            try JSONSerialization.data(withJSONObject: run).write(to: directory.appending(path: "\(id).json"))
        }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        assertReviewFixture(in: app)
        let oldest = app.descendants(matching: .any)["Sidebar run \(oldestID)"]
        XCTAssertFalse(oldest.exists)
        let filter = app.textFields["Filter runs"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("search-target")
        XCTAssertTrue(oldest.waitForExistence(timeout: 3), "Search must include runs beyond the initial three")
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(oldest.exists)
        let showAll = app.buttons["Sidebar run expansion"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        showAll.click()
        XCTAssertTrue(oldest.waitForExistence(timeout: 3))
        oldest.click()
        showAll.click()
        XCTAssertTrue(oldest.exists, "The selected run must remain in the sidebar when the list is shortened")
        app.staticTexts["Sidebar overview"].click()
        let showMore = app.buttons["Show more recent runs"]
        XCTAssertTrue(showMore.waitForExistence(timeout: 5))
        let runs = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Review example"))
        let before = runs.count
        showMore.click()
        XCTAssertEqual(runs.count, before + 3)
        app.buttons["Show fewer recent runs"].click()
        XCTAssertEqual(runs.count, before)
    }

    /// Keeps batch dataset actions and advanced settings available after simplifying the default sheet.
    @MainActor
    func testBatchSetupRevealsAdvancedOptionsWithoutLosingValues() throws {
        continueAfterFailure = false
        let storage = try reviewStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        assertReviewFixture(in: app)
        sidebarDestination("Sidebar batch runs", in: app).click()
        let importHelp = app.disclosureTriangles["About JSONL imports"]
        XCTAssertTrue(importHelp.waitForExistence(timeout: 5))
        importHelp.click()
        let importDetails = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Imports accept JSONL", "Imports accept JSONL")
        XCTAssertTrue(app.staticTexts.matching(importDetails).firstMatch.waitForExistence(timeout: 3))
        importHelp.click()
        app.buttons["Freeze current suite"].click()
        let options = app.menuButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Dataset options ")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10), app.debugDescription)
        options.click()
        XCTAssertTrue(app.menuItems["Review captured outputs"].exists)
        app.menuItems["Dataset details…"].click()
        XCTAssertTrue(app.sheets.buttons["Done"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sheets.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Revision")).firstMatch.exists)
        app.sheets.buttons["Done"].click()
        app.buttons["New batch"].firstMatch.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.textFields["Batch name"].waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.popUpButtons["Batch dataset"].exists)
        XCTAssertTrue(sheet.textFields["Batch minimum pass rate"].exists)
        let advanced = sheet.buttons["Batch advanced options"]
        XCTAssertTrue(advanced.exists)
        XCTAssertFalse(sheet.textFields["Batch request timeout"].exists)
        advanced.click()
        let timeout = sheet.textFields["Batch request timeout"]
        XCTAssertTrue(timeout.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.textFields["Batch OS filter"].exists)
        XCTAssertTrue(sheet.textFields["Batch cohort minimum pass rate"].exists)
        timeout.click()
        timeout.typeKey("a", modifierFlags: .command)
        timeout.typeText("0")
        advanced.click()
        XCTAssertFalse(sheet.buttons["Create batch"].isEnabled)
        let timeoutError = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Request timeout must be", "Request timeout must be")
        XCTAssertTrue(sheet.staticTexts.matching(timeoutError).firstMatch.exists)
        advanced.click()
        timeout.click()
        timeout.typeKey("a", modifierFlags: .command)
        timeout.typeText("90")
        let budget = sheet.textFields["Batch time budget"]
        budget.click()
        budget.typeKey("a", modifierFlags: .command)
        budget.typeText("0")
        advanced.click()
        XCTAssertFalse(sheet.buttons["Create batch"].isEnabled)
        let budgetError = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Job time budget must be", "Job time budget must be")
        XCTAssertTrue(sheet.staticTexts.matching(budgetError).firstMatch.exists)
        advanced.click()
        budget.click()
        budget.typeKey("a", modifierFlags: .command)
        budget.typeText("24")
        advanced.click()
        XCTAssertTrue(sheet.buttons["Create batch"].isEnabled)
        advanced.click()
        XCTAssertEqual(timeout.value as? String, "90")
        sheet.buttons["Cancel"].click()
    }

    /// Keeps the report focused on outcomes while retaining its extra columns and selected response.
    @MainActor
    func testRunReportRevealsAdditionalColumns() throws {
        continueAfterFailure = false
        let storage = try reviewStorage(multipleResults: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = application(storage: storage)
        launchWorkspace(app)
        defer { app.terminate() }
        assertReviewFixture(in: app)
        let latest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest run:")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5), app.debugDescription)
        latest.click()
        let more = app.buttons["More columns"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        let secondRow = app.descendants(matching: .outlineRow).containing(.staticText, identifier: "Second case").firstMatch
        XCTAssertTrue(secondRow.waitForExistence(timeout: 3), app.debugDescription)
        // Wait for the table row to accept pointer interaction before selecting it.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: secondRow)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 3), .completed, app.debugDescription)
        secondRow.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: secondRow)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, app.debugDescription)
        let column = app.buttons["Latency"]
        XCTAssertFalse(column.exists)
        let response = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Second distinct response", "Second distinct response")).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 3), app.debugDescription)
        more.click()
        XCTAssertTrue(column.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(secondRow.isSelected)
        XCTAssertTrue(response.exists)
        app.buttons["Fewer columns"].click()
        XCTAssertFalse(column.exists)
        XCTAssertTrue(secondRow.isSelected)
        XCTAssertTrue(response.exists)
    }

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
    /// Keeps saved reviews and pattern navigation available after narrowing the workspace.
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
        XCTAssertTrue(app.radioGroups["Review"].radioButtons["Patterns"].waitForExistence(timeout: 3))
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

    /// Stops a fixture test before mutation if macOS launched it with the wrong workspace.
    @MainActor private func assertReviewFixture(in app: XCUIApplication) {
        let name = app.textFields["Suite name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Review example", "UI tests must use the isolated review fixture")
    }

    /// Opens a review pane through the visible segmented, menu, or sidebar navigation.
    @MainActor private func choosePane(_ title: String, app: XCUIApplication) {
        let picker = app.popUpButtons["Review"]
        let segment = app.radioGroups["Review"].radioButtons[title]
        if segment.exists {
            reveal(segment, in: app)
            segment.click()
        } else if picker.exists {
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
    /// Creates isolated review evidence and optionally adds a second result for selection tests.
    private func reviewStorage(multipleResults: Bool = false) throws -> URL {
        let storage = try UITestStorage.makeDirectory(prefix: "eval-review")
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "review-fixture", withExtension: "json"),
            "The UI test bundle must include its generic review-fixture.json resource."
        )
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let suite = fixture["suite"] as! [String: Any]
        var run = fixture["run"] as! [String: Any]
        if multipleResults {
            var results = run["results"] as! [[String: Any]]
            var cases = run["plannedCases"] as! [[String: Any]]
            let caseID = UUID().uuidString
            var second = results[0]
            second["id"] = UUID().uuidString
            second["caseID"] = caseID
            second["caseName"] = "Second case"
            second["response"] = "Second distinct response"
            results.append(second)
            var planned = cases[0]
            planned["id"] = caseID
            planned["name"] = "Second case"
            cases.append(planned)
            run["results"] = results
            run["plannedCases"] = cases
        }
        try JSONSerialization.data(withJSONObject: suite).write(to: storage.appending(path: "suite.json"))
        let runs = storage.appending(path: "Runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: run).write(to: runs.appending(path: "\(run["id"] as! String).json"))
        return storage
    }
}
