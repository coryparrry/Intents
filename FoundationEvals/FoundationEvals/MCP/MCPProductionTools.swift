import Foundation

enum MCPProductionTools {
  static let definitions: [MCPToolDefinition] = {
    let s = MCPControlSchema.self
    func read(
      _ name: String, _ description: String, _ fields: [String: MCPJSONValue] = [:],
      _ required: [String] = []
    ) -> MCPToolDefinition {
      s.tool("eval_production_" + name, description, fields, required: required)
    }
    func write(
      _ name: String, _ description: String, _ fields: [String: MCPJSONValue], _ required: [String],
      destructive: Bool = false
    ) -> MCPToolDefinition {
      s.tool(
        "eval_production_" + name, description, fields, required: required, mutation: true,
        destructive: destructive)
    }
    let job: [String: MCPJSONValue] = ["jobID": s.uuid, "expectedJobRevision": s.text(64)]
    let target: [String: MCPJSONValue] = [
      "projectID": s.uuid, "suiteID": s.uuid, "expectedRevision": s.text(64),
    ]
    return [
      read(
        "state",
        "List bounded dataset/job/worker/schedule pages. Frozen execution contexts are omitted.",
        ["offset": s.number(0, 100000, integer: true), "limit": s.number(1, 100, integer: true)]),
      write(
        "upload_begin",
        "Begin an immutable JSONL upload with SHA256 of the complete raw bytes. Examples follow ProductionExample; dates are Unix milliseconds. No filesystem path is accepted.",
        [
          "uploadID": s.uuid, "name": s.text(200), "version": s.text(100),
          "sampling": s.choices(["curated", "random", "targeted"]), "productionData": s.boolean,
          "chunks": s.number(1, 1024, integer: true),
          "bytes": s.number(1, 1_000_000_000, integer: true), "sha256": s.text(64),
        ], ["uploadID", "name", "version", "chunks", "bytes", "sha256"]),
      write(
        "upload_chunk",
        "Append up to 1 MiB of raw bytes, base64 encoded. Identical retries are safe; different bytes at the same index fail.",
        [
          "uploadID": s.uuid, "index": s.number(0, 1023, integer: true),
          "dataBase64": s.text(1_398_104),
        ], ["uploadID", "index", "dataBase64"]),
      read(
        "upload_status", "Read upload contract and received chunk indexes.", ["uploadID": s.uuid],
        ["uploadID"]),
      write(
        "upload_preview",
        "Verify all chunks and SHA256; seal source and return three examples. This makes no model calls.",
        ["uploadID": s.uuid], ["uploadID"]),
      write(
        "upload_finish",
        "Import the exact previewed source as an immutable dataset. Production data requires operator redaction confirmation.",
        ["uploadID": s.uuid, "previewDigest": s.text(64), "redactionConfirmed": s.boolean],
        ["uploadID", "previewDigest"]),
      write(
        "upload_discard",
        "Discard staging bytes after operator confirmation; immutable datasets remain available.",
        ["uploadID": s.uuid, "confirm": s.boolean], ["uploadID", "confirm"], destructive: true),
      read(
        "dataset_get", "Read dataset manifest and bounded examples.",
        [
          "revision": s.text(64), "offset": s.number(0, 1_000_000, integer: true),
          "limit": s.number(1, 10, integer: true),
        ], ["revision"]),
      write(
        "dataset_snapshot", "Freeze the selected native suite as a dataset.", target,
        ["projectID", "suiteID", "expectedRevision"]),
      write(
        "job_create",
        "Freeze native suite execution or captured output review. Native optionsJSON may set repetitions, chunkSize, maximumAttempts, timeoutSeconds, maximumElapsedSeconds, cost bounds, targets, gate and baselineJobID. Execution/scoring identity and replay safety come from the app.",
        target.merging([
          "jobID": s.uuid, "datasetRevision": s.text(64), "name": s.text(200),
          "kind": s.choices(["native", "captured"]), "optionsJSON": s.text(32000),
        ]) { a, _ in a },
        ["projectID", "suiteID", "expectedRevision", "jobID", "datasetRevision", "name", "kind"]),
      write(
        "job_clone",
        "Clone a frozen job with a stable new ID; preserves scoring, target and dataset contracts.",
        job.merging(["newJobID": s.uuid, "name": s.text(200)]) { a, _ in a },
        ["jobID", "expectedJobRevision", "newJobID", "name"]),
      read(
        "job_get",
        "Read frozen job metadata, control and report. Execution context is retrieved separately in bounded chunks.",
        ["jobID": s.uuid], ["jobID"]),
      read(
        "context_read",
        "Read base64 frozen execution context bytes. Never contains authentication secrets.",
        [
          "jobID": s.uuid, "offset": s.number(0, 67_108_864, integer: true),
          "bytes": s.number(1, 262144, integer: true),
        ], ["jobID"]),
      write(
        "job_start",
        "Start/resume the frozen job on this Mac. Reply acknowledges dispatch; poll job_get for completion, errors and gates. External disclosure approval is explicit.",
        job.merging(["externalDisclosureApproved": s.boolean]) { a, _ in a },
        ["jobID", "expectedJobRevision"]),
      write(
        "baseline_approve",
        "Approve complete eligible baseline evidence after operator review. Approval binds the frozen job and exact report evidence; later reviews/cancellation invalidate it.",
        job.merging(["expectedEvidenceRevision": s.text(64), "note": s.text(4000), "confirm": s.boolean]) { a, _ in a },
        ["jobID", "expectedJobRevision", "expectedEvidenceRevision", "note", "confirm"]),
      write(
        "job_control",
        "Pause, resume or permanently cancel an explicit job. Cancelling retains evidence; clone to run again.",
        job.merging([
          "paused": s.boolean, "cancelled": s.boolean, "expectedControlRevision": s.text(64),
        ]) { a, _ in a }, ["jobID", "expectedJobRevision", "expectedControlRevision"]),
      read(
        "results",
        "Read bounded result summaries. Use result_get for one full result and review audit.",
        [
          "jobID": s.uuid, "offset": s.number(0, 10_000_000, integer: true),
          "limit": s.number(1, 100, integer: true),
        ], ["jobID"]),
      read(
        "result_get",
        "Read one completed slot with bounded source and original response plus review audit.",
        ["jobID": s.uuid, "slot": s.number(0, 9_999_999, integer: true)], ["jobID", "slot"]),
      write(
        "review_append",
        "Append an operator-authorized immutable review, assignment, adjudication or reconciliation. eventJSON follows ProductionReviewEvent with Unix millisecond dates.",
        job.merging([
          "slot": s.number(0, 9_999_999, integer: true), "eventJSON": s.text(400000),
          "confirmHumanReview": s.boolean,
        ]) { a, _ in a },
        ["jobID", "expectedJobRevision", "slot", "eventJSON", "confirmHumanReview"]),
      write(
        "schedule_save",
        "Save bounded schedule JSON (Unix millisecond dates). Schedules create jobs when ticked; execution remains explicit.",
        [
          "scheduleJSON": s.text(10000), "confirm": s.boolean,
          "expectedScheduleRevision": s.text(64),
        ], ["scheduleJSON", "confirm", "expectedScheduleRevision"]),
      write(
        "schedule_tick",
        "Create due jobs and advance schedules once. This does not start inference.", [:], []),
      write(
        "export", "Freeze an evidence export in the app-owned MCP directory.", job,
        ["jobID", "expectedJobRevision"]),
      read(
        "export_list", "List files of one retained MCP export, with bounded pagination.",
        [
          "exportID": s.uuid, "offset": s.number(0, 100000, integer: true),
          "limit": s.number(1, 100, integer: true),
        ], ["exportID"]),
      read(
        "export_read",
        "Read a bounded export file chunk by exact relative manifest path; traversal and symlinks are rejected.",
        [
          "exportID": s.uuid, "path": s.text(500),
          "offset": s.number(0, 1_000_000_000, integer: true),
          "bytes": s.number(1, 262144, integer: true),
        ], ["exportID", "path"]),
    ]
  }()
}
enum MCPControlTools {
  static let definitions =
    MCPWorkspaceTools.definitions + MCPProductionTools.definitions + MCPDeviceTools.definitions
  static let names = Set(definitions.map(\.name))
}
