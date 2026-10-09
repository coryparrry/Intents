import Foundation

/// A fresh, app-bound accessibility capture. The native owner independently
/// selects and decodes the property; the controller never supplies the answer.
public struct AutomationUIReadback: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var index: Int
        public var parentIndex: Int?
        public var identifier: String?
        public var label: String?
        public var value: String?
        public var ownerBundle: String?
        public var blocked: Bool
        public var hidden: Bool
        public var visible: Bool
        public var disabled: Bool
        public var secure: Bool
        public var checked: Bool?
        public var selected: Bool?
    }
    public var schemaVersion: Int
    public var appBundleId: String
    public var targetId: String
    public var complete: Bool
    public var nodes: [Node]
    public func extract(operation: AutomationUIProgram.Operation, app: AppIdentity, target: TargetIdentity) throws -> AutomationValue {
        guard schemaVersion == 1, appBundleId == app.bundleID, targetId == target.id, complete,
              (1...5000).contains(nodes.count), operation.kind == .observeProperty, let locator = operation.locator,
              locator.role == nil, locator.kind != .role, Set(nodes.map(\.index)).count == nodes.count else { throw AutomationContractError.missingEvidence("Invalid UI capture identity or completeness") }
        let byIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.index, $0) })
        for node in nodes {
            guard node.index >= 0, node.identifier.map({ $0.utf16.count <= 1024 }) ?? true,
                  node.label.map({ $0.utf16.count <= 32768 }) ?? true, node.value.map({ $0.utf16.count <= 32768 }) ?? true,
                  !node.secure || (node.label == nil && node.value == nil) else { throw AutomationContractError.missingEvidence("Invalid or unredacted UI capture") }
            var cursor: Node? = node, seen = Set<Int>(), secureAncestry = false
            while let current = cursor {
                guard seen.count <= 32, seen.insert(current.index).inserted else { throw AutomationContractError.missingEvidence("Invalid UI ancestry") }
                secureAncestry = secureAncestry || current.secure
                if let parent = current.parentIndex {
                    guard let parentNode = byIndex[parent] else { throw AutomationContractError.missingEvidence("Incomplete UI ancestry") }
                    cursor = parentNode
                } else { cursor = nil }
            }
            guard !secureAncestry || (node.label == nil && node.value == nil) else { throw AutomationContractError.missingEvidence("Unredacted secure descendant") }
        }
        let matches = nodes.filter { locator.kind == .testId ? $0.identifier == locator.value : $0.label == locator.value }
        guard matches.count == 1, let node = matches.first, node.visible, !node.disabled, !node.secure else {
            throw AutomationContractError.missingEvidence("UI readback requires one visible nonsecure node")
        }
        var ancestor: Node? = node
        while let current = ancestor {
            guard !current.blocked, !current.hidden, !current.disabled, !current.secure,
                  current.ownerBundle.map({ $0.isEmpty || $0 == app.bundleID }) ?? true else { throw AutomationContractError.missingEvidence("UI ancestry or owner contradicts selected node") }
            ancestor = current.parentIndex.flatMap { byIndex[$0] }
        }
        switch operation.property {
        case "text": if let value = node.label { return .text(value) }
        case "value": if let value = node.value { return .text(value) }
        case "checked": if let value = node.checked { return .bool(value) }
        case "selected": if let value = node.selected { return .bool(value) }
        default: break
        }
        throw AutomationContractError.missingEvidence("UI property was not observed")
    }
    static func storeVerified(receipt: AutomationJSON, outputs: [String: AutomationJSON], program: AutomationUIProgram,
                              app: AppIdentity, target: TargetIdentity, scope: AutomationScope,
                              artifacts: AutomationArtifactRegistry, name: String) async throws -> ([String: AutomationValue], AutomationArtifactRegistry.Artifact) {
        guard receipt.object?["outputs"] == .object(outputs) else { throw AutomationContractError.missingEvidence("UI receipt/output mismatch") }
        let verified = try Self.outputs(outputs, program: program, app: app, target: target)
        let data = try JSONEncoder().encode(receipt)
        let artifact = try await artifacts.store(data: data, name: name, scope: scope)
        return (verified, artifact)
    }
    public static func outputs(_ outputs: [String: AutomationJSON], program: AutomationUIProgram, app: AppIdentity, target: TargetIdentity) throws -> [String: AutomationValue] {
        var verified: [String: AutomationValue] = [:]
        for operation in program.operations where operation.kind == .observeProperty {
            guard let payload = outputs[operation.id] else { throw AutomationContractError.missingEvidence("Missing UI readback") }
            guard let fields = payload.object, Set(fields.keys) == ["schemaVersion", "appBundleId", "targetId", "complete", "nodes"],
                  case .array(let nodes) = fields["nodes"], nodes.allSatisfy({ node in
                      guard let fields = node.object else { return false }
                      return Set(fields.keys).isSubset(of: ["index", "parentIndex", "identifier", "label", "value", "ownerBundle", "blocked", "hidden", "visible", "disabled", "secure", "checked", "selected"])
                  }) else { throw AutomationContractError.missingEvidence("Unexpected UI capture fields") }
            let capture = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
            verified[operation.id] = try capture.extract(operation: operation, app: app, target: target)
        }
        return verified
    }
}
