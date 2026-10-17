#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationUIHostQueryTests: XCTestCase {
    func testMacStaticTextMatchesDisplayedValueAndExistingLabel() {
        let title = "Phase 3 task quoted \"title\" %@"
        let predicate = UIHostQuery(elementType: "staticText").labelContainsPredicate(title, nativeMac: true)
        XCTAssertTrue(predicate.evaluate(with: ["label": "", "value": "Personal · \(title) · Open"]))
        XCTAssertTrue(predicate.evaluate(with: ["label": "Personal · \(title) · Open", "value": ""]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "Other task", "value": "Other task"]))
    }

    func testMacValueFallbackRequiresExplicitStaticTextType() {
        for type in [nil, "any", "button", "textField", "textView"] as [String?] {
            let predicate = UIHostQuery(elementType: type).labelContainsPredicate("Expected task", nativeMac: true)
            XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": "Expected task"]), "type=\(String(describing: type))")
            XCTAssertTrue(predicate.evaluate(with: ["label": "Expected task", "value": ""]))
        }
    }

    func testOtherPlatformsKeepStaticTextLabelMatching() {
        let predicate = UIHostQuery(elementType: "staticText").labelContainsPredicate("Expected task", nativeMac: false)
        XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": "Expected task"]))
        XCTAssertTrue(predicate.evaluate(with: ["label": "Expected task", "value": ""]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "Other task", "value": "Other task"]))
    }
}
#endif
