import Foundation
import Testing
@testable import FoundationEvals

struct EditorSelectionHelpersTests {
    @Test func selectionUpdatesOnlyWhenInvalid() {
        let first = UUID()
        let second = UUID()
        var selected: UUID? = second
        var updates = 0
        func repair(_ ids: [UUID]) {
            repairEditorSelection(selected, ids: ids) {
                updates += 1
                selected = $0
            }
        }

        repair([first, second])
        repair([second, second])
        #expect(selected == second)
        #expect(updates == 0)
        repair([first, first])
        #expect(selected == first)
        #expect(updates == 1)
        repair([])
        #expect(selected == nil)
        #expect(updates == 2)
        repair([])
        #expect(selected == nil)
        #expect(updates == 3)
        repair([second])
        #expect(selected == second)
        #expect(updates == 4)
    }

    @Test func numberedNamesFillGapsAndRespectPrefixes() {
        #expect(firstAvailableNumberedName(prefix: "field", existing: ["field1", "field3"]) == "field2")
        #expect(firstAvailableNumberedName(prefix: "value", existing: ["field1", "value1"]) == "value2")
        #expect(firstAvailableNumberedName(prefix: "Definition", existing: []) == "Definition1")
    }
}
