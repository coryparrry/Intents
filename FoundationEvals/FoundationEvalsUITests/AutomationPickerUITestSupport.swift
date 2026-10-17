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
