import XCTest

final class MacPreparationUITests: XCTestCase {
    /// Exercises the native popup and its selection callback without preparing or building an app.
    @MainActor
    func testAppPickerSelectsSourceTargetWithoutAnAccessibilityLabel() throws {
        executionTimeAllowance = 120; continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "native-mac-app-picker")
        defer { try? FileManager.default.removeItem(at: storage) }
        let project = storage.appendingPathComponent("PickerFixture.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let objects: [String: Any] = [
            "IOS": ["isa": "PBXNativeTarget", "name": "AutomationFixture",
                    "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS"],
            "MAC": ["isa": "PBXNativeTarget", "name": "AutomationFixtureMac",
                    "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS"],
            "CONFIGS": ["buildConfigurations": ["DEBUG"]],
            "DEBUG": ["name": "Debug"]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--automation-select-path", project.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launch(); defer { app.terminate() }
        app.activate(); app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(automationAppPicker(in: app, selectedApp: "AutomationFixture"), item: "AutomationFixtureMac")
        _ = automationAppPicker(in: app, selectedApp: "AutomationFixtureMac")
        selectAutomationMenu(app.popUpButtons["automation.preparation.destination"], item: "macOS")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        let review = automationConfirmation(in: app, title: "Build the selected app?")
        // Resolve the real sheet action even when macOS also publishes its Touch Bar mirror.
        XCTAssertEqual(review.buttons.matching(identifier: "Build private copy").count, 1)
        XCTAssertTrue(review.buttons["Build private copy"].isEnabled)
        review.buttons["Cancel"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: review)], timeout: 5), .completed)
        let route = app.popUpButtons["automation.workflow.route"]
        revealAutomationControl(route, in: app)
        let selectedMac = automationAppPicker(in: app, selectedApp: "AutomationFixtureMac")
        revealAutomationControl(selectedMac, in: app)
        selectAutomationMenu(selectedMac, item: "AutomationFixture")
        _ = automationAppPicker(in: app, selectedApp: "AutomationFixture")
        XCTAssertFalse(app.buttons["Build private copy"].exists)
        XCTAssertFalse(app.buttons["Run approved workflow"].exists)
    }

    /// Opt-in: prepares the committed Mac fixture and runs approved native routes.
    @MainActor
    func testSelectedToolchainPreparesMacCopyAndRunsApprovedWorkflows() throws {
        executionTimeAllowance = 900
        let fixture = try AutomationFixtureUITestSupport(requiresSimulator: false)
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "native-mac-preparation")
        print("NATIVE_MAC_PREPARATION_STORAGE=\(storage.path)")
        // Keep build provenance and screenshots for inspection.
        let app = XCUIApplication()
        fixture.configure(app, storage: storage)
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(automationAppPicker(in: app, selectedApp: "AutomationFixture"), item: "AutomationFixtureMac")
        _ = automationAppPicker(in: app, selectedApp: "AutomationFixtureMac")
        selectAutomationMenu(app.popUpButtons["automation.preparation.destination"], item: "macOS")
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "ui")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        let build = automationConfirmation(in: app, title: "Build the selected app?").buttons["Build private copy"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "build-review")
        build.click()
        let ready = app.staticTexts["Prepared a private Mac copy. Choose a system action or exact UI steps and review their permitted effects."]
        XCTAssertTrue(ready.waitForExistence(timeout: 300), app.debugDescription)

        let automation = storage.appendingPathComponent("Automation")
        let preparations = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("prepare-") }
        XCTAssertEqual(preparations.count, 1)
        let prepared = try object(try XCTUnwrap(preparations.first).appendingPathComponent("prepared-application.json"))
        let host = try XCTUnwrap(prepared["host"] as? [String: Any])
        let identity = try XCTUnwrap(host["app"] as? [String: Any])
        XCTAssertEqual(identity["bundleID"] as? String, AutomationFixtureUITestSupport.macBundleID)
        XCTAssertEqual(identity["platform"] as? String, "macos")
        XCTAssertEqual((host["target"] as? [String: Any])?["kind"] as? String, "nativeMac")
        let product = URL(fileURLWithPath: try XCTUnwrap(host["subjectProductPath"] as? String))
        let metadata = try object(product.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata"))
        XCTAssertEqual(metadata["version"] as? Int, 1)
        let catalog = try XCTUnwrap(prepared["catalog"] as? [String: Any])
        let actions = try XCTUnwrap(catalog["systemActions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains { ($0["typeName"] as? String)?.hasSuffix("EchoIntegerArrayIntent") == true })
        XCTAssertTrue(actions.contains { ($0["typeName"] as? String)?.hasSuffix("CompleteTaskIntent") == true })

        try capture(app, storage: storage, name: "prepared-mac-copy")
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "system")
        selectAutomationMenu(app.popUpButtons["automation.action"], item: "Echo integer array")
        let input = app.textFields["value (JSON list of whole numbers)"]
        revealAutomationControl(input, in: app); input.click(); input.typeText("[1,2]")
        XCTAssertEqual(input.value as? String, "[1,2]")
        let actionEffects = app.popUpButtons["Effects of this action"]
        revealAutomationControl(actionEffects, in: app)
        selectAutomationMenu(actionEffects, item: "Observation and navigation")
        XCTAssertEqual(actionEffects.value as? String, "Observation and navigation")
        let runAction = app.buttons["Run action…"]
        XCTAssertFalse(runAction.isEnabled, "The action must require explicit effect consent")
        confirmAutomationEffects(app.checkBoxes["I confirm this action stays within these effects"], in: app)
        XCTAssertFalse(app.checkBoxes["Allow starting this simulator and installing the prepared app"].exists)
        revealAutomationControl(runAction, in: app)
        XCTAssertTrue(runAction.isEnabled, app.debugDescription); runAction.click()
        let approveAction = automationConfirmation(in: app, title: "Run the selected workflow?").buttons["Run approved workflow"]
        XCTAssertTrue(approveAction.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "typed-action-review")
        approveAction.click()
        let actionCompleted = app.staticTexts["Executed · unassessed"].waitForExistence(timeout: 180)
        if !actionCompleted { attachNativeExecutionFailureLogs(storage: storage) }
        XCTAssertTrue(actionCompleted, app.debugDescription)
        try capture(app, storage: storage, name: "typed-action-result")

        let route = app.popUpButtons["automation.workflow.route"]
        revealAutomationControl(route, in: app)
        selectAutomationMenu(route, item: "ui")
        let instruction = app.textFields["What should the app do?"]
        revealAutomationControl(instruction, in: app); instruction.click(); instruction.typeText("Observe the fixture controls")
        let endpoint = app.textFields["Destination control"]
        revealAutomationControl(endpoint, in: app); endpoint.click(); endpoint.typeText("id:fixture.control")
        let expected = app.textFields["Expected property value (optional)"]
        revealAutomationControl(expected, in: app); expected.click(); expected.typeText("Control")
        let workflowEffects = app.popUpButtons["Effects of this workflow"]
        revealAutomationControl(workflowEffects, in: app)
        selectAutomationMenu(workflowEffects, item: "Observation and navigation")
        confirmAutomationEffects(app.checkBoxes["I confirm this workflow stays within these effects"], in: app)
        let runWorkflow = app.buttons["Run workflow…"]
        revealAutomationControl(runWorkflow, in: app)
        XCTAssertTrue(runWorkflow.isEnabled, app.debugDescription); runWorkflow.click()
        let approveUI = automationConfirmation(in: app, title: "Run the selected workflow?").buttons["Run approved workflow"]
        XCTAssertTrue(approveUI.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "ui-workflow-review")
        approveUI.click()
        let workflowPassed = app.staticTexts["Passed the approved requirements"].waitForExistence(timeout: 180)
        if !workflowPassed { attachNativeExecutionFailureLogs(storage: storage) }
        XCTAssertTrue(workflowPassed, app.debugDescription)
        try capture(app, storage: storage, name: "ui-workflow-result")
        let reports = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("report.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(reports.count, 2)
        for reportURL in reports {
            XCTAssertEqual(try object(reportURL)["resourcesReleased"] as? Bool, true)
        }
        try fixture.assertSourceUnchanged()
    }
    func testNativeFailureDiagnosticsRedactCredentialsAndEnvironment() {
        let text = [
            "error: Testing failed because the test runner exited",
            "Authorization: Bearer fixture-authorization",
            "SIGNING_PASSWORD=fixture-password",
            "opaque value sk-proj-fixture123",
            "opaque value ghp_fixture123",
            "    export DEVELOPER_DIR=/Applications/Xcode.app",
            "EnvironmentVariables: withheld",
            "Test session failed to start"
        ].joined(separator: "\n")
        let redacted = redactedNativeDiagnostic(text)
        XCTAssertTrue(redacted.contains("error: Testing failed because the test runner exited"))
        XCTAssertTrue(redacted.contains("Test session failed to start"))
        for withheld in ["fixture-authorization", "fixture-password", "sk-proj-fixture123",
                         "ghp_fixture123", "/Applications/Xcode.app", "EnvironmentVariables"] {
            XCTAssertFalse(redacted.contains(withheld))
        }
    }

    private func redactedNativeDiagnostic(_ text: String) -> String {
        let credential = #"(?i)authorization|bearer|token|secret|password|passwd|api[ _-]?key|private[ _-]?key|credential|cookie|signature"#
        let value = #"sk-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|AKIA[A-Z0-9]{16}"#
        let environment = #"(?i)^\s*(export\s|environment variables|environmentvariables|setenv\s|[A-Z_][A-Z0-9_]*=)"#
        return text.components(separatedBy: .newlines).map { line in
            [credential, value, environment].contains { line.range(of: $0, options: .regularExpression) != nil }
                ? "[redacted credential or environment line]" : line
        }.joined(separator: "\n")
    }

    func testNativeFailureDiagnosticsSelectLatestCreatedAttempt() throws {
        let storage = try UITestStorage.makeDirectory(prefix: "native-attempt-diagnostic-selection")
        defer { try? FileManager.default.removeItem(at: storage) }
        let earlier = storage.appendingPathComponent("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        let later = storage.appendingPathComponent("00000000-0000-0000-0000-000000000000")
        let preparation = storage.appendingPathComponent("prepare-most-recent")
        for (index, directory) in [earlier, later, preparation].enumerated() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))],
                                                  ofItemAtPath: directory.path)
        }
        XCTAssertEqual(latestNativeAttempt(in: storage)?.standardizedFileURL.path, later.standardizedFileURL.path)
    }

    private func latestNativeAttempt(in automation: URL) -> URL? {
        let candidates = try? FileManager.default.contentsOfDirectory(at: automation,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        return candidates?.compactMap { url -> (url: URL, created: Date)? in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate else { return nil }
            return (url, created)
        }.max { $0.created < $1.created }?.url
    }

    func testNativeFailureDiagnosticsRetainPreflightFailureWithoutInnerArtifacts() throws {
        let attempt = try UITestStorage.makeDirectory(prefix: "native-preflight-diagnostic")
        defer { try? FileManager.default.removeItem(at: attempt) }
        let xcuitest = attempt.appendingPathComponent("xcuitest")
        try FileManager.default.createDirectory(at: xcuitest, withIntermediateDirectories: true)
        let artifacts = attempt.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let report: [String: Any] = ["resourcesReleased": true, "result": [
            "summary": "infrastructureFailed", "subjectDispatched": false,
            "subjectCompleted": false, "evidenceComplete": false], "servedJavaScriptResponses": ["private": "withheld-response"]]
        try JSONSerialization.data(withJSONObject: report).write(to: attempt.appendingPathComponent("report.json"))
        let failure = ["stage": "xcuitest-execution", "errorType": "AutomationContractError",
            "message": "Private Mac app registration failed\nAuthorization: Bearer fixture-authorization"]
        try JSONSerialization.data(withJSONObject: failure)
            .write(to: artifacts.appendingPathComponent("xcuitest-preflight-failure-fixture.json"))
        let observations: [[String: Any]] = [["stage": "prepare", "error": "Kernel observation failed",
            "inventory": ["private": "withheld-inventory"]]]
        try JSONSerialization.data(withJSONObject: observations).write(to: xcuitest.appendingPathComponent("native-mac-release.json"))
        let summary = nativeAttemptFailureSummary(in: attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: artifacts.path), ["xcuitest-preflight-failure-fixture.json"])
        XCTAssertTrue(summary.contains("infrastructureFailed"))
        XCTAssertTrue(summary.contains("Private Mac app registration failed"))
        XCTAssertTrue(summary.contains("AutomationContractError"))
        XCTAssertTrue(summary.contains("prepare"))
        for withheld in ["fixture-authorization", "withheld-response", "withheld-inventory"] {
            XCTAssertFalse(summary.contains(withheld))
        }
    }

    private func nativeDiagnosticJSON(_ url: URL) -> Any? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1024 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024 * 1024) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func nativeAttemptFailureSummary(in attempt: URL) -> String {
        var lines: [String] = []
        if let report = nativeDiagnosticJSON(attempt.appendingPathComponent("report.json")) as? [String: Any] {
            if let released = report["resourcesReleased"] as? Bool { lines.append("resourcesReleased: \(released)") }
            if let result = report["result"] as? [String: Any] {
                if let summary = result["summary"] as? String { lines.append("summary: " + String(summary.prefix(128))) }
                for key in ["subjectDispatched", "subjectCompleted", "subjectDispatchUncertain", "assessed", "evidenceComplete"] {
                    if let value = result[key] as? Bool { lines.append("\(key): \(value)") }
                }
            }
        }
        let artifacts = attempt.appendingPathComponent("artifacts")
        let failures = (try? FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)) ?? []
        for file in failures.filter({ $0.lastPathComponent.hasPrefix("xcuitest-preflight-failure-") && $0.pathExtension == "json" }).prefix(4) {
            guard let failure = nativeDiagnosticJSON(file) as? [String: Any] else { continue }
            for key in ["stage", "errorType", "message"] {
                if let value = failure[key] as? String { lines.append("preflight.\(key): " + String(value.prefix(8192))) }
            }
        }
        if let observations = nativeDiagnosticJSON(attempt.appendingPathComponent("xcuitest/native-mac-release.json")) as? [[String: Any]] {
            for observation in observations.suffix(20) {
                if let stage = observation["stage"] as? String { lines.append("lifecycle.stage: " + String(stage.prefix(128))) }
                if let error = observation["error"] as? String { lines.append("lifecycle.error: " + String(error.prefix(2048))) }
            }
        }
        return String(redactedNativeDiagnostic(lines.joined(separator: "\n")).prefix(16_384))
    }

    /// Retain a filtered status/error summary and this fixture's failed inner XCTest output.
    /// Raw reports, journals, process inventories, environment and signing material are excluded.
    private func attachNativeExecutionFailureLogs(storage: URL) {
        let manager = FileManager.default
        let automation = storage.appendingPathComponent("Automation")
        guard let attempt = latestNativeAttempt(in: automation) else { return }
        var remainingBytes = 1024 * 1024
        var remainingFiles = 16
        let summary = nativeAttemptFailureSummary(in: attempt)
        if !summary.isEmpty {
            let data = Data(summary.utf8)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
            attachment.name = "fixture-native-failure-" + attempt.lastPathComponent + "-summary.txt"
            attachment.lifetime = .keepAlways; add(attachment)
            remainingBytes -= data.count; remainingFiles -= 1
        }
        let artifacts = attempt.appendingPathComponent("artifacts")
        guard let files = try? manager.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.creationDateKey]) else { return }
        // Failed receipts precede logs; newest execution logs precede earlier successful preflights.
        let ordered = files.filter {
            ($0.lastPathComponent.hasPrefix("xcuitest-log-") && $0.pathExtension == "txt") ||
            ($0.lastPathComponent.hasPrefix("xcuitest-attachment-") && $0.pathExtension == "json")
        }.sorted {
            if $0.pathExtension != $1.pathExtension { return $0.pathExtension == "json" }
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        }
        for file in ordered where remainingBytes > 0 && remainingFiles > 0 {
            let name = file.lastPathComponent
            let isLog = name.hasPrefix("xcuitest-log-") && file.pathExtension == "txt"
            let isReceipt = name.hasPrefix("xcuitest-attachment-") && file.pathExtension == "json"
            guard isLog || isReceipt,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: min(remainingBytes, 1024 * 1024)) else { continue }
            let text: String
            if isReceipt {
                guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      fields["completed"] as? Bool == false, fields["stepIndex"] != nil, fields["planDigest"] != nil,
                      let error = fields["error"] as? String, !error.isEmpty,
                      let filtered = try? JSONSerialization.data(withJSONObject: fields.filter {
                          ["stepID", "segmentID", "kind", "completed", "error", "planDigest"].contains($0.key)
                      }, options: [.sortedKeys]) else { continue }
                text = String(decoding: filtered, as: UTF8.self)
            } else {
                // The inner command receives only PATH and DEVELOPER_DIR, and artifact
                // storage refuses secret-tainted scopes. Redact credential lines anyway.
                text = String(decoding: data, as: UTF8.self)
            }
            let redacted = redactedNativeDiagnostic(text)
            let retained = Data(redacted.utf8).prefix(remainingBytes)
            let attachment = XCTAttachment(data: Data(retained), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "fixture-native-failure-" + attempt.lastPathComponent + "-" + name
            attachment.lifetime = .keepAlways; add(attachment)
            remainingBytes -= retained.count; remainingFiles -= 1
        }
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    @MainActor
    private func capture(_ app: XCUIApplication, storage: URL, name: String) throws {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: storage.appendingPathComponent(name + ".png"))
    }
}
