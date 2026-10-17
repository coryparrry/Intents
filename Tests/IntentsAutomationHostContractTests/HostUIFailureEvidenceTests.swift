import Foundation
import XCTest

final class HostUIFailureEvidenceTests: XCTestCase {
    func testTerminalReceiptSurvivesFailureBeforeApplicationLaunch() throws {
        // The generated XCTest host cannot run in a SwiftPM unit test. Check the
        // distributed template contract so a missing app cannot erase its error.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Integration/AutomationHost/UIStepTests.swift"), encoding: .utf8)
        let failure = try XCTUnwrap(source.range(of: "} catch {"))
        let handler = String(source[failure.upperBound...])
        let receipt = try XCTUnwrap(handler.range(of: "error: String(String(describing: error).prefix(4096))"))
        let running = try XCTUnwrap(handler.range(of: "if app.state == .runningForeground || app.state == .runningBackground {"))
        let screenshot = try XCTUnwrap(handler.range(of: "XCTAttachment(screenshot: app.screenshot())"))
        let rethrow = try XCTUnwrap(handler.range(of: "throw error"))
        XCTAssertLessThan(receipt.lowerBound, running.lowerBound)
        XCTAssertLessThan(running.lowerBound, screenshot.lowerBound)
        XCTAssertLessThan(screenshot.lowerBound, rethrow.lowerBound)
    }
}
