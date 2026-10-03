import Foundation

enum MCPWorkspaceTools {
  static let definitions: [MCPToolDefinition] = {
    let s = MCPControlSchema.self
    let revision = ["expectedWorkspaceRevision": s.text(64)]
    let suite = ["projectID": s.uuid, "suiteID": s.uuid, "expectedRevision": s.text(64)]
    func tool(
      _ name: String, _ description: String, _ fields: [String: MCPJSONValue] = [:],
      required: [String] = [], destructive: Bool = false
    ) -> MCPToolDefinition {
      s.tool(
        name, description, fields.merging(revision) { a, _ in a },
        required: required + ["expectedWorkspaceRevision"], mutation: true, destructive: destructive
      )
    }
    return [
      s.tool(
        "eval_control_capabilities",
        "Describe all controllable app workflows and the authenticated connector boundary."),
      s.tool(
        "eval_review_patterns", "Read clustered failure tags from exact saved review evidence."),
      s.tool(
        "eval_workspace_state",
        "Read projects, selected IDs, workspace revision, local review/experiment state, judge connections and model readiness."
      ),
      s.tool(
        "eval_operation_result_read",
        "Read a bounded base64 chunk of a large persisted operation result advertised by its receipt.",
        [
          "operationID": s.uuid, "offset": s.number(0, 8_388_608, integer: true),
          "bytes": s.number(1, 262144, integer: true),
        ], required: ["operationID"]),
      s.tool(
        "eval_operation_status",
        "Read a stable mutation receipt. Interrupted operations require state inspection before another action.",
        ["operationID": s.uuid], required: ["operationID"]),
      tool(
        "eval_workspace_navigate",
        "Show a workspace section and optionally a batch pane or saved run.",
        [
          "section": s.choices([
            "overview", "intentLab", "evaluations", "batchRuns", "traces", "suite", "run",
          ]), "pane": s.choices(["datasets", "jobs", "review", "reports", "workers"]),
          "jobID": s.uuid, "runID": s.uuid,
        ], required: ["section"]),
      tool(
        "eval_workspace_select",
        "Select an explicit project and suite in the shared app workspace.",
        ["projectID": s.uuid, "suiteID": s.uuid], required: ["projectID", "suiteID"]),
      tool(
        "eval_project_create", "Create and select a project with a starter suite.",
        ["name": s.text(200)], required: ["name"]),
      tool(
        "eval_project_rename", "Rename an explicit project.",
        ["projectID": s.uuid, "name": s.text(200)], required: ["projectID", "name"]),
      tool(
        "eval_project_duplicate", "Duplicate a project and its saved suites.",
        ["projectID": s.uuid], required: ["projectID"]),
      tool(
        "eval_project_archive", "Archive a project with explicit operator confirmation.",
        ["projectID": s.uuid, "confirm": s.boolean], required: ["projectID", "confirm"],
        destructive: true),
      tool(
        "eval_suite_create", "Create and select a suite in the selected explicit project.",
        ["projectID": s.uuid, "name": s.text(200)], required: ["projectID", "name"]),
      tool(
        "eval_suite_rename", "Rename an explicit suite in the selected project.",
        ["projectID": s.uuid, "suiteID": s.uuid, "name": s.text(200)],
        required: ["projectID", "suiteID", "name"]),
      tool(
        "eval_suite_duplicate", "Duplicate an explicit suite in the selected project.",
        ["projectID": s.uuid, "suiteID": s.uuid], required: ["projectID", "suiteID"]),
      tool(
        "eval_suite_archive", "Archive an explicit suite with operator confirmation.",
        ["projectID": s.uuid, "suiteID": s.uuid, "confirm": s.boolean],
        required: ["projectID", "suiteID", "confirm"], destructive: true),
      tool(
        "eval_suite_configure",
        "Replace the full native suite JSON returned in workspace state, including judge and release policy. Keep identity/attachment metadata unchanged. Run admission preserves readiness validation.",
        suite.merging(["suiteJSON": s.text(8_000_000), "confirmDeletes": s.boolean]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "suiteJSON"]),
      tool(
        "eval_suite_reset", "Reset the selected explicit suite after confirmation.",
        suite.merging(["confirm": s.boolean]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "confirm"], destructive: true),
      tool(
        "eval_clear_run_history",
        "Permanently clear the selected suite's saved runs after confirmation.",
        suite.merging(["confirm": s.boolean]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "confirm"], destructive: true),
      tool(
        "eval_project_repository_link",
        "Link the selected project/suite to an existing Git root after operator confirmation. Existing conflicting definitions are preserved.",
        suite.merging(["rootPath": s.text(4000), "confirm": s.boolean]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "rootPath", "confirm"]),
      tool(
        "eval_run_save_retry",
        "Retry pending local evidence persistence without running inference again.", suite,
        required: ["projectID", "suiteID", "expectedRevision"]),
      tool(
        "eval_baseline_approve",
        "Approve complete compatible evidence as a baseline with explicit operator approval.",
        suite.merging([
          "runID": s.uuid, "assessmentID": s.uuid, "note": s.text(4000, minimum: 0),
          "confirm": s.boolean,
        ]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "runID", "confirm"]),
      tool(
        "eval_experiment_create", "Freeze an instruction candidate against the selected suite.",
        suite.merging(["name": s.text(200), "instructions": s.text(32000)]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "name", "instructions"]),
      tool(
        "eval_experiment_run",
        "Start the existing balanced instruction experiment. Inspect its saved run IDs before qualification.",
        suite.merging(["experimentID": s.uuid]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "experimentID"]),
      tool(
        "eval_experiment_decide",
        "Record an explicit experiment decision; candidate adoption retains the existing revision and evidence guards.",
        suite.merging([
          "experimentID": s.uuid,
          "decision": s.choices(EvaluationExperimentDecision.allCases.map(\.rawValue)),
          "confirm": s.boolean,
        ]) { a, _ in a },
        required: [
          "projectID", "suiteID", "expectedRevision", "experimentID", "decision", "confirm",
        ]),
      tool(
        "eval_review_save",
        "Record a user-authorized review of an exact captured source. confirmHumanReview attests operator review; never infer it from an agent's own judgment. Annotation JSON follows workspace review state.",
        suite.merging(["annotationJSON": s.text(20000), "confirmHumanReview": s.boolean]) { a, _ in
          a
        },
        required: [
          "projectID", "suiteID", "expectedRevision", "annotationJSON", "confirmHumanReview",
        ]),
      tool(
        "eval_review_decide_proposal",
        "Accept/reject a pending agent proposal with explicit operator confirmation.",
        suite.merging(["proposalID": s.uuid, "accept": s.boolean, "confirm": s.boolean]) { a, _ in a
        },
        required: ["projectID", "suiteID", "expectedRevision", "proposalID", "accept", "confirm"]),
      tool(
        "eval_review_promote",
        "Promote a current operator review to a regression with a verified expected answer.",
        suite.merging(["reviewID": s.uuid, "expected": s.text(32000), "confirm": s.boolean]) {
          a, _ in a
        },
        required: ["projectID", "suiteID", "expectedRevision", "reviewID", "expected", "confirm"]),
      tool(
        "eval_judge_check_add",
        "Add an operator-reviewed sample to development or held-out judge calibration.",
        suite.merging(["reviewID": s.uuid, "partition": s.choices(["development", "test"])]) {
          a, _ in a
        }, required: ["projectID", "suiteID", "expectedRevision", "reviewID", "partition"]),
      tool(
        "eval_judge_check_partition", "Move a calibration example to an explicit partition.",
        suite.merging(["exampleID": s.uuid, "partition": s.choices(["development", "test"])]) {
          a, _ in a
        }, required: ["projectID", "suiteID", "expectedRevision", "exampleID", "partition"]),
      tool(
        "eval_judge_checks_run", "Start calibration using the selected approved judge connection.",
        suite.merging(["connectionID": s.uuid]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "connectionID"]),
      tool(
        "eval_judge_connection_save",
        "Save native connection JSON and optionally a write-only API key. Secrets never appear in state or receipts.",
        ["connectionJSON": s.text(32000), "apiKey": s.text(8000)], required: ["connectionJSON"]),
      tool(
        "eval_judge_connection_delete",
        "Delete an explicit judge connection and its secret after confirmation.",
        ["connectionID": s.uuid, "confirm": s.boolean], required: ["connectionID", "confirm"],
        destructive: true),
      tool(
        "eval_judge_connection_check",
        "Check an explicit judge connection and read the resulting status in workspace state.",
        ["connectionID": s.uuid], required: ["connectionID"]),
      tool(
        "eval_judge_disclosure_approve",
        "Approve the exact currently selected external judge disclosure on behalf of the operator.",
        suite.merging(["disclosureDigest": s.text(64), "confirm": s.boolean]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "disclosureDigest", "confirm"]),
      tool(
        "eval_reassess_run",
        "Start reassessment of a saved run using the selected judge, preserving subject evidence.",
        suite.merging(["runID": s.uuid, "connectionID": s.uuid]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "runID", "connectionID"]),
      tool(
        "eval_assessment_select", "Select a saved assessment without regenerating subject output.",
        suite.merging(["runID": s.uuid, "assessmentID": s.uuid]) { a, _ in a },
        required: ["projectID", "suiteID", "expectedRevision", "runID", "assessmentID"]),
      tool(
        "eval_coreai_load",
        "Load the currently configured Core AI model through the app's existing lifecycle.", suite,
        required: ["projectID", "suiteID", "expectedRevision"]),
    ]
  }()
}
