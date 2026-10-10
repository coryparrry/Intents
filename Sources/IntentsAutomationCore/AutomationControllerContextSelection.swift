import Foundation

/// A bounded prompt projection, never an observation-completeness or action proof.
/// AX trees put many structural ancestors before useful controls; keep actual
/// inputs/buttons visible to the model without changing their observed states.
enum AutomationControllerContextSelection {
    struct Projection {
        let nodes: [AutomationControllerRequest.Node]
        let nodeIDs: [String: String]
        let fillAliases: [String]
        let tapAliases: [String]
    }
    static func project(_ request: AutomationControllerRequest) throws -> Projection {
        try request.validate()
        let nodes = select(request.nodes)
        let entries = nodes.enumerated().map { (alias: "n" + String($0.offset), node: $0.element) }
        return Projection(nodes: nodes, nodeIDs: Dictionary(uniqueKeysWithValues: entries.map { ($0.alias, $0.node.id) }),
            fillAliases: entries.filter {
                request.verbs.contains("fill") && $0.node.visible && !$0.node.disabled && !$0.node.secure
                && ($0.node.editable == true || ($0.node.editable == nil && $0.node.fillSupported == true))
            }.map(\.alias),
            tapAliases: entries.filter {
                request.verbs.contains("tap") && $0.node.visible && !$0.node.disabled && !$0.node.secure
                // A segmented control is an option container. Its observed
                // child buttons own selection; tapping the container cannot
                // identify which option was approved.
                && $0.node.role?.lowercased() != "segmented-control"
            }.map(\.alias))
    }
    static func select(_ nodes: [AutomationControllerRequest.Node], maximum: Int = 48) -> [AutomationControllerRequest.Node] {
        let limit = min(48, max(0, maximum))
        return nodes.enumerated().filter { !$0.element.secure }.sorted { lhs, rhs in
            let a = priority(lhs.element), b = priority(rhs.element)
            if a != b { return a < b }
            let identifiedA = lhs.element.testId != nil, identifiedB = rhs.element.testId != nil
            if identifiedA != identifiedB { return identifiedA }
            return lhs.offset < rhs.offset
        }.prefix(limit).map(\.element)
    }
    private static func priority(_ node: AutomationControllerRequest.Node) -> Int {
        guard node.visible else { return 4 }
        let role = node.role?.lowercased() ?? ""
        let input = node.editable == true || (node.editable == nil && node.fillSupported == true)
        let control = input || ["button", "text-field", "textfield", "textview", "text-view", "segmented-control", "switch", "checkbox", "slider"].contains(role)
        if control && !node.disabled { return input ? 0 : 1 }
        if control { return 2 }
        return node.name?.isEmpty == false || node.text?.isEmpty == false || node.value?.isEmpty == false ? 3 : 4
    }
}
