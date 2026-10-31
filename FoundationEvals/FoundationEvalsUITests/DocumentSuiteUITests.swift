import XCTest
import CryptoKit

final class DocumentSuiteUITests: XCTestCase {
    private var app: XCUIApplication?
    private var storage: URL?

    /// Disable continuation after failure so UI assertions stop before mutating another fixture state.
    override func setUpWithError() throws { continueAfterFailure = false }
    /// Terminate the test application and remove its isolated workspace after each UI flow.
    override func tearDown() async throws {
        await app?.terminate()
        if let storage { try? FileManager.default.removeItem(at: storage) }
    }

    /// Verify that source review and accepted-suite creation work in light appearance.
    @MainActor func testReviewAndCreateDocumentSuiteInLightMode() throws { try reviewAndCreate(style: "Light") }
    /// Verify that source review and accepted-suite creation work in dark appearance.
    @MainActor func testReviewAndCreateDocumentSuiteInDarkMode() throws { try reviewAndCreate(style: "Dark") }

    /// Keep the acceptance action unavailable until unchecked evidence has an explicitly authorized reviewer.
    @MainActor func testUncheckedDraftCannotBeAcceptedWithoutAnAuthorizedJudge() throws {
        let app = try openDraft(style: "Light", semanticApproved: false)
        let create = app.buttons["Create document suite"]
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(app.staticTexts["Needs semantic check"].exists, app.debugDescription)
        app.scrollViews["Document draft review scroll"].scroll(byDeltaX: 0, deltaY: -1000)
        let accept = app.buttons["Accept document source review"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3))
        accept.click()
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(app.staticTexts["Authorize a semantic judge to check the edited draft."].waitForExistence(timeout: 3), app.debugDescription)
    }

    /// Exercise source review, acceptance, and suite creation in the requested appearance.
    @MainActor private func reviewAndCreate(style: String) throws {
        let app = try openDraft(style: style, semanticApproved: true)
        let storage = try XCTUnwrap(self.storage)
        let disclosure = app.staticTexts["Document semantic judge disclosure"]
        XCTAssertTrue(disclosure.exists, app.debugDescription)
        XCTAssertTrue((disclosure.value as? String ?? disclosure.label).contains("https://example.invalid/v1"), app.debugDescription)
        XCTAssertFalse(app.buttons["Resume generation"].isEnabled)
        let create = app.buttons["Create document suite"]
        XCTAssertFalse(create.isEnabled)
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

    /// Launch the application against synthetic draft storage and navigate to its document review screen.
    @MainActor private func openDraft(style: String, semanticApproved: Bool) throws -> XCUIApplication {
        let storage = try fixture(semanticApproved: semanticApproved)
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
        XCTAssertTrue(app.staticTexts["Suite name"].waitForExistence(timeout: 3))
        let create = app.buttons["Create document suite"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.textViews["Draft question"].waitForExistence(timeout: 3), app.debugDescription)
        return app
    }

    /// Write a synthetic workspace and document draft without accessing the user workspace or credentials.
    private func fixture(semanticApproved: Bool) throws -> URL {
        let directory = try UITestStorage.makeDirectory(prefix: "document-suite")
        let projectID = UUID().uuidString
        let suiteID = UUID().uuidString
        let caseID = UUID().uuidString
        let judgeID = UUID().uuidString
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
        var draftCase: [String: Any] = ["evaluationCase": evaluationCase, "discarded": false]
        if semanticApproved {
            // UI-only receipt fixture: live provider behavior is tested by the separate quality harness.
            let payload: [String: Any] = ["prompt": "Can members export a workspace?", "expected": evaluationCase["expected"]!,
                "criteria": evaluationCase["criteriaOverride"]!, "evidence": evidence]
            let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .map { String(format: "%02x", $0) }.joined()
            let checks: [[String: Any]] = (1...6).map { ["criterionIndex": $0, "score": 4, "rationale": "UI-only approved fixture"] }
            let questionChecks: [[String: Any]] = (1...3).map { ["criterionIndex": $0, "score": 4, "rationale": "UI-only independent question fixture"] }
            draftCase["semanticReview"] = ["policyVersion": "document-semantic-v6", "candidateDigest": digest,
                "connectionID": judgeID, "connectionDigest": "ui-fixture", "modelID": "ui-fixture",
                "checks": checks, "reviewedQuestions": [], "questionChecks": questionChecks,
                "questionRawResponse": String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": questionChecks]), as: UTF8.self),
                "rawResponse": String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": checks]), as: UTF8.self)]
        }
        var draft: [String: Any] = ["id": UUID().uuidString, "formatVersion": 1, "projectID": projectID,
            "destinationSuiteID": UUID().uuidString, "name": "Document UI fixture", "source": source,
            "selectedPassageIDs": ["page-6-1"], "requestedCount": 5, "cases": [draftCase], "requiresSemanticReview": true,
            "completedBatchIDs": ["page-6-1:0"], "issues": [:], "generationVersion": "document-draft-v1"]
        if semanticApproved {
            draft["semanticJudgeID"] = judgeID
            let connection: [String: Any] = ["id": judgeID, "name": "UI fixture judge", "kind": "customCompatible",
                "baseURL": "https://example.invalid/v1", "modelID": "ui-fixture", "generationPolicy": "portable",
                "capabilities": ["structuredOutputs": true, "multimodal": false, "contextWindowTokens": 8192]]
            try JSONSerialization.data(withJSONObject: [connection], options: [.sortedKeys])
                .write(to: directory.appending(path: "judge-connections.json"), options: .atomic)
        }
        let draftURL = directory.appending(path: "DocumentDrafts/\(projectID).json")
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(draft, to: draftURL)
        return directory
    }

    /// Serialize synthetic UI fixture data to its temporary destination.
    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
