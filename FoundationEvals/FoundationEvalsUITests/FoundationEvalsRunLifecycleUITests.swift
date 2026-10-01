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

    override func setUpWithError() throws {
        continueAfterFailure = false
        storage = try UITestStorage.makeDirectory(prefix: "run-lifecycle")
        fixture = try LocalHTTPModelFixture()
        app = try launchApp()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.stop()
        if let storage {
            try? FileManager.default.removeItem(at: storage)
        }
        app = nil
        fixture = nil
        storage = nil
    }

    @MainActor
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
        XCTAssertTrue(app.staticTexts["Scored pass rate"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["100%"].firstMatch.exists, app.debugDescription)

        app.terminate()
        app = try launchApp()
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

    @MainActor
    func testCancelShowsCancelledRun() throws {
        try openSuiteEditor()
        configureSuite(name: "UI cancellation fixture", endpointPath: "/success")

        app.buttons["Run evaluation"].click()
        XCTAssertTrue(fixture.waitForRequest(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()

        XCTAssertTrue(app.buttons["Export Run as JSON"].waitForExistence(timeout: 8))
        openRunReport()
        XCTAssertTrue(runStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(runStatus.label, "Cancelled")
        fixture.finishResponse()
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

    private func launchApp() throws -> XCUIApplication {
        try UITestStorage.verifyWritable(storage)
        let launchedApp = XCUIApplication()
        launchedApp.launchArguments += [
            "--disable-mcp-autostart",
            "--evaluation-storage", storage.path,
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
        try UITestStorage.waitFor(app.buttons["Run"], in: app, timeout: 5)
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

        app.radioButtons["Scoring"].click()
        app.radioButtons["Exact text"].click()
        let expected = app.textViews["Scoring expected text"]
        XCTAssertTrue(expected.waitForExistence(timeout: 3))
        // The summary cards place the nested text editor below the initial viewport.
        app.scrollViews.containing(.textField, identifier: "Suite name").firstMatch
            .scroll(byDeltaX: 0, deltaY: -480)
        replaceText(in: expected, with: "Deterministic fixture stream.")

        app.radioButtons["Model"].click()
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
        XCTAssertTrue(app.staticTexts["Ready to run"].waitForExistence(timeout: 3), app.debugDescription)
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
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
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
