import Testing
@testable import FoundationEvals

struct EditorSelectionHelpersTests {
    /// Keeps a valid selection and repairs it when cases disappear or become available again.
    @Test func selectionTracksAvailableCases() {
        var selected: Int? = 2
        repairEditorSelection(selected, ids: [1, 2]) { selected = $0 }
        #expect(selected == 2)
        repairEditorSelection(selected, ids: [1]) { selected = $0 }
        #expect(selected == 1)
        repairEditorSelection(selected, ids: []) { selected = $0 }
        #expect(selected == nil)
        repairEditorSelection(selected, ids: [2]) { selected = $0 }
        #expect(selected == 2)
    }

    @Test func numberedNamesFillGapsAndRespectPrefixes() {
        #expect(firstAvailableNumberedName(prefix: "field", existing: ["field1", "field3"]) == "field2")
        #expect(firstAvailableNumberedName(prefix: "value", existing: ["field1", "value1"]) == "value2")
        #expect(firstAvailableNumberedName(prefix: "Definition", existing: []) == "Definition1")
    }
}
