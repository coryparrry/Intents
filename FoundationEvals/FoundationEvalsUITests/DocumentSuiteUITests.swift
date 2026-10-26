import XCTest

final class DocumentSuiteUITests: XCTestCase {
    private var app: XCUIApplication?
    private var storage: URL?

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        app?.terminate()
        if let storage { try? FileManager.default.removeItem(at: storage) }
    }

    @MainActor func testReviewAndCreateDocumentSuiteInLightMode() throws { try reviewAndCreate(style: "Light") }
    @MainActor func testReviewAndCreateDocumentSuiteInDarkMode() throws { try reviewAndCreate(style: "Dark") }

    @MainActor private func reviewAndCreate(style: String) throws {
        let storage = try fixture()
        self.storage = storage
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1180", "--evaluation-window-height", "850",
            "-AppleInterfaceStyle", style, "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"]
        app.launch()
        try UITestStorage.openSuiteEditor(in: app)
        let newSuite = app.buttons["New Suite"].firstMatch
        XCTAssertTrue(newSuite.waitForExistence(timeout: 5), app.debugDescription)
        newSuite.click()
        let fromDocument = app.buttons["New suite from document"]
        XCTAssertTrue(fromDocument.waitForExistence(timeout: 3), app.debugDescription)
        fromDocument.click()
        let create = app.buttons["Create document suite"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(app.textViews["Draft question"].waitForExistence(timeout: 3), app.debugDescription)
        let review = app.scrollViews["Document draft review scroll"]
        XCTAssertTrue(review.exists, app.debugDescription)
        review.scroll(byDeltaX: 0, deltaY: -1000)
        let accept = app.buttons["Accept document source review"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(accept.isEnabled, app.debugDescription)
        accept.click()
        XCTAssertTrue(create.isEnabled, app.debugDescription)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Document source review \(style)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(to: UITestStorage.screenshotURL(name: "document-suite-\(style.lowercased())"))
        create.click()
        XCTAssertTrue(app.buttons["Run evaluation"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Create document suite"].exists, app.debugDescription)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.appending(path: "workspace-v1.json"))) as? [String: Any])
        let projects = try XCTUnwrap(catalog["projects"] as? [[String: Any]])
        let suites = try XCTUnwrap(projects.first?["suites"] as? [[String: Any]])
        XCTAssertEqual(suites.count, 2)
        XCTAssertTrue(suites.contains { $0["name"] as? String == "Document UI fixture" })
        app.terminate()
        app.launch()
        try UITestStorage.openSuiteEditor(in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    private func fixture() throws -> URL {
        let directory = try UITestStorage.makeDirectory(prefix: "document-suite")
        let projectID = UUID().uuidString
        let suiteID = UUID().uuidString
        let caseID = UUID().uuidString
        let date = "2026-10-26T12:00:00Z"
        let location = directory.appending(path: "Projects/\(projectID)/Suites/\(suiteID)")
        try FileManager.default.createDirectory(at: location.appending(path: "Runs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: location.appending(path: "Attachments"), withIntermediateDirectories: true)
        let catalog: [String: Any] = ["formatVersion": 1, "selectedProjectID": projectID, "projects": [[
            "id": projectID, "name": "Document UI verification", "createdAt": date, "updatedAt": date,
            "selectedSuiteID": suiteID, "suites": [["id": suiteID, "name": "Initial", "createdAt": date, "updatedAt": date]]
        ]]]
        try write(catalog, to: directory.appending(path: "workspace-v1.json"))
        try write(["id": suiteID, "name": "Initial", "cases": [["id": UUID().uuidString, "name": "Case", "prompt": "Say ready", "expected": "ready"]]], to: location.appending(path: "suite.json"))
        let passage: [String: Any] = ["id": "page-6-1", "location": "Page 6", "text": "Owners can export a workspace. Members can view reports but cannot export a workspace."]
        let source: [String: Any] = ["name": "Guide.pdf", "fileDigest": String(repeating: "a", count: 64), "passages": [passage], "warnings": []]
        let evidence: [String: Any] = ["formatVersion": 1, "sourceName": "Guide.pdf", "sourceDigest": String(repeating: "a", count: 64),
            "extractionVersion": 1, "passages": [passage], "citations": [["id": UUID().uuidString, "passageID": "page-6-1", "quote": "Owners can export a workspace."]],
            "questionType": "Apply a rule", "generator": "UI fixture", "generatorVersion": "document-draft-v1"]
        let evaluationCase: [String: Any] = ["id": caseID, "name": "Workspace exports", "prompt": ["format": "document-case-v1", "text": "Can members export a workspace?"],
            "expected": "No. Only owners can export.", "criteriaOverride": ["States that members cannot export.", "Identifies the owner role."], "documentEvidence": evidence]
        let draft: [String: Any] = ["id": UUID().uuidString, "formatVersion": 1, "projectID": projectID,
            "destinationSuiteID": UUID().uuidString, "name": "Document UI fixture", "source": source,
            "selectedPassageIDs": ["page-6-1"], "requestedCount": 5, "cases": [["evaluationCase": evaluationCase, "discarded": false]],
            "completedBatchIDs": ["page-6-1:0"], "issues": [:], "generationVersion": "document-draft-v1"]
        let draftURL = directory.appending(path: "DocumentDrafts/\(projectID).json")
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(draft, to: draftURL)
        return directory
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
