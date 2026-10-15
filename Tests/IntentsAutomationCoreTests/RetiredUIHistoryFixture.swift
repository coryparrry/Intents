import Foundation
@testable import IntentsAutomationCore

/// Historical JSON only: no retired executable model is linked into the tests.
func retiredUIHistoryFixture(_ frozen: AutomationFrozenCase, id: String) throws -> (data: Data, digest: String) {
    var object = try JSONSerialization.jsonObject(with: AutomationFrozenCase.canonicalData(frozen)) as! [String: Any]
    var plan = object["plan"] as! [String: Any]; plan["id"] = id
    var execution = plan["execution"] as! [String: Any]
    execution["kind"] = "ui"
    let program: [String: Any] = ["operations": [["id": "navigate", "kind": "navigateGoal", "goal": [
        "id": "goal", "instruction": "Open tasks", "endpoint": ["kind": "label", "value": "Tasks"],
        "maximumCalls": 12, "maximumActions": 30]]], "bindings": [String: String](), "timeoutMilliseconds": 120000]
    execution["uiProgram"] = program; plan["execution"] = execution
    object["plan"] = plan
    let digest = AutomationArtifactRegistry.digest(try historyJSON(plan)); object["digest"] = digest
    return (try historyJSON(object), digest)
}
func historyJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
func writeRetiredHistory(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
