import Foundation
import IntentsAutomationCore

/// Engineering-only controller evaluation. It owns no device and dispatches no UI action.
@main enum ControllerProbe {
    struct Case: Decodable {
        let id: String
        let goal: AutomationNavigationGoal
        let bindings: [String: String]
        let request: AutomationControllerRequest
        let expectedKinds: [String]
        let expectedNodeIDs: [String]?
    }
    struct Profile: Decodable { let cases: [Case] }
    struct Result: Encodable {
        let id: String
        let kind: String
        let nodeID: String?
        let nodeName: String?
        let bindingName: String?
        let expectedClass: Bool
        let expectedTarget: Bool
        let exactObservedTarget: Bool
        let permittedBinding: Bool
        let requiredActivityRespected: Bool
        let errorType: String?
    }
    struct Report: Encodable {
        let scope = "retained snapshot controller contract; no app actions or recipe qualification"
        let results: [Result]
        let passed: Bool
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--profile" else {
                throw AutomationContractError.invalidIdentity
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            guard bytes.count <= 4 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            let profile = try JSONDecoder().decode(Profile.self, from: bytes)
            guard (1...5).contains(profile.cases.count), Set(profile.cases.map(\.id)).count == profile.cases.count, profile.cases.allSatisfy({ $0.id.utf16.count <= 128 }) else {
                throw AutomationContractError.invalidIdentity
            }
            let controller = AutomationFoundationController()
            var results: [Result] = []
            for item in profile.cases {
                try item.goal.validate(); try item.request.validate()
                guard item.request.goalId == item.goal.id, item.bindings.count <= 30,
                      item.bindings.allSatisfy({ $0.key.range(of: #"^[A-Za-z0-9_.:-]{1,256}$"#, options: .regularExpression) != nil && $0.value.utf16.count <= 32768 }),
                      !item.expectedKinds.isEmpty, Set(item.expectedKinds).isSubset(of: ["tap", "fill", "scroll", "finish", "cannotProceed"]) else {
                    throw AutomationContractError.invalidIdentity
                }
                try ControllerSnapshotTargetExpectation.validate(item.expectedNodeIDs, kinds: item.expectedKinds,
                    observed: Set(item.request.nodes.map(\.id)))
                do {
                    let decision = try await withThrowingTaskGroup(of: AutomationControllerDecision.self) { group in
                        group.addTask { try await controller.decide(goal: item.goal, request: item.request, bindings: item.bindings) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(30))
                            throw AutomationContractError.missingEvidence("Snapshot controller deadline expired")
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                    _ = try decision.action(request: item.request, bindings: item.bindings, phase: .setup, allowedFillBindings: item.goal.allowedFillBindings)
                    let target = decision.node == nil || item.request.nodes.contains { $0.id == decision.node }
                    let binding = decision.kind != "fill" || (decision.textBinding != nil && item.bindings[decision.textBinding!] != nil &&
                        (item.goal.allowedFillBindings == nil || item.goal.allowedFillBindings!.contains(decision.textBinding!)))
                    let activity = decision.kind != "finish" || (item.goal.minimumBindingUses ?? [:]).allSatisfy { (item.request.approvedBindingUses?[$0.key] ?? 0) >= $0.value }
                    results.append(.init(id: item.id, kind: decision.kind, nodeID: decision.node, nodeName: item.request.nodes.first(where: { $0.id == decision.node })?.name, bindingName: decision.textBinding, expectedClass: item.expectedKinds.contains(decision.kind), expectedTarget: ControllerSnapshotTargetExpectation.matches(item.expectedNodeIDs, node: decision.node), exactObservedTarget: target, permittedBinding: binding, requiredActivityRespected: activity, errorType: nil))
                } catch {
                    results.append(.init(id: item.id, kind: "error", nodeID: nil, nodeName: nil, bindingName: nil, expectedClass: false, expectedTarget: false, exactObservedTarget: false, permittedBinding: false, requiredActivityRespected: false, errorType: String(reflecting: type(of: error))))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = Report(results: results, passed: results.allSatisfy { $0.expectedClass && $0.expectedTarget && $0.exactObservedTarget && $0.permittedBinding && $0.requiredActivityRespected })
            FileHandle.standardOutput.write(try encoder.encode(report))
            if !report.passed { exit(2) }
        } catch {
            FileHandle.standardError.write(Data((String(reflecting: type(of: error)) + "\n").utf8)); exit(1)
        }
    }
}

/// Grading data stays outside the controller call and never authorises an action.
enum ControllerSnapshotTargetExpectation {
    static func validate(_ ids: [String]?, kinds: [String], observed: Set<String>) throws {
        guard let ids else { return }
        guard (1...30).contains(ids.count), Set(ids).count == ids.count,
              Set(ids).isSubset(of: observed), !kinds.isEmpty,
              Set(kinds).isSubset(of: ["tap", "fill"]) else { throw AutomationContractError.invalidIdentity }
    }
    static func matches(_ ids: [String]?, node: String?) -> Bool {
        guard let ids else { return true }
        guard let node else { return false }
        return ids.contains(node)
    }
}
