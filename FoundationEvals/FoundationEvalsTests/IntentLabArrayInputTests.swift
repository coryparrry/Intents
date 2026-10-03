import Testing
@testable import FoundationEvals

struct IntentLabArrayInputTests {
    @Test func integerEntryKeepsPartialTextOutOfTheModel() {
        let type: ScenarioValueType = .primitive(.integer)
        #expect(ScenarioArrayInput.parse("1", element: type) == [.integer(1)])
        #expect(ScenarioArrayInput.parse("1,", element: type) == nil)
        #expect(ScenarioArrayInput.parse("1,2", element: type) == [.integer(1), .integer(2)])
        #expect(ScenarioArrayInput.parse("", element: type) == [])
    }

    @Test func booleanEntryRejectsIncompleteAndInvalidItems() {
        let type: ScenarioValueType = .primitive(.boolean)
        #expect(ScenarioArrayInput.parse("true,", element: type) == nil)
        #expect(ScenarioArrayInput.parse("true,false", element: type) == [.boolean(true), .boolean(false)])
        #expect(ScenarioArrayInput.parse("true,maybe", element: type) == nil)
    }
}
