import XCTest

final class MacIntentTestingUITests: XCTestCase {
    /// Keeps the expected-value editor visibly labeled after choosing a synthetic App Intent.
    @MainActor
    func testMacIntentTestingShowsInstalledAppAndExplicitCaseControls() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "mac-intent-testing")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["-appIntentTesting.mode", "direct", "--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1000", "--evaluation-window-height", "700"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        XCTAssertFalse(app.menuItems["Show Intent Lab"].exists)
        XCTAssertFalse(app.menuItems["Show App Automation"].exists)
        app.menuItems["Show App Intents"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sidebar app intents"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 1"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 2"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 3"].exists)
        XCTAssertTrue(app.staticTexts["Choose an app to inspect its actions and inputs."].exists)
        XCTAssertTrue(app.staticTexts["Choose an app to prepare a native test run."].exists)
        XCTAssertTrue(app.buttons["Choose built macOS app…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines.staticTexts["Intent Lab"].exists)
        XCTAssertFalse(app.outlines.staticTexts["App automation"].exists)
        let installationText = "Install and launch the app normally"
        let installationCopy = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                           installationText, installationText)
        XCTAssertTrue(app.staticTexts.matching(installationCopy).firstMatch.exists)
        let supported = app.disclosureTriangles["Supported inputs and results"]
        XCTAssertTrue(supported.exists)
        supported.click()
        let capabilityCopy = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                          "Compiled metadata discovery", "Compiled metadata discovery")
        XCTAssertTrue(app.staticTexts.matching(capabilityCopy).firstMatch.waitForExistence(timeout: 3))
        supported.click()

        // Read compiled metadata from a synthetic bundle. This does not install,
        // launch, sign, or dispatch the fixture through the native test runner.
        app.buttons["Choose built macOS app…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(fixture.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        let inputs = app.textViews["Inputs JSON"]
        XCTAssertTrue(inputs.waitForExistence(timeout: 5), app.debugDescription)
        let buildDetails = app.disclosureTriangles["Build details"]
        XCTAssertTrue(buildDetails.exists)
        buildDetails.click()
        let bundle = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                 "example.MacIntentUITestFixture", "example.MacIntentUITestFixture")
        XCTAssertTrue(app.staticTexts.matching(bundle).firstMatch.waitForExistence(timeout: 3))
        buildDetails.click()
        XCTAssertEqual(inputs.value as? String, "{}")
        XCTAssertFalse(app.textViews["Expected value JSON"].exists)
        let compare = app.switches["Compare returned value"]
        if !compare.exists {
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Missing compare control"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(compare.exists, app.debugDescription)
        compare.click()
        XCTAssertTrue(app.textViews["Expected value JSON"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Expected value JSON"].exists)
        XCTAssertEqual(app.textViews["Expected value JSON"].value as? String, "null")
        let advanced = app.disclosureTriangles["Advanced: build and signing"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["Developer directory"].exists)
        reveal(app.buttons["Run native test"], in: app)
        app.buttons["Run native test"].click()
        let diagnostic = app.descendants(matching: .any)["mac-intent-diagnostic"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3), app.debugDescription)
        reveal(diagnostic, in: app)
        XCTAssertTrue(diagnostic.isHittable, "Direct Action errors must be visible with Advanced collapsed")
        XCTAssertFalse(app.textFields["Developer directory"].exists)

        let page = app.scrollViews["App Intent steps"]
        XCTAssertTrue(page.waitForExistence(timeout: 3), app.debugDescription)
        let viewport = page.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 12)
        for _ in 0..<16 {
            if advanced.isHittable && viewport.contains(advanced.frame) { break }
            let delta: CGFloat = advanced.frame.minY < viewport.minY ? 180 : -180
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(advanced.isHittable && viewport.contains(advanced.frame), app.debugDescription)
        advanced.click()
        XCTAssertTrue(app.textFields["Developer directory"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.textFields["Signing identity"].exists)
        XCTAssertTrue(app.textFields["Team identifier"].exists)
        XCTAssertTrue(app.buttons["Run native test"].exists)
        XCTAssertFalse(app.buttons["Cancel"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Mac App Intent testing explicit case controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Follows workspace tabs, preserves conversation checks, and keeps raw result evidence behind Advanced.
    @MainActor
    func testSiriStudioSavesAndReopensTwoTurnScenario() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240 // Includes setup navigation and five native file sheets.
        let storage = try UITestStorage.makeDirectory(prefix: "siri-studio")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart",
                                "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        XCTAssertTrue(app.radioGroups["Siri Studio page"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["app-intent-testing-mode"].firstMatch.exists,
                       "Technical test modes belong in Advanced, not the primary workspace")
        XCTAssertFalse(app.textFields["Developer directory"].exists)
        choosePage("Setup", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["siri-studio-setup-status"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["siri-studio-confirm-siri"].firstMatch.exists)
        let recheck = app.buttons["Recheck setup"]
        XCTAssertTrue(recheck.waitForExistence(timeout: 5), app.debugDescription)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in recheck.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 45), .completed, app.debugDescription)
        let stepIDs = ["macos", "xcode", "signing", "xcodegen", "registered", "stopped", "siri"]
        XCTAssertLessThanOrEqual(stepIDs.filter {
            app.descendants(matching: .any)["siri-studio-setup-" + $0].firstMatch.exists
        }.count, 1, "Setup should show the next missing action on any supported authoring host")
        choosePage("Conversations", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["siri-studio-setup-status"].firstMatch.exists)
        XCTAssertTrue(app.buttons["siri-studio-new-scenario"].exists)
        // A newly chosen app opens its first conversation automatically.
        try enter("Open the fixture.", in: "siri-studio-utterance-1", app: app)
        app.menuButtons["siri-studio-expected-action-1"].click()
        app.menuItems["Echo"].click()
        app.buttons["Add turn"].click()
        try enter("What is its status?", in: "siri-studio-utterance-2", app: app)
        advancedAction("Show advanced controls", in: app)
        let replyCheck = app.buttons["Add reply check"]
        reveal(replyCheck, in: app)
        replyCheck.click()
        try enter("ready", in: "siri-studio-reply-check-0", app: app)
        advancedAction("Show advanced controls", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["siri-studio-saved-settings"].firstMatch.exists)
        app.buttons["Save"].click()
        let documentURL = storage.appending(path: "Workspace/SiriStudio/Scenarios/example.MacIntentUITestFixture.json")
        let bytes = try Data(contentsOf: documentURL)
        let authored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let scenarios = try XCTUnwrap(authored["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 1, "App selection should prepare one conversation, not duplicate drafts")
        let turns = try XCTUnwrap(scenarios.first?["turns"] as? [[String: Any]])
        let firstChecks = try XCTUnwrap(turns[0]["expectations"] as? [String: Any])
        let calls = try XCTUnwrap(firstChecks["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["actionIdentifier"] as? String, "EchoIntent")
        let secondChecks = try XCTUnwrap(turns[1]["expectations"] as? [String: Any])
        let replies = try XCTUnwrap(secondChecks["replyContains"] as? [[String: Any]])
        XCTAssertEqual(replies.first?["text"] as? String, "ready")
        app.buttons["Save"].click()
        XCTAssertEqual(try Data(contentsOf: documentURL), bytes)

        app.terminate()
        app.launch()
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        choosePage("Conversations", in: app)
        let reopened = app.descendants(matching: .any)["siri-studio-utterance-2"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(reopened.value as? String, "What is its status?")
        choosePage("Setup", in: app)
        advancedAction("Show advanced controls", in: app)
        let signing = app.disclosureTriangles["Xcode and signing"]
        reveal(signing, in: app)
        signing.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 27, dy: 0)).click()
        let developer = app.textFields["Developer directory"]
        XCTAssertTrue(developer.waitForExistence(timeout: 3), app.debugDescription)
        reveal(developer, in: app)
        developer.click()
        developer.typeKey("a", modifierFlags: .command)
        developer.typeText("/Applications/Xcode.app/Contents/Developer")
        for action in ["Open scenario document…", "Import result bundle…", "Open saved run…",
                       "Export scenario document…"] {
            advancedAction(action, in: app)
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The file picker must open without blocking Studio")
            let cancel = sheet.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 3))
            cancel.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Save"].isEnabled)
        }
        choosePage("Conversations", in: app)
        XCTAssertEqual(reopened.value as? String, "What is its status?")
        let savedRun = try makeRunFixture(authored, in: storage)
        advancedAction("Open saved run…", in: app)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let runPath = app.sheets.textFields.firstMatch
        XCTAssertTrue(runPath.waitForExistence(timeout: 5))
        runPath.typeText(savedRun.path)
        app.typeKey(.return, modifierFlags: [])
        let openRun = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(openRun.waitForExistence(timeout: 5))
        openRun.click()
        let technical = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "framework-result-fixture", "framework-result-fixture")
        let rawResult = app.staticTexts.matching(technical).firstMatch
        XCTAssertTrue(rawResult.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(reopened.exists, "Opening a run should navigate to Results, not mix it into the editor")
        advancedAction("Show advanced controls", in: app)
        XCTAssertTrue(rawResult.waitForNonExistence(timeout: 3), "Raw framework evidence belongs in Advanced")
        let observedTurn = app.popUpButtons["siri-studio-observed-turn"]
        XCTAssertTrue(observedTurn.waitForExistence(timeout: 5), "Results must let the user inspect every observed turn")
        observedTurn.click()
        app.menuItems["Turn 2"].click()
        let secondMessage = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "What is its status?", "What is its status?")
        XCTAssertTrue(app.staticTexts.matching(secondMessage).firstMatch.exists)
        let foreignCall = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "EchoIntent · succeeded", "EchoIntent · succeeded")
        XCTAssertTrue(app.staticTexts.matching(foreignCall).firstMatch.exists,
                      "Calls from another app must retain their identifier instead of borrowing this app’s title")
        let plain = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "ready", "ready")
        XCTAssertTrue(app.staticTexts.matching(plain).firstMatch.exists)
        choosePage("Conversations", in: app)
        app.buttons["siri-studio-new-scenario"].click()
        choosePage("Results", in: app)
        let resultPicker = app.popUpButtons["siri-studio-result-conversation"]
        XCTAssertTrue(resultPicker.waitForExistence(timeout: 5), "An unrun draft must not hide existing results")
        resultPicker.click()
        app.menuItems[try XCTUnwrap(scenarios.first?["name"] as? String)].click()
        XCTAssertTrue(app.staticTexts.matching(plain).firstMatch.exists)
        app.menuButtons["siri-studio-advanced"].click()
        XCTAssertTrue(app.menuItems["Export Swift…"].isEnabled, "The finished conversation must remain exportable beside an unfinished draft")
        XCTAssertFalse(app.menuItems["Export all scenarios as Swift…"].isEnabled, "Export all still validates unfinished drafts")
        app.typeKey(.escape, modifierFlags: [])
        var currentOnly = authored
        var replacement = try XCTUnwrap(scenarios.first)
        replacement["id"] = UUID().uuidString
        replacement["name"] = "Current conversation"
        currentOnly["scenarios"] = [replacement]
        let replacementURL = storage.appending(path: "current-conversation.json")
        try JSONSerialization.data(withJSONObject: currentOnly).write(to: replacementURL)
        openStudioFile(replacementURL, action: "Open scenario document…", in: app)
        openStudioFile(savedRun, action: "Open saved run…", in: app)
        XCTAssertTrue(app.staticTexts.matching(plain).firstMatch.waitForExistence(timeout: 5),
                      "Reopening the same run must still navigate to Results")
        app.menuButtons["siri-studio-advanced"].click()
        XCTAssertFalse(app.menuItems["Export Swift…"].isEnabled, "A removed draft must not export as the current conversation")
        app.typeKey(.escape, modifierFlags: [])
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Siri Studio workspace results"
        attachment.lifetime = .keepAlways
        add(attachment)
        chooseMode("Direct Action", in: app)
        XCTAssertTrue(app.textViews["Inputs JSON"].waitForExistence(timeout: 5))
    }

    /// Keeps saved-document load failures visible on every workspace tab without overwriting the failed file.
    @MainActor
    func testSiriStudioShowsSavedDocumentErrorsAcrossTabs() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-studio-invalid-document")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let folder = storage.appending(path: "Workspace/SiriStudio/Scenarios")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = folder.appending(path: "example.MacIntentUITestFixture.json")
        let invalid = Data("invalid fixture document".utf8)
        try invalid.write(to: saved)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        let diagnostic = app.descendants(matching: .any)["siri-studio-diagnostic"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), app.debugDescription)
        choosePage("Conversations", in: app)
        let newConversation = app.buttons["siri-studio-new-scenario"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        XCTAssertFalse(newConversation.isEnabled)
        for page in ["Setup", "Results", "Conversations"] {
            choosePage(page, in: app)
            XCTAssertTrue(diagnostic.exists, "The load failure must remain visible independently of the selected tab")
        }
        XCTAssertEqual(try Data(contentsOf: saved), invalid)
    }

    /// Explains a rejected older app, preserves that selection when cancelling, and guides an updated build into setup.
    @MainActor
    func testAppSelectionExplainsMissingActionsAndGuidesRecovery() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-app-selection")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let older = storage.appending(path: "OlderApp.app")
        try FileManager.default.moveItem(at: fixture, to: older)
        try FileManager.default.removeItem(at: older.appending(path: "Contents/Resources/Metadata.appintents"))
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: older)
        chooseMode("Siri Studio", in: app)
        let issue = app.descendants(matching: .any)["siri-studio-app-selection-error"].firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 5), app.debugDescription)
        let name = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "OlderApp", "OlderApp")
        XCTAssertTrue(app.staticTexts.matching(name).firstMatch.exists)
        for title in ["Build your updated Mac app", "Install that build", "Choose the updated app here"] {
            let copy = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)
            XCTAssertTrue(app.staticTexts.matching(copy).firstMatch.exists, app.debugDescription)
        }
        app.buttons["mac-intent-choose-app"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(issue.exists, "Cancelling another choice must retain the rejected app and its next steps")
        let updated = try makeCatalogFixture(in: storage.appending(path: "Updated"))
        chooseAppFile(updated, in: app)
        XCTAssertTrue(issue.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["siri-studio-setup-status"].firstMatch.waitForExistence(timeout: 5))
        reveal(app.buttons["Write a conversation"], in: app)
        app.buttons["Write a conversation"].click()
        XCTAssertTrue(app.textViews["siri-studio-utterance-1"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "App selection guided recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Recovers unsaved authoring on relaunch and requires a choice before removing a turn's expectations.
    @MainActor
    func testSiriStudioRecoversUnsavedEditsAndConfirmsTurnRemoval() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-studio-recovery")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        choosePage("Conversations", in: app)
        try enter("Open the fixture.", in: "siri-studio-utterance-1", app: app)
        app.buttons["Add turn"].click()
        try enter("Check its status.", in: "siri-studio-utterance-2", app: app)
        advancedAction("Show advanced controls", in: app)
        let replyCheck = app.buttons["Add reply check"]
        reveal(replyCheck, in: app)
        replyCheck.click()
        try enter("ready", in: "siri-studio-reply-check-0", app: app)
        XCTAssertTrue(app.staticTexts["siri-studio-unsaved"].exists)
        let removals = app.buttons.matching(identifier: "Remove turn")
        XCTAssertEqual(removals.count, 2)
        removals.element(boundBy: 1).click()
        let confirmation = app.sheets.containing(.button, identifier: "Remove turn and expectations").firstMatch
        XCTAssertTrue(confirmation.buttons["Remove turn and expectations"].waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(app.descendants(matching: .any)["siri-studio-reply-check-0"].firstMatch.value as? String, "ready")
        app.terminate()
        app.launch()
        try openWorkspace(in: app, fixture: fixture)
        chooseMode("Siri Studio", in: app)
        choosePage("Conversations", in: app)
        advancedAction("Show advanced controls", in: app)
        let second = app.descendants(matching: .any)["siri-studio-utterance-2"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(second.value as? String, "Check its status.")
        app.buttons["Turn 2"].click()
        XCTAssertEqual(app.descendants(matching: .any)["siri-studio-reply-check-0"].firstMatch.value as? String, "ready")
        app.buttons.matching(identifier: "Remove turn").element(boundBy: 1).click()
        confirmation.buttons["Remove turn and expectations"].click()
        XCTAssertFalse(second.exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Siri Studio recovered authoring and confirmed turn removal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Guides app selection and setup, creates an editable action-backed example, and exposes direct testing without a hidden menu.
    @MainActor
    func testGuidedSetupCreatesExampleAndExposesDirectAction() throws {
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "siri-guide")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixture = try makeCatalogFixture(in: storage)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.appending(path: "Workspace").path,
                                "--evaluation-window-width", "1250", "--evaluation-window-height", "880"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show App Intents"].click()
        chooseMode("Siri Studio", in: app)
        app.buttons["Guided setup"].click()
        XCTAssertFalse(app.radioGroups["Siri Studio page"].exists,
                       "The app-selection screen must not indicate an unrelated selected page")
        XCTAssertTrue(app.buttons["mac-intent-choose-app"].exists)
        chooseAppFile(fixture, in: app)
        XCTAssertTrue(app.radioGroups["Siri Studio page"].waitForExistence(timeout: 5))
        let progress = app.staticTexts["siri-guide-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["siri-guide-continue"].exists)
        let example = app.buttons["siri-guide-example"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        example.click()
        let utterance = app.textViews["siri-studio-utterance-1"]
        XCTAssertTrue(utterance.waitForExistence(timeout: 5))
        XCTAssertEqual(utterance.value as? String, "In CatalogFixture, Echo.")
        XCTAssertTrue(app.menuButtons["siri-studio-expected-action-1"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Guided App Intents example conversation"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Test an action without Siri"].click()
        XCTAssertTrue(app.descendants(matching: .any)["App Intent step 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Inputs JSON"].exists)
    }

    /// Opens the app workspace and loads synthetic catalog metadata without executing an intent.
    @MainActor
    private func openWorkspace(in app: XCUIApplication, fixture: URL) throws {
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show App Intents"].click()
        chooseAppFile(fixture, in: app)
    }

    /// Selects the app through the real file importer and waits for its native sheet to close.
    @MainActor
    private func chooseAppFile(_ fixture: URL, in app: XCUIApplication) {
        let choose = app.buttons["mac-intent-choose-app"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(fixture.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// Reveals the control's click point, allowing native focus rectangles to extend beyond the scroll content.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingDown: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let page = app.scrollViews["App Intent steps"]
        let wheel = page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        /// Requires a hittable control whose center is visible, or a toolbar control above the scroll view.
        func canClick() -> Bool {
            let frame = element.frame
            let viewport = page.frame.insetBy(dx: 0, dy: 8)
            return element.isHittable && (frame.maxY <= viewport.minY
                || viewport.contains(CGPoint(x: frame.midX, y: frame.midY)))
        }
        for _ in 0..<8 {
            if canClick() { return }
            wheel.scroll(byDeltaX: 0, deltaY: scrollingDown ? -350 : 350)
        }
        XCTAssertTrue(canClick(), "Control: \(element.frame); viewport: \(page.frame). \(app.debugDescription)")
    }

    /// Navigates the same native toolbar tabs used throughout the workspace.
    @MainActor
    private func choosePage(_ title: String, in app: XCUIApplication) {
        let control = app.radioGroups["Siri Studio page"].radioButtons[title]
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        control.click()
    }

    /// Opens an explicit technical action from the workspace toolbar.
    @MainActor
    private func advancedAction(_ title: String, in app: XCUIApplication) {
        let menu = app.menuButtons["siri-studio-advanced"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription)
        item.click()
    }

    /// Selects a local scenario or run through the real native file sheet.
    @MainActor
    private func openStudioFile(_ url: URL, action: String, in app: XCUIApplication) {
        advancedAction(action, in: app)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// Returns from the technical Direct Action form or opens it through Advanced.
    @MainActor
    private func chooseMode(_ label: String, in app: XCUIApplication) {
        if app.radioGroups["Siri Studio page"].exists || app.staticTexts["siri-guide-progress"].exists {
            if label == "Direct Action" { advancedAction("Test an action directly", in: app) }
            return
        }
        let segment = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), app.debugDescription)
        reveal(segment, in: app, scrollingDown: false)
        segment.click()
    }

    /// Enters text using its control identifier across native text-field and text-view representations.
    @MainActor
    private func enter(_ text: String, in identifier: String, app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        field.typeText(text)
    }

    /// Supplies synthetic saved evidence to exercise result presentation without calling Siri or claiming a live evaluation.
    private func makeRunFixture(_ document: [String: Any], in directory: URL) throws -> URL {
        let scenario = try XCTUnwrap((document["scenarios"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(scenario["id"] as? String)
        let revision = try XCTUnwrap(scenario["revision"] as? Int)
        let turns = try XCTUnwrap(scenario["turns"] as? [[String: Any]])
        let transcript: [[String: Any]] = try turns.map { turn in
            ["turnID": try XCTUnwrap(turn["id"] as? String), "utterance": turn["utterance"] ?? "",
             "foundEntities": [], "onScreenEntities": [], "loadedSkills": [],
             "invocations": [["intent": "EchoIntent", "arguments": [String: String](),
                               "outcome": "succeeded", "ran": true, "committed": true,
                               "result": "framework-result-fixture", "timestamp": "2026-01-01T12:00:00Z"],
                              ["intent": "EchoIntent", "bundleIdentifier": "example.OtherApp", "arguments": [String: String](),
                               "outcome": "succeeded", "ran": true, "committed": true, "timestamp": "2026-01-01T12:00:01Z"]],
             "response": ["text": "ready", "timestamp": "2026-01-01T12:00:00Z"]]
        }
        let summary: [String: Any] = ["schema": "dev.intents.siri-studio.summary", "version": 1,
            "scenarioID": id, "revision": revision, "metrics": ["intentsAllPass": 1, "siriResponseAllPass": 1],
            "inferenceFailureCount": 0, "metricsNotFound": []]
        let report: [String: Any] = ["schema": "dev.intents.siri-studio.report", "version": 1,
            "scenarioID": id, "revision": revision, "repeatIndex": 0, "status": "ran",
            "turnsAuthored": turns.count, "turnsReached": turns.count, "turns": transcript]
        let verdict: [String: Any] = ["id": id, "revision": revision, "name": scenario["name"] ?? "Fixture",
            "state": "passed", "attempted": 1, "passed": 1, "failingMetrics": [], "reports": [report], "summary": summary]
        let run: [String: Any] = ["document": document, "osBuild": "UI fixture", "startedAt": 0,
            "endedAt": 1, "logURL": directory.appending(path: "fixture.log").absoluteString, "scenarios": [verdict]]
        let folder = directory.appending(path: "SavedRun", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: run).write(to: folder.appending(path: "run.json"))
        return folder
    }

    /// Creates an isolated catalog-only app bundle with no executable App Intent behavior.
    private func makeCatalogFixture(in directory: URL) throws -> URL {
        let app = directory.appending(path: "CatalogFixture.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let metadata = contents.appending(path: "Resources/Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "example.MacIntentUITestFixture", "CFBundlePackageType": "APPL",
                                   "CFBundleExecutable": "CatalogFixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Data("catalog-only fixture".utf8).write(to: contents.appending(path: "MacOS/CatalogFixture"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.appending(path: "MacOS/CatalogFixture").path)
        try Data(#"{"version":1,"actions":{"EchoIntent":{"identifier":"EchoIntent","title":{"key":"Echo"},"parameters":[]}}}"#.utf8)
            .write(to: metadata.appending(path: "extract.actionsdata"))
        return app
    }
}
