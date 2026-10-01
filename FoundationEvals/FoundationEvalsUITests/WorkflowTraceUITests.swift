import XCTest

final class WorkflowTraceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPromptEditingUndoAndPersistence() throws {
        try withFixtureApplication { app in
            app.menuBars.menuBarItems["Evaluation"].click()
            app.menuItems["Show Suite Editor"].click()
            let prompt = app.textViews["Case prompt"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            prompt.click()
            prompt.typeKey("a", modifierFlags: .command)
            let text = "Why is the sky blue?\nExplain it in two short paragraphs.\nUse plain language."
            prompt.typeText(text)
            XCTAssertEqual(prompt.value as? String, text)
            prompt.typeKey("a", modifierFlags: .command)
            prompt.typeKey(.delete, modifierFlags: [])
            XCTAssertEqual(prompt.value as? String, "")
            prompt.typeKey("z", modifierFlags: .command)
            XCTAssertEqual(prompt.value as? String, text)
            let selector = app.popUpButtons["Case selector"]
            let firstCase = try XCTUnwrap(selector.value as? String)
            app.buttons["Add Case"].click()
            XCTAssertEqual(prompt.value as? String, "")
            prompt.click()
            prompt.typeText("A different case prompt")
            XCTAssertTrue(app.staticTexts["Saved automatically on this Mac"].waitForExistence(timeout: 5))
            selector.click()
            app.menuItems[firstCase].click()
            XCTAssertEqual(prompt.value as? String, text)
            prompt.click()
            prompt.typeKey("z", modifierFlags: .command)
            XCTAssertEqual(prompt.value as? String, text)
            try capture(app, name: "prompt-editor")
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            app.launch()
            try UITestStorage.requireNoAlert(in: app)
            app.menuBars.menuBarItems["Evaluation"].click()
            app.menuItems["Show Suite Editor"].click()
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            XCTAssertEqual(prompt.value as? String, text)
        }
    }

    @MainActor
    func testTypingAutosavesLatestTextAcrossRelaunch() throws {
        try withFixtureApplication { app in
            app.menuBars.menuBarItems["Evaluation"].click()
            app.menuItems["Show Suite Editor"].click()
            let name = app.textFields["Suite name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.click()
            name.typeKey("a", modifierFlags: .command)
            let text = "Typing stays responsive and the latest edit survives reopening"
            name.typeText(text)
            XCTAssertEqual(name.value as? String, text)
            // Quit immediately after typing to exercise the pending-save flush.
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            app.launch()
            try UITestStorage.requireNoAlert(in: app)
            app.menuBars.menuBarItems["Evaluation"].click()
            app.menuItems["Show Suite Editor"].click()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, text)
        }
    }

    @MainActor
    func testWorkspaceResetConfirmationAndPersistence() throws {
        try withFixtureApplication { app in
            func choose(_ title: String) {
                app.descendants(matching: .any).matching(identifier: "Start from Scratch").firstMatch.click()
                app.menuItems[title].click()
            }
            choose("Clear All Runs and Traces")
            let dialog = app.sheets.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 3), app.debugDescription)
            dialog.buttons["Cancel"].click()
            XCTAssertTrue(app.popUpButtons["Trace case"].exists)

            choose("Clear All Runs and Traces")
            dialog.buttons["Clear All Runs and Traces"].click()
            XCTAssertTrue(app.textFields["Suite name"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.popUpButtons["Trace case"].exists)
            let priorName = app.textFields["Suite name"].value as? String
            XCTAssertNotEqual(priorName, "Untitled Suite")

            choose("Reset Current Suite")
            dialog.buttons["Reset Current Suite"].click()
            XCTAssertEqual(app.textFields["Suite name"].value as? String, "Untitled Suite")
            try capture(app, name: "blank-suite-after-reset")
            app.terminate()
            app.launch()
            try UITestStorage.requireNoAlert(in: app)
            app.menuBars.menuBarItems["Evaluation"].click()
            app.menuItems["Show Suite Editor"].click()
            XCTAssertTrue(app.textFields["Suite name"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Suite name"].value as? String, "Untitled Suite")
            XCTAssertFalse(app.buttons["Run evaluation"].isEnabled)
        }
    }

    @MainActor
    func testNativeWorkflowSupportsStageInspectionHierarchyAndKeyboardSelection() throws {
        try withFixtureApplication { app in
            XCTAssertTrue(app.radioButtons["Workflow trace"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["Workflow spans"].exists)
            XCTAssertTrue(app.staticTexts["App-observed timing"].exists)
            app.buttons["Expand all spans"].click()

            span(WorkflowTraceFixture.generationID, in: app).click()
            assertSelectedTitle("Generate response", in: app)
            assertDetailContains("Framework-reported usage. Cached input is part of input; reasoning is part of output.", in: app)
            assertDetailContains("Input", in: app)
            assertDetailContains("Output", in: app)
            assertDetailContains("First visible content", in: app)
            try capture(app, name: "recorded-workflow")

            span(WorkflowTraceFixture.preparationID, in: app).click()
            assertSelectedTitle("Prepare input", in: app)
            app.radioButtons["Input / Output"].click()
            assertDetailContains(WorkflowTraceFixture.effectivePrompt, in: app)
            try capture(app, name: "preparation")

            span(WorkflowTraceFixture.judgeID, in: app).click()
            assertSelectedTitle("AI judge", in: app)
            assertDetailContains(WorkflowTraceFixture.judgePrompt, in: app)
            assertDetailContains(WorkflowTraceFixture.judgeResponse, in: app)
            try capture(app, name: "judge")

            // This is a local HTTP tool called by native generation, not model inference over HTTP.
            let request = span(WorkflowTraceFixture.successRequestID, in: app)
            XCTAssertTrue(request.waitForExistence(timeout: 2))
            request.click()
            assertSelectedTitle("POST /fixture/search", in: app)
            app.radioButtons["Details"].click()
            assertDetailContains("Method", in: app)
            assertDetailContains("POST", in: app)
            assertDetailContains("Status code", in: app)
            assertDetailContains("200", in: app)
            assertDetailContains("http://127.0.0.1:8765/fixture/search", in: app)
            try capture(app, name: "local-http-tool")

            // Arrow selection follows the visible depth-first rows, including tool children.
            request.click()
            app.typeKey(.downArrow, modifierFlags: [])
            assertSelectedTitle(WorkflowTraceFixture.failedToolTitle, in: app)
            app.typeKey(.downArrow, modifierFlags: [])
            assertSelectedTitle("POST /fixture/unavailable", in: app)
            assertDetailContains("503", in: app)
            assertDetailContains("Fixture service unavailable", in: app)
            try capture(app, name: "failed-local-http-tool")

            app.typeKey(.upArrow, modifierFlags: [])
            assertSelectedTitle(WorkflowTraceFixture.failedToolTitle, in: app)
            app.typeKey(.leftArrow, modifierFlags: [])
            XCTAssertTrue(span(WorkflowTraceFixture.failedRequestID, in: app).waitForNonExistence(timeout: 2))
            app.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertTrue(span(WorkflowTraceFixture.failedRequestID, in: app).waitForExistence(timeout: 2))

            app.buttons["Collapse Generate response"].click()
            XCTAssertTrue(request.waitForNonExistence(timeout: 2))
            XCTAssertFalse(span(WorkflowTraceFixture.failedRequestID, in: app).exists)
            XCTAssertTrue(span(WorkflowTraceFixture.scoringID, in: app).exists)
            app.buttons["Expand Generate response"].click()
            XCTAssertTrue(request.waitForExistence(timeout: 2))

            app.buttons["Collapse all spans"].click()
            XCTAssertTrue(span(WorkflowTraceFixture.rootID, in: app).exists)
            XCTAssertFalse(span(WorkflowTraceFixture.generationID, in: app).exists)
            app.buttons["Expand all spans"].click()
            XCTAssertTrue(request.waitForExistence(timeout: 2))

            // The original result report remains available from the same saved run.
            app.radioButtons["Report"].click()
            XCTAssertTrue(app.staticTexts["Scored pass rate"].waitForExistence(timeout: 2))
            app.radioButtons["Workflow trace"].click()
            XCTAssertTrue(app.descendants(matching: .any)["Workflow spans"].waitForExistence(timeout: 2))
        }
    }

    @MainActor
    func testLegacySampleKeepsDurationsWithoutInventingTimelinePlacement() throws {
        try withFixtureApplication { app in
            selectCase("Legacy durations", in: app)
            XCTAssertTrue(app.staticTexts[WorkflowTraceFixture.legacyTimingExplanation].waitForExistence(timeout: 2))
            XCTAssertTrue(app.descendants(matching: .any)["Workflow spans"].exists)
            XCTAssertFalse(span(WorkflowTraceFixture.successRequestID, in: app).exists)
            try capture(app, name: "legacy")

            selectCase("Native workflow with local tools", in: app)
            XCTAssertTrue(span(WorkflowTraceFixture.rootID, in: app).waitForExistence(timeout: 2))
            XCTAssertFalse(app.staticTexts[WorkflowTraceFixture.legacyTimingExplanation].exists)
        }
    }

    @MainActor
    func testCancelledHTTPRequestRetainsItsErrorAndDoesNotInventAStatusCode() throws {
        try withFixtureApplication { app in
            selectCase("Cancelled request", in: app)
            app.buttons["Expand all spans"].click()
            let request = span(WorkflowTraceFixture.cancelledRequestID, in: app)
            XCTAssertTrue(request.waitForExistence(timeout: 2))
            request.click()
            assertSelectedTitle("POST /fixture/cancelled", in: app)
            assertDetailContains("Fixture request cancelled before receiving a response", in: app)
            assertDetailContains("POST", in: app)
            let details = app.descendants(matching: .any)["Span details"]
            XCTAssertFalse(details.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Status code", "Status code")
            ).firstMatch.exists)
            try capture(app, name: "cancelled-local-http-tool")
        }
    }

    @MainActor
    func testOverflowingWaterfallScrollsTheEntireLastSpanIntoView() throws {
        try withFixtureApplication { app in
            selectCase("Overflowing native workflow", in: app)
            app.buttons["Expand all spans"].click()
            let waterfall = app.descendants(matching: .any)["Workflow spans"]
            let lastSpan = span(WorkflowTraceFixture.overflowLastSpanID, in: app)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.descendants(matching: .any)["Workspace status"].waitForExistence(timeout: 2))
            XCTAssertFalse(isFullyVisibleVertically(lastSpan, in: waterfall, window: window),
                "The 38-span fixture must extend below the initial viewport")

            scrollDownToReveal(lastSpan, in: waterfall, window: window)
            try capture(app, name: "overflowing-waterfall")
            assertFullyVisibleVertically(lastSpan, in: waterfall, window: window, minimumHeight: 32)
            lastSpan.click()
            assertSelectedTitle("Judge attempt 1", in: app)
        }
    }

    @MainActor
    func testLongJudgeInspectorScrollsTheEntireOutputIntoView() throws {
        try withFixtureApplication(longJudgeEvidence: true) { app in
            span(WorkflowTraceFixture.judgeID, in: app).click()
            assertSelectedTitle("AI judge", in: app)
            app.radioButtons["Input / Output"].click()
            let details = app.descendants(matching: .any)["Span details"]
            let inspector = details.scrollViews.firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 2), app.debugDescription)
            let output = details.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                WorkflowTraceFixture.longJudgeOutput, WorkflowTraceFixture.longJudgeOutput
            )).firstMatch
            let window = app.windows.firstMatch
            XCTAssertTrue(window.descendants(matching: .any)["Workspace status"].waitForExistence(timeout: 2))
            XCTAssertFalse(isFullyVisibleVertically(output, in: inspector, window: window),
                "The 240-line judge input must place its output below the initial viewport")

            scrollDownToReveal(output, in: inspector, window: window)
            assertFullyVisibleVertically(output, in: inspector, window: window, minimumHeight: 10)
            try capture(app, name: "long-judge-output")
        }
    }

    @MainActor
    func testFittedTimelineKeepsDetailsAndResizesWithSidebar() throws {
        try withFixtureApplication { app in
            let list = app.descendants(matching: .any)["Workflow spans"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            XCTAssertFalse(app.popUpButtons["Timeline zoom"].exists)
            let details = app.descendants(matching: .any)["Span details"]
            XCTAssertTrue(details.exists)
            XCTAssertFalse(app.buttons["Hide span details"].exists)
            let window = app.windows.firstMatch
            let originalWidth = list.frame.width
            XCTAssertLessThanOrEqual(list.frame.maxX, details.frame.minX + 2)
            XCTAssertGreaterThanOrEqual(list.frame.minX, window.frame.minX)
            span(WorkflowTraceFixture.generationID, in: app).click()
            assertSelectedTitle("Generate response", in: app)
            let sidebar = app.buttons["Hide Sidebar"].exists ? app.buttons["Hide Sidebar"] : app.buttons["Show Sidebar"]
            sidebar.click()
            XCTAssertNotEqual(list.frame.width, originalWidth)
            XCTAssertLessThanOrEqual(list.frame.maxX, details.frame.minX + 2)
            XCTAssertGreaterThanOrEqual(list.frame.minX, window.frame.minX)
            XCTAssertTrue(details.exists)
            try capture(app, name: "fitted-timeline-sidebar-resize")
        }
    }

    @MainActor
    private func withFixtureApplication(
        longJudgeEvidence: Bool = false,
        _ body: (XCUIApplication) throws -> Void
    ) throws {
        let storage = try UITestStorage.makeDirectory(prefix: "workflow-trace")
        defer { try? FileManager.default.removeItem(at: storage) }
        try WorkflowTraceFixture.write(to: storage, longJudgeEvidence: longJudgeEvidence)
        try UITestStorage.verifyWritable(storage)

        let app = XCUIApplication()
        app.launchArguments += [
            "--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        try UITestStorage.requireNoAlert(in: app)
        app.activate()
        try UITestStorage.requireNoAlert(in: app)
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        try UITestStorage.waitFor(app.windows.firstMatch, in: app, timeout: 5)
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.exists { showSidebar.click() }
        let savedRun = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", WorkflowTraceFixture.runName)).firstMatch
        try UITestStorage.waitFor(savedRun, in: app, timeout: 5)
        savedRun.click()
        try UITestStorage.waitFor(app.popUpButtons["Trace case"], in: app, timeout: 5)
        try body(app)
    }

    @MainActor
    private func span(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.activate()
        return app.descendants(matching: .any)["Trace span \(id)"]
    }

    @MainActor
    private func selectCase(_ name: String, in app: XCUIApplication) {
        app.popUpButtons["Trace case"].click()
        let item = app.menuItems["\(name) · repetition 1"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), app.debugDescription)
        item.click()
    }

    @MainActor
    private func assertSelectedTitle(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selectedTitle = app.staticTexts["Selected span title"]
        let expected = NSPredicate(format: "label == %@ OR value == %@", title, title)
        let changed = XCTNSPredicateExpectation(predicate: expected, object: selectedTitle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [changed], timeout: 2), .completed,
            app.debugDescription, file: file, line: line
        )
    }

    @MainActor
    private func assertDetailContains(
        _ text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let details = app.descendants(matching: .any)["Span details"]
        let evidence = details.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
        XCTAssertTrue(
            evidence.waitForExistence(timeout: 2),
            app.debugDescription, file: file, line: line
        )
    }

    @MainActor
    private func scrollDownToReveal(_ element: XCUIElement, in scrollView: XCUIElement, window: XCUIElement) {
        // Use actual wheel scrolling; clicking an off-screen element would let XCTest scroll for us.
        for _ in 0..<12 {
            if isFullyVisibleVertically(element, in: scrollView, window: window) { return }
            scrollView.scroll(byDeltaX: 0, deltaY: -500)
        }
    }

    @MainActor
    private func isFullyVisibleVertically(_ element: XCUIElement, in scrollView: XCUIElement, window: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let viewport = contentViewport(of: scrollView, window: window)
        return !viewport.isNull && frame.height > 0
            && frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.maxY + 1
    }

    @MainActor
    private func contentViewport(of scrollView: XCUIElement, window: XCUIElement) -> CGRect {
        let viewport = scrollView.frame.intersection(window.frame)
        let statusBar = window.descendants(matching: .any)["Workspace status"]
        guard !viewport.isNull, statusBar.exists else { return .null }
        let bottom = min(viewport.maxY, statusBar.frame.minY)
        guard bottom > viewport.minY else { return .null }
        // The footer can overlay content even when the element is fully inside the window.
        return CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: bottom - viewport.minY)
    }

    @MainActor
    private func assertFullyVisibleVertically(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        window: XCUIElement,
        minimumHeight: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, element.debugDescription, file: file, line: line)
        let frame = element.frame
        let viewport = contentViewport(of: scrollView, window: window)
        XCTAssertFalse(viewport.isNull, "The scroll viewport must be inside the window and above the workspace status bar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, minimumHeight, "The element must retain its full height", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, "Element \(frame) starts above viewport \(viewport)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, "Element \(frame) ends below viewport \(viewport)", file: file, line: line)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) throws {
        app.activate()
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Trace inspector test fixture — \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(
            to: try UITestStorage.screenshotURL(name: name),
            options: .atomic
        )
    }
}

/// Persists an explicitly labelled test run through the app's normal JSON storage boundary.
/// Times, responses, and HTTP metadata below are deterministic fixture values, not real model results.
private enum WorkflowTraceFixture {
    static let runName = "Trace inspector test fixture"
    static let rootID = "A0000000-0000-0000-0000-000000000001"
    static let preparationID = "A0000000-0000-0000-0000-000000000002"
    static let generationID = "A0000000-0000-0000-0000-000000000003"
    static let successRequestID = "A0000000-0000-0000-0000-000000000005"
    static let failedRequestID = "A0000000-0000-0000-0000-000000000007"
    static let scoringID = "A0000000-0000-0000-0000-000000000008"
    static let judgeID = "A0000000-0000-0000-0000-000000000009"
    static let cancelledRequestID = "C0000000-0000-0000-0000-000000000004"
    static let failedToolTitle = "Fetch unavailable records with a deliberately long tool label to verify row truncation"
    static let legacyTimingExplanation = "Start offsets were not recorded for this saved sample. Durations are shown without timeline placement."
    static let effectivePrompt = "Test fixture instructions. Return the fixture response."
    static let judgePrompt = "Assess whether the native model returned the fixture response after using its local reference tools."
    static let judgeResponse = "{\"checks\":[{\"criterionIndex\":1,\"score\":4,\"rationale\":\"The fixture response follows the fixture instructions.\"}]}"
    static let overflowLastSpanID = "E0000000-0000-0000-0000-000000000038"
    static let longJudgeOutput = "Fixture judge output reached."
    private static let longJudgePrompt = "Trace inspector long-input test fixture.\n" + String(repeating: "Fixture input.\n", count: 240)

    static func write(to directory: URL, longJudgeEvidence: Bool = false) throws {
        let runs = directory.appending(path: "Runs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        var firstSample = recordedSample
        if longJudgeEvidence {
            firstSample["judgeTrace"] = [
                "instructions": "Apply the fixture rubric using the on-device judge.",
                "prompt": longJudgePrompt,
                "rawResponse": longJudgeOutput
            ]
        }
        let document: [String: Any] = [
            "id": "D0000000-0000-0000-0000-000000000001",
            "suiteID": "D0000000-0000-0000-0000-000000000002",
            "suiteName": runName,
            "suiteVersion": "fixture-v1",
            "instructions": "Trace inspector test fixture; no model or network request is executed.",
            "criteria": "Fixture response equals the expected text.",
            "scoringMode": "modelJudge",
            "judgePromptVersion": "fixture-v1",
            "judgePassingScore": 3,
            "repetitions": 1,
            "plannedSampleCount": 4,
            "startedAt": "2026-09-08T09:00:00Z",
            "completedAt": "2026-09-08T09:00:03Z",
            "cancelled": false,
            "environment": [
                "operatingSystem": "macOS test fixture",
                "locale": "en_GB",
                "model": "On-device model (test fixture)",
                "modelContextSize": 4096
            ],
            "attachments": [],
            "results": [firstSample, legacySample, cancelledSample, overflowingSample]
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: runs.appending(path: "trace-inspector-test-fixture.json"), options: .atomic)
    }

    private static var recordedSample: [String: Any] {
        var sample = baseSample(idPrefix: "A", name: "Native workflow with local tools", duration: 110)
        sample["score"] = 4
        sample["judgeDurationMilliseconds"] = 59
        sample["judgeUsage"] = ["inputTokens": 96, "cachedInputTokens": 0, "outputTokens": 28, "reasoningTokens": 0]
        sample["judgeTrace"] = [
            "instructions": "Apply the fixture rubric using the on-device judge.",
            "prompt": judgePrompt,
            "rawResponse": judgeResponse
        ]
        sample["featureTrace"] = [
            "customToolCalls": [],
            "profileEvents": [],
            "firstContentMilliseconds": 22.5
        ]
        sample["workflowTrace"] = ["timingSource": "App-observed monotonic clock", "spans": [
            span(id: rootID, kind: "sample", title: "Native workflow with local tools", offset: 0, duration: 170,
                 metadata: ["provider": "On device", "model": "SystemLanguageModel (test fixture)"]),
            span(id: preparationID, parent: rootID,
                 kind: "preparation", title: "Prepare input", offset: 0, duration: 5,
                 metadata: ["estimatedInputTokens": "64"]),
            span(id: generationID, parent: rootID, kind: "generation",
                 title: "Generate response", offset: 5, duration: 105,
                 metadata: ["role": "evaluation", "streaming": "true", "usageSource": "Framework-reported",
                            "inputTokens": "64", "cachedInputTokens": "8", "outputTokens": "12",
                            "reasoningTokens": "0", "firstContentMilliseconds": "22.5"]),
            span(id: "A0000000-0000-0000-0000-000000000004", parent: generationID,
                 kind: "tool", title: "Search fixture records", offset: 15, duration: 30),
            span(id: successRequestID, parent: "A0000000-0000-0000-0000-000000000004",
                 kind: "httpRequest", title: "POST /fixture/search", offset: 15, duration: 30,
                 metadata: ["method": "POST", "endpoint": "http://127.0.0.1:8765/fixture/search",
                            "statusCode": "200", "requestBytes": "26", "responseBytes": "128"]),
            span(id: "A0000000-0000-0000-0000-000000000006", parent: generationID,
                 kind: "tool", title: failedToolTitle, offset: 65, duration: 45,
                 status: "failed", error: "Fixture service unavailable"),
            span(id: failedRequestID, parent: "A0000000-0000-0000-0000-000000000006",
                 kind: "httpRequest", title: "POST /fixture/unavailable", offset: 65, duration: 45,
                 status: "failed", error: "Fixture service unavailable",
                 metadata: ["method": "POST", "endpoint": "http://127.0.0.1:8765/fixture/unavailable",
                            "statusCode": "503", "requestBytes": "26", "responseBytes": "0"]),
            span(id: scoringID, parent: rootID, kind: "scoring",
                 title: "Score response", offset: 110, duration: 60),
            span(id: judgeID, parent: scoringID, kind: "judge", title: "AI judge", offset: 111, duration: 59,
                 metadata: ["usageSource": "Framework-reported", "inputTokens": "96", "cachedInputTokens": "0",
                            "outputTokens": "28", "reasoningTokens": "0"])
        ]]
        return sample
    }

    private static var legacySample: [String: Any] {
        var sample = baseSample(idPrefix: "B", name: "Legacy durations", duration: 95)
        sample["timing"] = [
            "preparationMilliseconds": 5,
            "generationMilliseconds": 85,
            "scoringMilliseconds": 5
        ]
        return sample
    }

    private static var overflowingSample: [String: Any] {
        func identifier(_ index: Int) -> String {
            "E0000000-0000-0000-0000-" + String(format: "%012d", index)
        }
        let root = identifier(1)
        var sample = baseSample(idPrefix: "E", name: "Overflowing native workflow", duration: 880)
        var spans = [
            span(id: root, kind: "sample", title: "Overflowing native workflow", offset: 0, duration: 1_000),
            span(id: identifier(2), parent: root, kind: "preparation", title: "Prepare input", offset: 0, duration: 10)
        ]
        for index in 0..<32 {
            spans.append(span(id: identifier(index + 3), parent: root, kind: "generation",
                title: "Native setup turn \(index + 1)", offset: Double(10 + index * 25), duration: 20,
                metadata: ["role": "conversationSetup"]))
        }
        spans += [
            span(id: identifier(35), parent: root, kind: "generation", title: "Generate response", offset: 810, duration: 70),
            span(id: identifier(36), parent: root, kind: "scoring", title: "Score response", offset: 880, duration: 120),
            span(id: identifier(37), parent: identifier(36), kind: "judge", title: "AI judge", offset: 885, duration: 115),
            span(id: overflowLastSpanID, parent: identifier(37), kind: "generation", title: "Judge attempt 1",
                offset: 890, duration: 110, metadata: ["role": "judge", "judgeAttempt": "1"])
        ]
        sample["workflowTrace"] = ["timingSource": "App-observed monotonic clock", "spans": spans]
        sample["judgeTrace"] = [
            "instructions": "Apply the fixture rubric.", "prompt": judgePrompt, "rawResponse": judgeResponse,
            "attempts": [["prompt": judgePrompt, "rawResponse": judgeResponse]]
        ]
        return sample
    }

    private static var cancelledSample: [String: Any] {
        var sample = baseSample(idPrefix: "C", name: "Cancelled request", duration: 55)
        sample["status"] = "error"
        sample["response"] = ""
        sample["errorCategory"] = "cancelled"
        sample["errorMessage"] = "Fixture request cancelled before receiving a response"
        let root = "C0000000-0000-0000-0000-000000000001"
        let generation = "C0000000-0000-0000-0000-000000000002"
        let tool = "C0000000-0000-0000-0000-000000000003"
        sample["workflowTrace"] = ["timingSource": "App-observed monotonic clock", "spans": [
            span(id: root, kind: "sample", title: "Cancelled request", offset: 0, duration: 55, status: "cancelled"),
            span(id: generation, parent: root, kind: "generation", title: "Generate response",
                 offset: 5, duration: 50, status: "cancelled"),
            span(id: tool, parent: generation, kind: "tool", title: "Cancelled fixture lookup",
                 offset: 10, duration: 45, status: "cancelled"),
            span(id: cancelledRequestID, parent: tool, kind: "httpRequest", title: "POST /fixture/cancelled",
                 offset: 10, duration: 45, status: "cancelled",
                 error: "Fixture request cancelled before receiving a response",
                 metadata: ["method": "POST", "endpoint": "http://127.0.0.1:8765/fixture/cancelled",
                            "requestBytes": "26"])
        ]]
        return sample
    }

    private static func baseSample(idPrefix: String, name: String, duration: Double) -> [String: Any] {
        [
            "id": "\(idPrefix)1000000-0000-0000-0000-000000000001",
            "caseID": "\(idPrefix)2000000-0000-0000-0000-000000000001",
            "caseName": name,
            "repetition": 1,
            "prompt": "Return the fixture response after inspecting the fixture records.",
            "effectivePrompt": effectivePrompt,
            "expected": "Fixture response",
            "response": "Fixture response",
            "status": "passed",
            "durationMilliseconds": duration,
            "usage": ["inputTokens": 64, "cachedInputTokens": 8, "outputTokens": 12, "reasoningTokens": 0]
        ]
    }

    private static func span(
        id: String,
        parent: String? = nil,
        kind: String,
        title: String,
        offset: Double,
        duration: Double,
        status: String = "succeeded",
        error: String? = nil,
        metadata: [String: String] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "kind": kind,
            "title": title,
            "startOffsetMilliseconds": offset,
            "durationMilliseconds": duration,
            "status": status,
            "metadata": metadata
        ]
        value["parentID"] = parent
        value["errorMessage"] = error
        return value
    }
}
