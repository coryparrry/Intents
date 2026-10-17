import XCTest

extension XCTestCase {
    @MainActor
    func waitForAutomationSelection(in app: XCUIApplication, timeout: TimeInterval = 30) {
        XCTAssertTrue(app.staticTexts["Selected app"].waitForExistence(timeout: timeout), app.debugDescription)
        let progress = app.staticTexts["automation.progress"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: progress)], timeout: timeout), .completed)
    }

    @MainActor
    func automationAppPicker(in app: XCUIApplication, selectedApp: String, timeout: TimeInterval = 10) -> XCUIElement {
        // Native SwiftUI exposes "App" as adjacent static text, not the popup's label.
        let matches = app.popUpButtons.matching(NSPredicate(format: "value == %@", selectedApp))
        let picker = matches.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertEqual(matches.count, 1, "Expected one app picker showing \(selectedApp).\n\(app.debugDescription)")
        return picker
    }

    @MainActor
    func automationConfirmation(in app: XCUIApplication, title: String, timeout: TimeInterval = 5) -> XCUIElement {
        // macOS also exposes alert actions in the Touch Bar. Scope approval to its presented sheet.
        let matches = app.sheets.containing(.staticText, identifier: title)
        let sheet = matches.element
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertEqual(matches.count, 1, "Expected one confirmation titled \(title).\n\(app.debugDescription)")
        return sheet
    }

    @MainActor
    func selectAutomationMenu(_ picker: XCUIElement, item identifier: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: picker)], timeout: timeout), .completed)
        picker.click()
        let item = picker.menuItems[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: timeout))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: item)], timeout: timeout), .completed)
        item.click()
    }
}
