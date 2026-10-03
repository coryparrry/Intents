import Foundation

enum MCPDeviceTools {
  static let definitions: [MCPToolDefinition] = {
    let s = MCPControlSchema.self
    func tool(
      _ name: String, _ description: String, _ fields: [String: MCPJSONValue] = [:],
      _ required: [String] = [], mutation: Bool = false
    ) -> MCPToolDefinition {
      var fields = fields
      var required = required
      if mutation && name.hasPrefix("eval_intent_") {
        fields["expectedIntentRevision"] = s.text(64)
        required.append("expectedIntentRevision")
      }
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
        ["runID": s.uuid], ["runID"], mutation: true),
      tool(
        "eval_intent_install_inspect",
        "Inspect existing Xcode application/test target IDs and schemes.",
        ["projectPath": s.text(4000)], ["projectPath"]),
      tool(
        "eval_intent_install_preview",
        "Preview the existing guarded integration installer using basic/siri templates. requestJSON has projectPath, optional workspacePath, scheme, applicationTargetID, optional uiTestTargetID, appBundleID, optional packageSource/packageRevision, mode and declarationBase64. Preview is session-bound and writes no project files.",
        ["requestJSON": s.text(2_000_000)], ["requestJSON"], mutation: true),
      tool(
        "eval_intent_install_apply",
        "Apply the exact reviewed session preview after operator confirmation. Rechecks every prior file digest and verifies installation; builds remain separately approved.",
        ["previewID": s.uuid, "previewDigest": s.text(64), "confirm": s.boolean],
        ["previewID", "previewDigest", "confirm"], mutation: true),
      tool(
        "eval_intent_state",
        "Read shared Intent Lab configuration, draft, discovery, readiness and selected IDs with bounded history pages.",
        ["offset": s.number(0, 100000, integer: true), "limit": s.number(1, 50, integer: true)]),
      tool(
        "eval_intent_get",
        "Read one saved definition, run, execution or collection batch by exact ID.",
        [
          "kind": s.choices(["definition", "run", "execution", "collection", "batch"]),
          "id": s.uuid, "version": s.number(1, 100000, integer: true),
        ], ["kind", "id"]),
      tool(
        "eval_intent_select", "Select an existing definition, execution, collection or batch.",
        [
          "kind": s.choices(["definition", "execution", "collection", "batch"]), "id": s.uuid,
          "version": s.number(1, 100000, integer: true),
        ], ["kind", "id"], mutation: true),
      tool(
        "eval_intent_connect",
        "Select an existing Xcode project/workspace, scheme, build configuration, team, provisioning policy or discovered app/test product. Product paths must match discovery. Project selection resets trust; builds need separate approval.",
        [
          "action": s.choices([
            "project", "scheme", "configuration", "team", "provisioning", "application",
            "testBundle", "device", "backend", "assignProject",
          ]), "value": s.text(4000), "enabled": s.boolean, "projectID": s.uuid,
        ], ["action"], mutation: true),
      tool(
        "eval_intent_draft",
        "Replace the authored draft JSON returned by intent_state. Connection identity is retained from the selected target; executable paths cannot be configured through this tool.",
        ["draftJSON": s.text(2_000_000)], ["draftJSON"], mutation: true),
      tool(
        "eval_intent_new",
        "Start a stable check or duplicate the current definition as a new version.",
        ["duplicate": s.boolean], [], mutation: true),
      tool(
        "eval_intent_save", "Validate/freeze/save the current authored definition.", [:], [],
        mutation: true),
      tool(
        "eval_intent_refresh", "Refresh devices or preflight through the existing coordinator.",
        ["kind": s.choices(["devices", "preflight"])], ["kind"], mutation: true),
      tool(
        "eval_intent_build",
        "Approve build and discovery for the exact selected project. Operator confirmation authorizes running its build scripts.",
        ["confirm": s.boolean], ["confirm"], mutation: true),
      tool(
        "eval_intent_verify",
        "Verify installed Intent Lab integration through the selected project's existing route.",
        [:], [], mutation: true),
      tool(
        "eval_intent_run",
        "Dispatch the current frozen requirement, a selected collection, or a saved rerun. Read operation_status and saved evidence for completion. Physical Siri/device readiness remains required.",
        [
          "mode": s.choices(["current", "diagnostic", "execution", "collection", "failedBatch"]),
          "lanesJSON": s.text(1000),
        ], ["mode"], mutation: true),
      tool(
        "eval_intent_cancel",
        "Cancel the active Intent Lab operation and retain recovery evidence.", [:], [],
        mutation: true),
      tool(
        "eval_intent_collection_save", "Create or revise a collection from exact current case IDs.",
        ["name": s.text(200), "caseIDsJSON": s.text(40000), "revise": s.boolean], ["caseIDsJSON"],
        mutation: true),
      tool(
        "eval_intent_variation_approve",
        "Add an explicitly operator-approved request variation to the selected collection.",
        ["approvalJSON": s.text(200000), "confirm": s.boolean], ["approvalJSON", "confirm"],
        mutation: true),
      tool(
        "eval_intent_suggest",
        "Generate request suggestions for the current requirement. Suggestions remain proposals.",
        [:], [], mutation: true),
      tool(
        "eval_intent_suggestion_approve",
        "Approve one generated suggestion on behalf of the operator.",
        ["suggestionID": s.uuid, "confirm": s.boolean], ["suggestionID", "confirm"], mutation: true),
      tool(
        "eval_intent_assess",
        "Freeze judge policy, reassess original evidence, or select a saved assessment on one execution coordinate.",
        [
          "action": s.choices(["freeze", "reassess", "select"]), "coordinateID": s.uuid,
          "assertionID": s.uuid, "assessmentID": s.uuid, "judgeJSON": s.text(32000),
        ], ["action", "coordinateID"], mutation: true),
      tool(
        "eval_intent_recover",
        "Retry a pending ordinary, feature, native or assessment-selection save without rerunning the app.",
        [
          "kind": s.choices(["ordinary", "feature", "native", "assessment"]), "id": s.uuid,
          "coordinateID": s.uuid,
        ], ["kind"], mutation: true),
      tool(
        "eval_intent_quarantine_clear",
        "Clear device quarantine only after operator-proven fixture readiness.",
        ["fixtureReadinessProven": s.boolean, "confirm": s.boolean],
        ["fixtureReadinessProven", "confirm"], mutation: true),
      tool(
        "eval_intent_export",
        "Export the selected execution or batch into a bounded app-owned evidence directory. Read files using production_export_list/read.",
        ["kind": s.choices(["execution", "batch"])], ["kind"], mutation: true),
    ]
  }()
}
