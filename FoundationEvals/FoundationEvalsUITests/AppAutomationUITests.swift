import XCTest
import CryptoKit
import Darwin

final class AppAutomationUITests: XCTestCase {
    @MainActor
    func testOwnershipResetConfirmationCanBeCancelledWithoutChangingTheReservation() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "ownership-reset-confirmation")
        defer { try? FileManager.default.removeItem(at: storage) }
        let support = storage.appendingPathComponent("Automation")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, size), size)
        let target = UUID().uuidString, key = "ios:" + target
        // The test runner is a separate, live owner. The app must display it
        // without releasing it during startup or a cancelled reset confirmation.
        let campaign: [String: Any] = ["runID": "other-live-owner",
            "target": ["id": target, "kind": "physical", "physicalDeviceIdentifier": target],
            "owner": ["pid": getpid(), "startIdentity": "\(process.pbi_start_tvsec):\(process.pbi_start_tvusec)"],
            "ownerToken": "test-runner-owner", "runners": []]
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "campaigns": [key: campaign], "generations": [key: 1]])
        let file = support.appendingPathComponent("target-leases.json")
        try bytes.write(to: file)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launch(); defer { app.terminate() }
        app.activate(); app.typeKey("3", modifierFlags: .command)
        let reset = app.buttons["automationResetDeviceOwnership"]
        XCTAssertTrue(reset.waitForExistence(timeout: 15)); XCTAssertTrue(reset.isEnabled)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/phase0-recovery-controls.png"))
        reset.click()
        XCTAssertTrue(app.staticTexts["Reset device ownership?"].waitForExistence(timeout: 5))
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/phase0-reset-confirmation.png"))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.click()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    /// Intake and picker regression only; selecting a destination never builds, boots or installs.
    @MainActor
    func testPreparationPickersUseStableIdentifiers() throws {
        executionTimeAllowance = 120; continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "automation-picker-identifiers")
        defer { try? FileManager.default.removeItem(at: storage) }
        let project = storage.appendingPathComponent("PickerFixture.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let objects: [String: Any] = [
            "APP": ["isa": "PBXNativeTarget", "name": "PickerFixture",
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
        let destination = app.popUpButtons["automation.preparation.destination"]
        let route = app.popUpButtons["automation.workflow.route"]
        selectAutomationMenu(destination, item: "physical")
        selectAutomationMenu(route, item: "siri")
        selectAutomationMenu(destination, item: "macOS")
        selectAutomationMenu(route, item: "system")
        selectAutomationMenu(destination, item: "simulator")
        selectAutomationMenu(route, item: "ui")
        let simulator = app.popUpButtons["automation.preparation.simulator"]
        XCTAssertTrue(simulator.waitForExistence(timeout: 10))
        XCTAssertTrue(simulator.isEnabled)
        simulator.click()
        let simulatorItem = simulator.menuItems.matching(NSPredicate(
            format: "identifier MATCHES %@", "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )).firstMatch
        XCTAssertTrue(simulatorItem.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(simulatorItem.isEnabled)
        let simulatorID = simulatorItem.identifier
        simulatorItem.click()
        // A second lookup uses the UDID even when the displayed state changes between runs.
        selectAutomationMenu(simulator, item: simulatorID)
        XCTAssertFalse(app.buttons["Run action…"].exists)
        XCTAssertFalse(app.buttons["Run approved workflow"].exists)
        captureEmptyFlow(app.windows.firstMatch, name: "Stable automation pickers")
    }

    @MainActor
    func testUnpreparedPhysicalSiriFormKeepsSubmissionDisabled() throws {
        executionTimeAllowance = 120; continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-form")
        defer { try? FileManager.default.removeItem(at: storage) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FoundationEvals.xcodeproj")
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launchArguments += ["--automation-select-path", project.path]
        app.launch(); defer { app.terminate() }; app.activate(); app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(app.popUpButtons["automation.preparation.destination"], item: "physical")
        let device = app.textFields["Exact physical device ID"]
        XCTAssertTrue(device.waitForExistence(timeout: 5)); device.click(); device.typeText("00008140-0000000000000001")
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "siri")
        let request = app.textFields["Exact request to submit to Siri"]; XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.click(); request.typeText("Open the approved test app")
        let review = app.buttons["Review Siri submission…"]; XCTAssertTrue(review.exists); XCTAssertFalse(review.isEnabled)
        XCTAssertFalse(app.buttons["Run approved workflow"].exists)
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = "unqualified-physical-siri-form"; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/unqualified-physical-siri-form.png"))
        app.checkBoxes["Check an existing record's state"].click()
        XCTAssertTrue(app.popUpButtons["Siri record type"].waitForExistence(timeout: 5))
        let checkedReview = app.buttons["Review Siri state check…"]
        XCTAssertTrue(checkedReview.exists); XCTAssertFalse(checkedReview.isEnabled)
        XCTAssertFalse(app.buttons["Run approved workflow"].exists)
        let checkedScreenshot = app.windows.firstMatch.screenshot()
        let checkedAttachment = XCTAttachment(screenshot: checkedScreenshot)
        checkedAttachment.name = "unqualified-physical-siri-state-check"; checkedAttachment.lifetime = .keepAlways; add(checkedAttachment)
        try checkedScreenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/unqualified-physical-siri-state-check.png"))
    }
    @MainActor
    func testEmptyAutomationAndPickerCancellationRemainReadOnly() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "app-automation")
        defer { try? FileManager.default.removeItem(at: storage) }
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1200", "--evaluation-window-height", "780"]
        app.launch(); defer { app.terminate() }
        app.activate(); app.typeKey("3", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let choose = app.buttons["Choose app…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isHittable)
        let capsule = app.buttons["Open case capsule…"]
        XCTAssertTrue(capsule.exists); XCTAssertTrue(capsule.isHittable)
        captureEmptyFlow(window, name: "Automation empty")
        choose.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); XCTAssertTrue(cancel.isHittable)
        captureEmptyFlow(window, name: "Choose app panel")
        cancel.click()
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isHittable)
        XCTAssertFalse(app.buttons["Prepare app"].exists)
        capsule.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); XCTAssertTrue(cancel.isHittable)
        captureEmptyFlow(window, name: "Open capsule panel")
        cancel.click()
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isHittable)
        captureEmptyFlow(window, name: "Automation after cancellation")
    }
    @MainActor
    private func captureEmptyFlow(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Opt-in integration test: a caller supplies an explicitly reviewed private
    /// fixture and exact owned simulator. Ordinary UI suites skip this test.
    @MainActor
    func testPreparedPureEchoShowsUnassessedNativeEvidence() throws {
        struct Profile: Decodable {
            let sourceProject: String
            let sourceDigest: String
            let simulatorID: String
            let simulatorLabel: String
            let developerDirectory: String?
        }
        let profileURL = UITestStorage.root.appendingPathComponent("automation-native-echo-approved-profile.json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("Requires an explicitly approved private echo fixture profile")
        }
        continueAfterFailure = false
        let profileData = try Data(contentsOf: profileURL)
        XCTAssertLessThanOrEqual(profileData.count, 16_384)
        let profile = try JSONDecoder().decode(Profile.self, from: profileData)
        let project = URL(fileURLWithPath: profile.sourceProject).resolvingSymlinksInPath()
        XCTAssertTrue(project.path.hasPrefix(UITestStorage.root.resolvingSymlinksInPath().path + "/"))
        XCTAssertEqual(project.lastPathComponent, "DuplicateTasks.xcodeproj")
        XCTAssertNotNil(UUID(uuidString: profile.simulatorID))
        let source = try Data(contentsOf: project.deletingLastPathComponent().appendingPathComponent("App/TaskIntents.swift"))
        XCTAssertEqual(SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(), profile.sourceDigest)
        let storage = try UITestStorage.makeDirectory(prefix: "native-echo-automation")
        print("NATIVE_ECHO_STORAGE=\(storage.path)")
        // Retain the real reports and screenshots, including on test failure.
        let app = XCUIApplication()
        if let developerDirectory = profile.developerDirectory {
            app.launchEnvironment["DEVELOPER_DIR"] = developerDirectory
        }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launchArguments += ["--automation-select-path", project.path]
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        selectAutomationMenu(app.popUpButtons["automation.preparation.simulator"], item: profile.simulatorID, timeout: 30)
        selectAutomationMenu(app.popUpButtons["automation.workflow.route"], item: "system")
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        app.buttons["Build private copy"].click()
        let action = app.popUpButtons["automation.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 300), app.debugDescription)
        selectAutomationMenu(action, item: "Qualification echo IntegerArray")
        let input = app.textFields["value (JSON list of whole numbers)"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("[1]")
        selectAutomationMenu(app.popUpButtons["Effects of this action"], item: "Observation and navigation")
        app.checkBoxes["I confirm this action stays within these effects"].click()
        app.checkBoxes["Allow starting this simulator and installing the prepared app"].click()
        let run = app.buttons["Run action…"]
        XCTAssertTrue(run.isEnabled); run.click(); app.buttons["Run approved workflow"].click()
        XCTAssertTrue(app.staticTexts["Executed · unassessed"].waitForExistence(timeout: 300), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Native evidence"].exists)
        let automation = storage.appendingPathComponent("Automation")
        let reports = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("report.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(reports.first))) as? [String: Any])
        XCTAssertEqual(report["resourcesReleased"] as? Bool, true)
        let result = try XCTUnwrap(report["result"] as? [String: Any])
        XCTAssertEqual(result["summary"] as? String, "executedUnassessed")
        XCTAssertEqual(result["assessed"] as? Bool, false)
        XCTAssertEqual(result["subjectCompleted"] as? Bool, true)
        let receipt = try XCTUnwrap((report["receipts"] as? [[String: Any]])?.first)
        XCTAssertEqual((report["receipts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((receipt["target"] as? [String: Any])?["id"] as? String, profile.simulatorID)
        XCTAssertEqual((receipt["app"] as? [String: Any])?["bundleID"] as? String, "com.coryparry.IntentsAutomation.DuplicateTasks")
        let outputs = try XCTUnwrap(receipt["verifiedOutputs"] as? [String: Any])
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.values.first as? [String: Any])
        XCTAssertEqual(output["kind"] as? String, "array")
        let value = try XCTUnwrap((output["value"] as? [[String: Any]])?.first)
        XCTAssertEqual((output["value"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(value["kind"] as? String, "integer"); XCTAssertEqual(value["value"] as? String, "1")
        let saved = app.buttons["View saved result"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); XCTAssertTrue(saved.isEnabled); saved.click()
        XCTAssertTrue(app.staticTexts["Saved result"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved result · not reverified"].exists)
        XCTAssertTrue(app.buttons["Open case capsule…"].exists)
        XCTAssertTrue(app.buttons["Review capsule export…"].exists)
        let heading = app.staticTexts["Executed · unassessed"].firstMatch
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 {
            if scroll.frame.contains(heading.frame) { break }
            scroll.scroll(byDeltaX: 0, deltaY: -500)
        }
        XCTAssertTrue(scroll.frame.contains(heading.frame))
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Real prepared echo with unassessed native evidence"; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: storage.appendingPathComponent("native-echo-result.png"))
    }
    @MainActor
    func testInstalledAppWorkflowKeepsSeparatePropertyCheckAndNeedsApproval() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "installed-app-automation")
        defer { try? FileManager.default.removeItem(at: storage) }
        let bundle = storage.appendingPathComponent("Selected.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.UITestSelection",
                                  "CFBundleExecutable": "Selected", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        // Intake-only bytes; this test never installs or executes the selected product.
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Selected"))
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "1100"]
        app.launchArguments += ["--automation-select-path", bundle.path]
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        let goal = app.textFields["What should the app do?"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10)); goal.click(); goal.typeText("Open tasks")
        let endpoint = app.textFields["Visible label at the destination"]
        endpoint.click(); endpoint.typeText("Tasks")
        XCTAssertFalse(app.buttons["Run workflow…"].isEnabled)
        XCTAssertFalse(app.buttons["Find failures…"].isEnabled)
        let property = app.popUpButtons["Property to check"]
        selectAutomationMenu(property, item: "Control value")
        let label = app.textFields["Element label for the check"]
        XCTAssertTrue(label.waitForExistence(timeout: 5)); label.click(); label.typeText("Volume")
        selectAutomationMenu(property, item: "Visible text")
        XCTAssertFalse(label.exists)
        XCTAssertTrue(app.textFields["Expected property value (optional)"].exists)
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Installed app workflow with separate business check"; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/intents-automation-installed-ui-workflow.png"))
    }
    @MainActor
    func testSourceSelectionSurvivesNavigationWithoutBuildingOrRunning() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "app-automation")
        defer { try? FileManager.default.removeItem(at: storage) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FoundationEvals.xcodeproj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launchArguments += ["--automation-select-path", project.path]
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        waitForAutomationSelection(in: app)
        XCTAssertFalse(app.buttons["Run action…"].exists, "Source selection does not imply a prepared or executable action")
        app.typeKey("1", modifierFlags: .command); app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Selected app"].waitForExistence(timeout: 5), "Root-owned intake persists across sidebar navigation")
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = "App automation selected source"; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/foundation-evals-ui-tests/intents-automation-app-selected-source.png"))
    }
}
