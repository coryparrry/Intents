import Foundation
import XCTest

enum UITestStorage {
    // The runner's private temporary directory cannot be opened by the application under test.
    // Access to this shared test-only root is granted by FoundationEvalsUITests.entitlements.
    static let root = URL(filePath: "/private/tmp/foundation-evals-ui-tests", directoryHint: .isDirectory)

    static func makeDirectory(prefix: String) throws -> URL {
        let directory = root.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try verifyWritable(directory)
        return directory
    }

    static func verifyWritable(_ directory: URL) throws {
        let probe = directory.appending(path: "storage-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data("Intents UI test storage preflight".utf8).write(to: probe, options: .atomic)
    }

    static func screenshotURL(name: String) throws -> URL {
        let directory = root.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "foundation-evals-trace-\(name).png")
    }

    @MainActor
    static func openIntentLab(in app: XCUIApplication) throws {
        app.activate()
        app.typeKey("2", modifierFlags: .command)
        let tab = app.radioButtons["Intent Lab · Beta"]
        try waitFor(tab, in: app, timeout: 5)
        tab.click()
    }

    @MainActor
    static func openSuiteEditor(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Use the normal Show Suite Editor shortcut, including when the last window
        // is closed. Menu hovering asks XCTest to place events in a windowless app's
        // infinite accessibility frame and can stall WindowServer on hosted macOS.
        app.activate()
        app.typeKey("3", modifierFlags: .command)
        try waitFor(app.windows.firstMatch, in: app, timeout: 5, file: file, line: line)
        try waitFor(app.buttons["Run evaluation"], in: app, timeout: 5, file: file, line: line)
    }

    /// Opens Setup, scrolls to a named section, and expands it when it is advanced.
    @MainActor
    static func selectSetupSection(_ title: String, in app: XCUIApplication) {
        let setup = app.radioButtons["Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5), app.debugDescription)
        setup.click()

        let identifier = "Setup section \(title)"
        let section = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5), app.debugDescription)
        let page = app.scrollViews["Suite editor scroll"]
        XCTAssertTrue(page.waitForExistence(timeout: 3), app.debugDescription)
        let viewport = page.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 12)
        for _ in 0..<16 {
            if section.isHittable && section.frame.intersects(viewport) { break }
            let delta: CGFloat = section.frame.minY < viewport.minY ? 180 : -180
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(section.isHittable && section.frame.intersects(viewport), app.debugDescription)

        let advancedContent = [
            "Tools": "Add Tool",
            "Structured output": "Add Field",
            "Session profile": "Use an evaluation profile",
            "Performance": "Prewarm the model before each sample"
        ]
        guard let contentIdentifier = advancedContent[title] else { return }

        let content = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", contentIdentifier, contentIdentifier)
        ).firstMatch
        if !content.exists {
            section.click()
        }
        XCTAssertTrue(content.waitForExistence(timeout: 3), app.debugDescription)
    }

    /// Rejects an unexpected application alert or sheet before a UI flow continues.
    @MainActor
    static func requireNoAlert(in app: XCUIApplication) throws {
        let alert = app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.sheets.firstMatch
        guard !alert.exists else {
            throw NSError(
                domain: "FoundationEvalsUITests.UnexpectedAlert",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected application alert:\n\(alert.debugDescription)"]
            )
        }
    }

    /// Waits for a required element, then reports any blocking application alert with its context.
    @MainActor
    static func waitFor(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let exists = element.waitForExistence(timeout: timeout)
        try requireNoAlert(in: app)
        XCTAssertTrue(exists, app.debugDescription, file: file, line: line)
    }
}
