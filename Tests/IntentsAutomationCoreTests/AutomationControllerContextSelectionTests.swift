import XCTest
@testable import IntentsAutomationCore

final class AutomationControllerContextSelectionTests: XCTestCase {
    func testActualInputAndButtonsAfterStructuralAncestorsRemainInBoundedPrompt() {
        var nodes = (0..<55).map { node("container-\($0)") }
        let input = node("title", role: "text-field", editable: true)
        let personal = node("personal", role: "button"), work = node("work", role: "button")
        nodes += [input] + (0..<6).map { node("wrapper-\($0)") } + [personal, work]
        let selected = AutomationControllerContextSelection.select(nodes)
        XCTAssertEqual(selected.count, 48)
        XCTAssertEqual(Array(selected.prefix(3)), [input, personal, work])
        XCTAssertTrue(selected.allSatisfy(nodes.contains))
        XCTAssertEqual(selected, AutomationControllerContextSelection.select(nodes))
    }
    func testClippingPreservesUnavailableStatesAndExcludesSecureFieldsWithoutInventingActions() {
        var disabled = node("disabled", role: "button"); disabled.disabled = true
        var hidden = node("hidden", role: "button"); hidden.visible = false
        var secure = node("secure", role: "text-field", editable: true); secure.secure = true
        let ordinary = node("ordinary", role: "button")
        let nodes = [secure, hidden, disabled, ordinary]
        XCTAssertEqual(AutomationControllerContextSelection.select(nodes), [ordinary, disabled, hidden])
        XCTAssertEqual(AutomationControllerContextSelection.select(nodes, maximum: 1), [ordinary])
        XCTAssertTrue(AutomationControllerContextSelection.select(nodes, maximum: -1).isEmpty)
        XCTAssertEqual(disabled.disabled, true); XCTAssertFalse(hidden.visible)
    }
    func testActionAliasesShareExactProjectionAndRespectEveryInputVeto() throws {
        var supported = node("native-input", role: "text-field"); supported.editable = nil; supported.fillSupported = true
        let explicit = node("explicit-input", role: "text-field", editable: true)
        var falseEditable = supported; falseEditable.id = "false-editable"; falseEditable.editable = false
        var missingSupport = supported; missingSupport.id = "unknown-input"; missingSupport.fillSupported = nil
        var falseSupport = missingSupport; falseSupport.id = "unsupported-input"; falseSupport.fillSupported = false
        var disabled = supported; disabled.id = "disabled-input"; disabled.disabled = true
        var hidden = supported; hidden.id = "hidden-input"; hidden.visible = false
        var secure = explicit; secure.id = "secure-input"; secure.secure = true
        let nodes = [falseEditable, missingSupport, falseSupport, disabled, hidden, secure, supported, explicit, node("button", role: "button")]
        let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: nodes, truncated: false,
            omittedNodes: 0, verbs: ["tap", "fill"], recentActions: [], remainingActions: 30, remainingMs: 120000)
        let projection = try AutomationControllerContextSelection.project(request)
        XCTAssertEqual(Set(projection.fillAliases.compactMap { projection.nodeIDs[$0] }), ["native-input", "explicit-input"])
        XCTAssertFalse(projection.nodeIDs.values.contains("secure-input"))
        XCTAssertFalse(projection.tapAliases.compactMap { projection.nodeIDs[$0] }.contains("hidden-input"))
        XCTAssertFalse(projection.tapAliases.compactMap { projection.nodeIDs[$0] }.contains("disabled-input"))
        for (index, item) in projection.nodes.enumerated() { XCTAssertEqual(projection.nodeIDs["n\(index)"], item.id) }
        var observer = request; observer.verbs = ["scroll"]
        XCTAssertTrue(try AutomationControllerContextSelection.project(observer).fillAliases.isEmpty)
        XCTAssertTrue(try AutomationControllerContextSelection.project(observer).tapAliases.isEmpty)
    }
    func testProjectionRetainsBoundAndRejectsDuplicateIdentityBeforeAliasing() throws {
        let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: (0..<100).map { node("button-\($0)", role: "button") },
            truncated: false, omittedNodes: 0, verbs: ["tap"], recentActions: [], remainingActions: 30, remainingMs: 120000)
        let projection = try AutomationControllerContextSelection.project(request)
        XCTAssertEqual(projection.nodes.count, 48); XCTAssertEqual(projection.tapAliases.count, 48)
        var duplicate = request; duplicate.nodes = [node("duplicate"), node("duplicate")]
        XCTAssertThrowsError(try AutomationControllerContextSelection.project(duplicate))
    }
    func testSegmentedOptionContainerRemainsContextButOnlyItsOptionsAreTapChoices() throws {
        var picker = node("account", role: "segmented-control"); picker.name = "Personal"
        var personal = node("personal", role: "button"); personal.name = "Personal"; personal.selected = true
        var work = node("work", role: "button"); work.name = "Work"
        var disabled = node("disabled", role: "button"); disabled.disabled = true
        let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: [picker, personal, work, disabled, node("save", role: "button")],
            truncated: false, omittedNodes: 0, verbs: ["tap"], recentActions: [], remainingActions: 30, remainingMs: 120000)
        let projection = try AutomationControllerContextSelection.project(request)
        XCTAssertTrue(projection.nodes.contains(picker))
        XCTAssertEqual(Set(projection.tapAliases.compactMap { projection.nodeIDs[$0] }), ["personal", "work", "save"])
        var unknown = picker; unknown.id = "unknown"; unknown.role = nil
        var ordinary = request; ordinary.nodes = [unknown]
        XCTAssertEqual(try AutomationControllerContextSelection.project(ordinary).tapAliases.count, 1)
    }
    private func node(_ id: String, role: String = "other", editable: Bool = false) -> AutomationControllerRequest.Node {
        .init(id: id, role: role, name: nil, text: nil, value: nil, editable: editable, visible: true, disabled: false, secure: false)
    }
}
