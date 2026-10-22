import Foundation

enum MCPDeviceTools {
  static let definitions: [MCPToolDefinition] = {
    let s = MCPControlSchema.self
    func tool(
      _ name: String, _ description: String, _ fields: [String: MCPJSONValue] = [:],
      _ required: [String] = [], mutation: Bool = false
    ) -> MCPToolDefinition {
      let fields = fields
      let required = required
      return s.tool(name, description, fields, required: required, mutation: mutation)
    }
    return [
      tool(
        "eval_runner_state",
        "Read discovered runners, capabilities, connection and run status. Pairing codes and trust secrets are omitted."
      ),
      tool(
        "eval_runner_select", "Select an advertised runner and feature without executing it.",
        ["runnerID": s.uuid, "featureID": s.text(200)], ["runnerID"], mutation: true),
      tool(
        "eval_runner_discovery", "Start or stop Bonjour discovery.", ["enabled": s.boolean],
        ["enabled"], mutation: true),
      tool(
        "eval_runner_pair",
        "Begin/cancel pairing with an explicit runner. Compare the code shown on the device before trust.",
        ["runnerID": s.uuid, "cancel": s.boolean], ["runnerID"], mutation: true),
      tool(
        "eval_runner_trust",
        "Trust a runner after the operator compares the physical pairing code.",
        ["runnerID": s.uuid, "pairingCode": s.text(20), "confirmCodeCompared": s.boolean],
        ["runnerID", "pairingCode", "confirmCodeCompared"], mutation: true),
      tool(
        "eval_runner_disconnect",
        "Disconnect one runner or forget its saved trust after operator confirmation.",
        ["runnerID": s.uuid, "forgetTrust": s.boolean, "confirm": s.boolean], ["runnerID"],
        mutation: true),
      tool(
        "eval_runner_run",
        "Dispatch the selected suite to an advertised developer feature. Poll runner_state and eval_get_run for evidence.",
        [
          "runnerID": s.uuid, "featureID": s.text(200), "timeoutSeconds": s.number(1, 3600),
          "projectID": s.uuid, "suiteID": s.uuid, "expectedRevision": s.text(64),
        ], ["runnerID", "featureID", "projectID", "suiteID", "expectedRevision"], mutation: true),
      tool(
        "eval_runner_cancel", "Cancel one developer run while retaining its evidence.",
        ["runID": s.uuid], ["runID"], mutation: true)
    ]
  }()
}
