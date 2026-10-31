import Network
import XCTest

final class FoundationEvalsRunLifecycleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storage: URL!
    private var fixture: LocalHTTPModelFixture!

    @MainActor
    private var runStatus: XCUIElement {
        app.descendants(matching: .any)["Run status"]
    }

    /// Creates isolated storage and a local model fixture before launching the UI application.
    override func setUp() async throws {
        continueAfterFailure = false
        storage = try UITestStorage.makeDirectory(prefix: "run-lifecycle")
        fixture = try LocalHTTPModelFixture()
        app = try await Self.launchApp(storage: storage)
    }

    /// Terminates the UI fixture on its actor and releases the loopback model and isolated files.
    override func tearDown() async throws {
        await app?.terminate()
        fixture?.stop()
        if let storage {
            try? FileManager.default.removeItem(at: storage)
        }
        app = nil
        fixture = nil
        storage = nil
    }

    @MainActor
    /// Runs a streamed response to completion and verifies its report survives an app restart.
    func testRunProgressCompletionAndHistoryRestoration() throws {
        try openSuiteEditor()
        configureSuite(name: "UI lifecycle fixture", endpointPath: "/success")

        let run = app.buttons["Run evaluation"]
        XCTAssertTrue(run.waitForExistence(timeout: 3))
        run.click()

        XCTAssertTrue(fixture.waitForRequest(timeout: 5), "The run must reach the loopback provider")
        XCTAssertTrue(app.staticTexts["Evaluation in progress"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 of 1 responses"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Cancel"].exists)

        fixture.finishResponse()
        XCTAssertTrue(app.buttons["Export Run as JSON"].waitForExistence(timeout: 8))
        openRunReport()
        XCTAssertTrue(runStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(runStatus.label, "Completed")
        let performance = app.radioButtons["Performance"]
        XCTAssertTrue(performance.waitForExistence(timeout: 3))
        performance.click()
        XCTAssertTrue(app.staticTexts["Scored pass rate"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["100%"].firstMatch.exists, app.debugDescription)

        app.terminate()
        app = try Self.launchApp(storage: storage)
        try openSuiteEditor()

        let savedRun = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND value CONTAINS %@", "UI lifecycle fixture", "passed")
        ).firstMatch
        XCTAssertTrue(savedRun.waitForExistence(timeout: 5), "The completed run must return in Run History after relaunch")
        savedRun.click()
        XCTAssertTrue(app.buttons["Export Run as JSON"].waitForExistence(timeout: 3))
        openRunReport()
        XCTAssertTrue(runStatus.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(runStatus.label, "Completed")
    }

    /// Cancels a held-open request and retains its cancelled report before the provider finishes.
    @MainActor
    func testCancelShowsCancelledRun() throws {
        try openSuiteEditor()
        configureSuite(name: "UI cancellation fixture", endpointPath: "/success")

        app.buttons["Run evaluation"].click()
        XCTAssertTrue(fixture.waitForRequest(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        capture("active-run-cancellation")
        cancel.click()

        XCTAssertTrue(app.buttons["Export Run as JSON"].waitForExistence(timeout: 8))
        openRunReport()
        XCTAssertTrue(runStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(runStatus.label, "Cancelled")
        capture("cancelled-run-report")
        fixture.finishResponse()
    }

    /// A running evaluation locks scoring edits without locking its read-only explanation.
    @MainActor
    func testScoringGuideRemainsAvailableDuringRun() throws {
        try openSuiteEditor()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appending(path: "workspace-v1.json").path),
                      "The test must use its isolated workspace")
        configureSuite(name: "Scoring guide fixture", endpointPath: "/success")
        let guided = app.checkBoxes["Guided generation"]
        XCTAssertTrue(guided.waitForExistence(timeout: 3))
        guided.click()
        selectSetup("Scoring")
        app.radioButtons["AI rubric"].click()
        let criteria = app.textViews["AI rubric requirements"]
        XCTAssertTrue(criteria.waitForExistence(timeout: 3))
        replaceText(in: criteria, with: "The response answers the question.")
        let run = app.buttons["Run evaluation"]
        XCTAssertTrue(run.isEnabled, app.debugDescription)
        run.click()
        XCTAssertTrue(fixture.waitForRequest(timeout: 5))

        selectSetup("Scoring")
        let guide = app.disclosureTriangles["How scoring works"]
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        XCTAssertTrue(guide.isEnabled)
        XCTAssertFalse(criteria.isEnabled)
        let editor = app.scrollViews["Suite editor scroll"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.20))
            .scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(guide.isHittable && editor.frame.contains(guide.frame), app.debugDescription)
        guide.click()
        let score = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Passing score: 3 or 4", "Passing score: 3 or 4")
        XCTAssertTrue(app.staticTexts.matching(score).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.click()
        fixture.finishResponse()
    }

    @MainActor
    func testPromptImprovementKeepsCancellationEnabled() throws {
        app.terminate()
        app.launchArguments.append("--prompt-improvement-test-suggestions")
        app.launch()
        try openSuiteEditor()
        configureSuite(name: "Instruction cancellation fixture", endpointPath: "/success")
        app.radioButtons["Cases"].click()
        app.buttons["Add Case"].click()
        replaceText(in: app.textViews["Case prompt"], with: "Return the fixture response.")
        replaceText(in: app.textViews["Scoring expected text"], with: "Deterministic fixture stream.")
        selectSetup("Instructions")
        app.buttons["Improve instructions"].click()
        let sheet = app.sheets.firstMatch
        let generate = sheet.buttons["Generate and compare instructions"]
        XCTAssertTrue(generate.waitForExistence(timeout: 3))
        generate.click()
        XCTAssertTrue(fixture.waitForRequest(timeout: 5), app.debugDescription)
        let cancel = sheet.buttons["Cancel run"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.isEnabled, "The disabled Setup editor must not disable its presented sheet")
        XCTAssertTrue(sheet.buttons["Done"].isEnabled)
        sheet.buttons["Done"].click()
        let reopen = app.buttons["Improve instructions"]
        XCTAssertTrue(reopen.isEnabled)
        reopen.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.descendants(matching: .any)["Instruction comparison progress"].exists)
        cancel.click()
        fixture.finishResponse()
        let cancelled = textContaining("Comparison cancelled", in: sheet)
        XCTAssertTrue(cancelled.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(sheet.buttons["Apply validated instructions"].exists)
        capture("prompt-improvement-cancelled")
        sheet.buttons["New comparison"].click()
        XCTAssertTrue(generate.isEnabled)
        sheet.buttons["History"].click()
        XCTAssertTrue(sheet.descendants(matching: .any)["Instruction comparison history"].exists)
        capture("prompt-improvement-history")
    }

    @MainActor
    func testPromptImprovementRoutesToMissingSetup() throws {
        try openSuiteEditor()
        selectSetup("Instructions")
        app.buttons["Improve instructions"].click()
        let sheet = app.sheets.firstMatch
        let configure = sheet.buttons["Configure instruction comparison"]
        XCTAssertTrue(configure.waitForExistence(timeout: 3))
        XCTAssertFalse(sheet.buttons["Generate and compare instructions"].exists)
        capture("prompt-improvement-add-cases")
        configure.click()
        XCTAssertTrue(app.buttons["Add Case"].waitForExistence(timeout: 3))
        app.buttons["Add Case"].click()
        selectSetup("Scoring")
        app.radioButtons["Collect only"].click()
        selectSetup("Instructions")
        app.buttons["Improve instructions"].click()
        XCTAssertTrue(configure.waitForExistence(timeout: 3))
        XCTAssertTrue(textContaining("Choose a scoring method", in: sheet).exists)
        capture("prompt-improvement-choose-scoring")
        configure.click()
        XCTAssertTrue(app.radioButtons["Collect only"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testPromptImprovementGuidesSetupReviewAndApply() throws {
        app.terminate()
        app.launchArguments += ["--prompt-improvement-test-suggestions", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        try openSuiteEditor()
        configureSuite(name: "Instruction comparison fixture", endpointPath: "/improve")
        app.radioButtons["Cases"].click()
        app.buttons["Add Case"].click()
        replaceText(in: app.textViews["Case prompt"], with: "Return the fixture response.")
        replaceText(in: app.textViews["Scoring expected text"], with: "Deterministic fixture stream.")
        selectSetup("Instructions")
        app.buttons["Improve instructions"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.descendants(matching: .any)["Instruction comparison setup"].waitForExistence(timeout: 3))
        capture("prompt-improvement-setup")
        sheet.disclosureTriangles["Choose examples"].click()
        XCTAssertTrue(sheet.checkBoxes.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(sheet.checkBoxes.count, 2)
        let reserved = sheet.checkBoxes.element(boundBy: 1)
        XCTAssertTrue(reserved.exists)
        // The final-check row starts below the fixed footer in a compact window.
        let examples = sheet.scrollViews.firstMatch
        examples.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        XCTAssertTrue(reserved.isHittable && examples.frame.contains(reserved.frame), app.debugDescription)
        reserved.click()
        let generate = sheet.buttons["Generate and compare instructions"]
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed)
        let practice = sheet.checkBoxes.firstMatch
        practice.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        generate.click()
        XCTAssertTrue(textContaining("A better suggestion is ready", in: sheet).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(sheet.buttons["Apply validated instructions"].isEnabled)
        XCTAssertTrue(sheet.descendants(matching: .any)["Instruction comparison outcome"].exists)
        capture("prompt-improvement-result")
        sheet.buttons["Apply validated instructions"].click()
        XCTAssertTrue(textContaining("Suggestion applied", in: sheet).waitForExistence(timeout: 3))
        XCTAssertFalse(sheet.buttons["Apply validated instructions"].exists)
        capture("prompt-improvement-applied")
        sheet.buttons["Done"].click()
        XCTAssertTrue(app.textViews["Model instructions"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["OK"].exists, "The result screen already confirms application; closing it must not show a stale success alert")
        XCTAssertTrue((app.textViews["Model instructions"].value as? String)?.contains("Return only the answer.") == true)
    }

    @MainActor
    private func textContaining(_ value: String, in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    /// Retains only the fixture window, excluding other apps and desktop content from test evidence.
    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProviderFailureProducesAnIssueRun() throws {
        try openSuiteEditor()
        configureSuite(name: "UI provider failure fixture", endpointPath: "/failure")

        app.buttons["Run evaluation"].click()
        XCTAssertTrue(fixture.waitForRequest(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Export Run as JSON"].waitForExistence(timeout: 8), app.debugDescription)
        openRunReport()
        XCTAssertTrue(runStatus.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(runStatus.label, "Completed with issues")
    }

    /// Launches the isolated UI fixture on the main actor without transferring the test instance.
    @MainActor
    private static func launchApp(storage: URL) throws -> XCUIApplication {
        let launchedApp = XCUIApplication()
        launchedApp.launchArguments += [
            "--disable-mcp-autostart",
            "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1000", "--evaluation-window-height", "700",
            "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"
        ]
        launchedApp.launch()
        do {
            try UITestStorage.requireNoAlert(in: launchedApp)
        } catch {
            launchedApp.terminate()
            throw error
        }
        return launchedApp
    }

    @MainActor
    private func openSuiteEditor() throws {
        try UITestStorage.requireNoAlert(in: app)
        app.activate()
        try UITestStorage.requireNoAlert(in: app)
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        try UITestStorage.waitFor(app.buttons["Run evaluation"], in: app, timeout: 5)
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.exists { showSidebar.click() }
    }

    @MainActor
    private func openRunReport() {
        let report = app.radioButtons["Report"]
        XCTAssertTrue(report.waitForExistence(timeout: 3), app.debugDescription)
        report.click()
    }

    @MainActor
    private func configureSuite(name: String, endpointPath: String) {
        replaceText(in: app.textFields["Suite name"], with: name)

        selectSetup("Scoring")
        app.radioButtons["Exact text"].click()
        app.radioButtons["Cases"].click()
        let expected = app.textViews["Scoring expected text"]
        XCTAssertTrue(expected.waitForExistence(timeout: 3))
        replaceText(in: expected, with: "Deterministic fixture stream.")

        selectSetup("Model")
        let provider = app.popUpButtons["Model provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        provider.click()
        app.menuItems["Custom local HTTP model"].click()

        let endpoint = app.textFields["Custom provider endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        let endpointURL = "http://127.0.0.1:\(fixture.port)\(endpointPath)"
        replaceText(in: endpoint, with: endpointURL)
        XCTAssertEqual(endpoint.value as? String, endpointURL)
        // End endpoint editing and bring the run controls back into view.
        app.textFields["Suite name"].click()
        XCTAssertTrue(app.buttons["Run evaluation"].isEnabled, app.debugDescription)
    }

    @MainActor
    private func selectSetup(_ title: String) {
        app.radioButtons["Setup"].click()
        let menu = app.popUpButtons["Suite setup"]
        if menu.exists {
            menu.click()
            app.menuItems[title].click()
        } else {
            app.buttons[title].click()
        }
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with value: String) {
        app.activate()
        element.click()
        element.typeKey("a", modifierFlags: .command)
        // Xcode 27's bulk text input drops colons on this keyboard layout.
        for (index, part) in value.components(separatedBy: ":").enumerated() {
            if index > 0 { element.typeKey(";", modifierFlags: .shift) }
            if !part.isEmpty { element.typeText(part) }
        }
    }
}

private final class LocalHTTPModelFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FoundationEvalsUITests.HTTPFixture", attributes: .concurrent)
    private let ready = DispatchSemaphore(value: 0)
    private let requestReceived = DispatchSemaphore(value: 0)
    private let responseGate = DispatchSemaphore(value: 0)
    private var listenerFailureDescription: String?
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener.port?.rawValue ?? 0
                self.ready.signal()
            case .failed(let error):
                self.listenerFailureDescription = error.localizedDescription
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        let readiness = ready.wait(timeout: .now() + 5)
        guard readiness == .success, port != 0 else {
            listener.cancel()
            let detail = readiness == .timedOut
                ? "Timed out waiting for the loopback listener to become ready."
                : listenerFailureDescription ?? "The loopback listener failed without a Network.framework error."
            throw FixtureError.failedToListen(detail)
        }
    }

    func waitForRequest(timeout: TimeInterval) -> Bool {
        requestReceived.wait(timeout: .now() + timeout) == .success
    }

    func finishResponse() {
        responseGate.signal()
    }

    func stop() {
        responseGate.signal()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil else {
                connection.cancel()
                return
            }
            let headerBoundary = request.range(of: Data("\r\n\r\n".utf8))
            let header = headerBoundary.map { String(decoding: request[..<$0.lowerBound], as: UTF8.self) } ?? ""
            let contentLength = header.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-length:")
            }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard let headerBoundary, request.count - headerBoundary.upperBound >= contentLength else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, accumulated: request)
                }
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        requestReceived.signal()
        let requestLine = String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first ?? ""
        if requestLine.contains(" /failure ") {
            send(
                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                on: connection,
                complete: true
            )
            return
        }

        if requestLine.contains(" /improve ") {
            let body = String(decoding: request, as: UTF8.self)
            let response = body.contains("Return only the answer.") ? "Deterministic fixture stream." : "Wrong answer."
            let event = "{\"kind\":\"response\",\"action\":\"append\",\"content\":\"\(response)\",\"tokenCount\":4}\n"
            send("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n" + event, on: connection, complete: true)
            return
        }
        let firstEvent = #"{"kind":"response","action":"append","content":"Deterministic fixture stream.","tokenCount":4}"# + "\n"
        send(
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n" + firstEvent,
            on: connection,
            complete: false
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.responseGate.wait()
            let usage = #"{"kind":"usage","usageTarget":"response","usage":{"inputTokens":12,"cachedInputTokens":0,"outputTokens":4,"reasoningTokens":0}}"# + "\n"
            self.send(usage, on: connection, complete: true)
        }
    }

    private func send(_ string: String, on connection: NWConnection, complete: Bool) {
        connection.send(
            content: Data(string.utf8),
            contentContext: .defaultMessage,
            isComplete: complete,
            completion: .contentProcessed { _ in
                if complete { connection.cancel() }
            }
        )
    }

    private enum FixtureError: LocalizedError {
        case failedToListen(String)

        var errorDescription: String? {
            switch self {
            case .failedToListen(let detail):
                "Could not start the UI test loopback fixture: \(detail)"
            }
        }
    }
}
