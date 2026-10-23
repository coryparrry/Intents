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

    static func waitFor(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let readyOrAlert = NSPredicate { _, _ in
            element.exists || app.alerts.firstMatch.exists || app.sheets.firstMatch.exists
        }
        let ready = XCTNSPredicateExpectation(predicate: readyOrAlert, object: nil)
        _ = XCTWaiter.wait(for: [ready], timeout: timeout)
        try requireNoAlert(in: app)
        XCTAssertTrue(element.exists, app.debugDescription, file: file, line: line)
    }
}
