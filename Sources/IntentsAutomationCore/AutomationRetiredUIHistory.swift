import Foundation

public struct AutomationHistoryListing<Item: Sendable>: Sendable {
    public let items: [Item]
    public let skippedRetiredRecords: Int
}

/// Classification after typed decoding fails. An excluded record is unsupported,
/// not verified evidence; no migrated plan is returned or made executable.
enum AutomationRetiredUIHistory {
    static func definition(_ data: Data, id: String, revision: Int, digest: String) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = object["plan"] as? [String: Any], containsRetiredOperation(plan) else { return false }
        try checkEnvelope(object)
        guard plan["id"] as? String == id, plan["revision"] as? Int == revision,
              object["digest"] as? String == digest else { throw AutomationContractError.conflictingOperation }
        return true
    }

    static func search(_ data: Data, id: String) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseline = object["baseline"] as? [String: Any],
              let mutations = object["mutations"] as? [[String: Any]] else { return false }
        let definitions = [baseline] + mutations.compactMap { $0["frozen"] as? [String: Any] }
        guard definitions.contains(where: { ($0["plan"] as? [String: Any]).map(containsRetiredOperation) == true }) else { return false }
        guard let version = object["schemaVersion"] as? Int, [1, 2, 3, 5].contains(version), object["id"] as? String == id,
              let runID = object["runID"] as? String, AutomationUIFailureSearchRecord.identifier(runID),
              definitions.count == mutations.count + 1 else { throw AutomationContractError.conflictingOperation }
        for definition in definitions { try checkEnvelope(definition) }
        return true
    }

    private static func checkEnvelope(_ object: [String: Any]) throws {
        guard object["schemaVersion"] as? Int == 1, let plan = object["plan"] as? [String: Any],
              plan["schemaVersion"] as? Int == 3, let id = plan["id"] as? String,
              AutomationUIFailureSearchRecord.identifier(id), let revision = plan["revision"] as? Int, revision > 0,
              let digest = object["digest"] as? String,
              digest == AutomationArtifactRegistry.digest(try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys, .withoutEscapingSlashes])) else {
            throw AutomationContractError.conflictingOperation
        }
    }

    private static func containsRetiredOperation(_ plan: [String: Any]) -> Bool {
        let segments = [plan["execution"] as? [String: Any]].compactMap { $0 } +
            ["setup", "observations", "cleanup"].flatMap { plan[$0] as? [[String: Any]] ?? [] }
        return segments.contains { segment in
            guard segment["kind"] as? String == "ui", let program = segment["uiProgram"] as? [String: Any],
                  let operations = program["operations"] as? [[String: Any]] else { return false }
            return operations.contains { $0["kind"] as? String == "navigateGoal" }
        }
    }
}
