#if canImport(FoundationModels)
import XCTest
import FoundationModels
@testable import IntentsAutomationCore

final class AutomationGeneratedNavigationDecisionTests: XCTestCase {
    func testFieldsAtClippingLimitsCannotProveExactSelection() throws {
        for (length, field) in [(512, "name"), (512, "text"), (1024, "value")] {
            let prefix = String(repeating: "a", count: length)
            var node = AutomationControllerRequest.Node(id: "clipped", role: "button", selected: true, visible: true, disabled: false, secure: false)
            switch field { case "name": node.name = prefix; case "text": node.text = prefix; default: node.value = prefix }
            let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: [node], truncated: true,
                omittedNodes: 0, verbs: ["tap"], recentActions: [], remainingActions: 30, remainingMs: 120000)
            let goal = AutomationNavigationGoal(id: "goal", instruction: "Select", endpoint: .init(.label, "Done"), allowedFillBindings: [], selectionBindings: ["option"])
            XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["option": prefix]).tapAliases, ["n0"])
        }
    }
    func testOnlyDeclaredAlreadySelectedOptionsAreExcludedFromTapProposals() throws {
        let nodes: [AutomationControllerRequest.Node] = [
            .init(id: "selected-option", role: "button", name: "Account A", selected: true, visible: true, disabled: false, secure: false),
            .init(id: "unselected-option", role: "button", name: "Account A", selected: false, visible: true, disabled: false, secure: false),
            .init(id: "unknown-option", role: "button", name: "Account A", visible: true, disabled: false, secure: false),
            .init(id: "other-selected", role: "button", name: "Account B", selected: true, visible: true, disabled: false, secure: false)]
        let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: nodes, truncated: false,
            omittedNodes: 0, verbs: ["tap"], recentActions: [], remainingActions: 30, remainingMs: 120000)
        var goal = AutomationNavigationGoal(id: "goal", instruction: "Select the approved account", endpoint: .init(.label, "Done"),
            allowedFillBindings: [], selectionBindings: ["account"])
        let grammar = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["account": "Account A"])
        XCTAssertEqual(grammar.tapAliases, ["n1", "n2", "n3"])
        XCTAssertThrowsError(try grammar.decision(.init(json: #"{"kind":"tap","node":"n0"}"#)))
        XCTAssertEqual(try grammar.decision(.init(json: #"{"kind":"tap","node":"n1"}"#)).node, "unselected-option")
        goal.selectionBindings = nil
        XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: [:]).tapAliases, ["n0", "n1", "n2", "n3"])
    }
    func testSelectionRequiresExplicitDisjointFillScopeAndSuppliedValues() throws {
        var goal = AutomationNavigationGoal(id: "goal", instruction: "Select", endpoint: .init(.label, "Done"), selectionBindings: ["account"])
        XCTAssertThrowsError(try goal.validate())
        goal.allowedFillBindings = ["account"]
        XCTAssertThrowsError(try goal.validate())
        goal.allowedFillBindings = []; goal.selectionBindings = ["account", "account"]
        XCTAssertThrowsError(try goal.validate())
        goal.selectionBindings = ["account"]
        let program = AutomationUIProgram(operations: [.init(id: "goal", kind: .navigateGoal, goal: goal)])
        XCTAssertThrowsError(try program.validate(phase: .setup))
        var supplied = program; supplied.bindings = ["account": "Account A"]
        XCTAssertNoThrow(try supplied.validate(phase: .setup))
    }
    private func grammar(required: Int? = nil, used: Int = 0, verbs: [String] = ["tap", "fill", "scroll"], remaining: Int = 30) throws -> AutomationGuidedNavigationDecision {
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Create fixture", endpoint: .init(.label, "Done"),
            maximumCalls: 12, maximumActions: 30, minimumBindingUses: required.map { ["approved": $0] })
        let nodes: [AutomationControllerRequest.Node] = [
            .init(id: "exact-field", role: "text-field", editable: nil, fillSupported: true, visible: true, disabled: false, secure: false),
            .init(id: "exact-button", role: "button", editable: nil, visible: true, disabled: false, secure: false)]
        let request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: nodes, truncated: false,
            omittedNodes: 0, verbs: verbs, recentActions: [], remainingActions: remaining, remainingMs: 120000, approvedBindingUses: ["approved": used])
        return try .init(goal: goal, request: request, bindings: ["approved": "private-approved-value"])
    }
    func testRepeatedExactRequiredFillIsExcludedOnlyAfterPriorApprovalAndCurrentMatch() throws {
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Create two records", endpoint: .init(.label, "Done"), minimumBindingUses: ["approved": 2])
        var request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: [
            .init(id: "field", role: "text-field", value: "private-input", editable: true, visible: true, disabled: false, secure: false)],
            truncated: false, omittedNodes: 0, verbs: ["fill"], recentActions: [], remainingActions: 30, remainingMs: 120000, approvedBindingUses: ["approved": 1])
        let repeated = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "private-input"])
        XCTAssertFalse(repeated.kinds.contains("fill")); XCTAssertFalse(repeated.kinds.contains("finish"))
        XCTAssertThrowsError(try repeated.decision(.init(json: #"{"kind":"fill","node":"n0","textBinding":"approved"}"#)))
        request.nodes[0].value = ""
        let cleared = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "private-input"])
        XCTAssertEqual(cleared.fillBindingOptions["n0"], ["approved"])
        request.nodes[0].value = "private-input"; request.approvedBindingUses = ["approved": 0]
        XCTAssertTrue(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "private-input"]).kinds.contains("fill"))
        request.approvedBindingUses = ["approved": 1]
        let other = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "private-input", "other": "different-input"])
        XCTAssertEqual(other.fillBindingOptions["n0"], ["other"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(other.schema), as: UTF8.self).contains("private-input"))
    }
    func testFrozenFillWhitelistKeepsContextOutOfEveryFillBranch() throws {
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Create", endpoint: .init(.label, "Done"),
            minimumBindingUses: ["approved": 2], allowedFillBindings: ["approved"])
        var request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: [
            .init(id: "field", role: "text-field", value: "name", editable: true, visible: true, disabled: false, secure: false)],
            truncated: false, omittedNodes: 0, verbs: ["fill", "tap"], recentActions: [], remainingActions: 30, remainingMs: 120000, approvedBindingUses: ["approved": 1])
        let bindings = ["approved": "name", "context": "Work"]
        let alreadyFilled = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: bindings)
        XCTAssertTrue(alreadyFilled.fillBindingOptions.isEmpty)
        XCTAssertThrowsError(try alreadyFilled.decision(.init(json: #"{"kind":"fill","node":"n0","textBinding":"context"}"#)))
        request.nodes[0].value = ""
        XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: bindings).fillBindingOptions["n0"], ["approved"])
        request.nodes[0].value = "name"; request.approvedBindingUses = ["approved": 0]
        XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: bindings).fillBindingOptions["n0"], ["approved"])
    }
    func testApprovedMatchingFieldIsNotProposedForAnotherFocusButInitialPrefillIs() throws {
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Create", endpoint: .init(.label, "Done"), minimumBindingUses: ["approved": 2], allowedFillBindings: ["approved"])
        var request = AutomationControllerRequest(goalId: "goal", revision: "1", nodes: [
            .init(id: "field", role: "text-field", value: "input", editable: true, visible: true, disabled: false, secure: false),
            .init(id: "button", role: "button", name: "Save", editable: false, visible: true, disabled: false, secure: false)], truncated: false, omittedNodes: 0, verbs: ["fill", "tap"], recentActions: [], remainingActions: 30, remainingMs: 120000, approvedBindingUses: ["approved": 1])
        let alreadyFilled = try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "input"])
        XCTAssertEqual(alreadyFilled.tapAliases, ["n1"])
        request.verbs = ["tap"]
        XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "input"]).tapAliases, ["n1"])
        XCTAssertThrowsError(try alreadyFilled.decision(.init(json: #"{"kind":"tap","node":"n0"}"#)))
        request.approvedBindingUses = ["approved": 0]
        XCTAssertEqual(try AutomationGuidedNavigationDecision(goal: goal, request: request, bindings: ["approved": "input"]).tapAliases, ["n0", "n1"])
    }
    func testRuntimeGrammarRestrictsExactAliasesAndProducesOnlyApplicableFields() throws {
        let grammar = try grammar()
        XCTAssertEqual(try grammar.decision(.init(json: #"{"kind":"fill","node":"n0","textBinding":"approved"}"#)), .init(kind: "fill", node: "exact-field", textBinding: "approved"))
        XCTAssertEqual(try grammar.decision(.init(json: #"{"kind":"tap","node":"n1"}"#)), .init(kind: "tap", node: "exact-button"))
        XCTAssertEqual(try grammar.decision(.init(json: #"{"kind":"scroll","direction":"down"}"#)), .init(kind: "scroll", direction: "down"))
        XCTAssertEqual(try grammar.decision(.init(json: #"{"kind":"finish"}"#)), .init(kind: "finish"))
        let schema = try JSONEncoder().encode(grammar.schema)
        let text = String(decoding: schema, as: UTF8.self)
        XCTAssertFalse(text.contains("private-approved-value")); XCTAssertFalse(text.contains("exact-field"))
        XCTAssertTrue(text.contains("n0")); XCTAssertTrue(text.contains("approved"))
    }
    func testUnexpectedNodesBindingsExtraFieldsAndUnionWrappersAreRejected() throws {
        let grammar = try grammar()
        for json in [#"{"kind":"fill","node":"n1","textBinding":"approved"}"#,
                     #"{"kind":"fill","node":"exact-field","textBinding":"approved"}"#,
                     #"{"kind":"fill","node":"n0","textBinding":"invented"}"#,
                     #"{"kind":"fill","node":"n0","textBinding":"approved","reason":"noSafeAction"}"#,
                     #"{"kind":"tap","node":"n99"}"#, #"{"ControllerFill":{"node":"n0","textBinding":"approved"}}"#,
                     #"{"kind":"scroll","direction":"diagonal"}"#, #"{"kind":"finish","node":"n0"}"#] {
            XCTAssertThrowsError(try grammar.decision(.init(json: json)))
        }
    }
    func testActionsAndFinishAreOmittedUntilTheirNativePrerequisitesHold() throws {
        let unfinished = try grammar(required: 2, used: 1)
        XCTAssertFalse(unfinished.kinds.contains("finish")); XCTAssertTrue(unfinished.kinds.contains("cannotProceed"))
        XCTAssertThrowsError(try unfinished.decision(.init(json: #"{"kind":"finish"}"#)))
        XCTAssertTrue(try grammar(required: 2, used: 2).kinds.contains("finish"))
        let exhausted = try grammar(remaining: 0)
        XCTAssertEqual(exhausted.kinds, ["finish", "cannotProceed"])
        XCTAssertThrowsError(try exhausted.decision(.init(json: #"{"kind":"tap","node":"n1"}"#)))
        let observe = try grammar(verbs: ["scroll"])
        XCTAssertFalse(observe.kinds.contains("fill")); XCTAssertFalse(observe.kinds.contains("tap"))
        XCTAssertTrue(observe.kinds.contains("scroll"))
    }
}
#endif
