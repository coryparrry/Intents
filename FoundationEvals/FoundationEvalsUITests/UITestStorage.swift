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
        try Data("Foundation Evals UI test storage preflight".utf8).write(to: probe, options: .atomic)
    }

    static func screenshotURL(name: String) throws -> URL {
        let directory = root.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "foundation-evals-trace-\(name).png")
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
