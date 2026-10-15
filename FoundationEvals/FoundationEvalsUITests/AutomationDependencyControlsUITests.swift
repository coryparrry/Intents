import XCTest

/// Source-copy permissions reset when a different app source is selected.
final class AutomationDependencyControlsUITests: XCTestCase {
    @MainActor func testDependencyConsentAndSourceGrantsResetForNewSelection() throws {
        executionTimeAllowance = 180
        continueAfterFailure = false
        let storage = try UITestStorage.makeDirectory(prefix: "dependency-controls")
        defer { try? FileManager.default.removeItem(at: storage) }
        let fixtures = storage.appendingPathComponent("Fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let evidence = storage.appendingPathComponent("Evidence")
        let first = try makeProject("First", under: fixtures)
        let second = try makeProject("Second", under: fixtures)
        let sibling = fixtures.appendingPathComponent("LocalPackage")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--evaluation-window-width", "1300", "--evaluation-window-height", "950"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.typeKey("3", modifierFlags: .command)
        try select(first, in: app)

        let dependencies = app.checkBoxes["Copy installed native dependencies"].firstMatch
        XCTAssertTrue(dependencies.waitForExistence(timeout: 15), app.debugDescription)
        try reveal(dependencies, in: app)
        XCTAssertFalse(try checked(dependencies), "Dependency copying requires an explicit choice")
        let addFolder = app.buttons["Add source folder…"].firstMatch
        XCTAssertTrue(addFolder.waitForExistence(timeout: 5))
        try reveal(addFolder, in: app)
        try capture(app, evidence, "source-default-off")

        try click(dependencies, in: app)
        XCTAssertTrue(try checked(dependencies))
        try capture(app, evidence, "dependencies-on")
        try click(dependencies, in: app)
        XCTAssertFalse(try checked(dependencies))
        try capture(app, evidence, "dependencies-off")

        try click(addFolder, in: app)
        try choosePath(sibling.path, confirmation: "Add source folder", in: app)
        let removeFolder = app.buttons["Remove source folder LocalPackage"].firstMatch
        XCTAssertTrue(removeFolder.waitForExistence(timeout: 10), app.debugDescription)
        try reveal(removeFolder, in: app)
        XCTAssertTrue(app.staticTexts[sibling.path].firstMatch.exists)
        try capture(app, evidence, "additional-folder-selected")
        try click(removeFolder, in: app)
        XCTAssertFalse(removeFolder.exists)

        // Leave both choices enabled, then verify they cannot carry to another selected source.
        try click(addFolder, in: app)
        try choosePath(sibling.path, confirmation: "Add source folder", in: app)
        XCTAssertTrue(removeFolder.waitForExistence(timeout: 10))
        try click(dependencies, in: app)
        XCTAssertTrue(try checked(dependencies))
        try select(second, in: app)
        XCTAssertTrue(dependencies.waitForExistence(timeout: 10))
        try reveal(dependencies, in: app)
        XCTAssertFalse(try checked(dependencies), "A new source selection must reset dependency consent")
        XCTAssertFalse(removeFolder.exists, "A new source selection must clear additional source grants")
        try capture(app, evidence, "new-source-permissions-reset")
    }

    private func makeProject(_ name: String, under root: URL) throws -> URL {
        let project = root.appendingPathComponent(name + "/" + name + ".xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Intake-only fixture: it deliberately contains no build script or executable code.
        let objects: [String: Any] = [
            "APP": ["isa": "PBXNativeTarget", "name": name,
                    "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS"],
            "CONFIGS": ["buildConfigurations": ["DEBUG"]],
            "DEBUG": ["name": "Debug"]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        return project
    }

    @MainActor private func select(_ project: URL, in app: XCUIApplication) throws {
        let choose = app.buttons["Choose app…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        try click(choose, in: app)
        try choosePath(project.path, confirmation: "Choose app", in: app)
    }

    @MainActor private func choosePath(_ path: String, confirmation: String, in app: XCUIApplication) throws {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), app.debugDescription)
        pathField.click()
        app.typeKey("a", modifierFlags: .command)
        pathField.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        let confirm = app.sheets.buttons[confirmation].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: confirm)], timeout: 10), .completed)
    }

    @MainActor private func checked(_ element: XCUIElement) throws -> Bool {
        if let value = element.value as? NSNumber { return value.intValue == 1 }
        let value = try XCTUnwrap(element.value as? String)
        XCTAssertTrue(["0", "1"].contains(value), "Unexpected checkbox value: " + value)
        return value == "1"
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        if let scroll = app.scrollViews.allElementsBoundByIndex.last(where: {
            $0.frame.minX <= element.frame.midX && element.frame.midX <= $0.frame.maxX
        }) {
            for _ in 0..<6 {
                if scroll.frame.contains(element.frame) { break }
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY > scroll.frame.midY ? -300 : 300)
            }
            XCTAssertTrue(scroll.frame.contains(element.frame), "Control must be visible: " + element.label)
        }
        XCTAssertTrue(element.isHittable, "Control must be hittable: " + element.label)
    }

    @MainActor private func click(_ element: XCUIElement, in app: XCUIApplication) throws {
        try reveal(element, in: app)
        XCTAssertTrue(element.isEnabled)
        element.click()
    }

    @MainActor private func capture(_ app: XCUIApplication, _ directory: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tree = app.debugDescription
        try Data(tree.utf8).write(to: directory.appendingPathComponent(name + ".txt"))
        guard app.windows.firstMatch.exists else { return }
        let screenshot = app.windows.firstMatch.screenshot()
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "dependency-controls-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let accessibility = XCTAttachment(string: tree)
        accessibility.name = "dependency-controls-" + name + "-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}
