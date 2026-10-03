import Foundation
import Testing

@testable import FoundationEvals

@MainActor struct MCPAppControlTests {
  private func fixture() throws -> (EvaluationAppControl, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-control-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (EvaluationAppControl(store: EvaluationStore(supportDirectory: root)), root)
  }
  private func call(_ name: String, _ fields: [String: MCPJSONValue], control: EvaluationAppControl)
    async throws -> MCPToolPayload
  {
    let parsed = try MCPToolCatalog.parse(name: name, arguments: .object(fields))
    return await MCPStoreAuthority.make(store: control.store, control: control).call(parsed)
  }
  private func workspace(_ control: EvaluationAppControl) throws -> [String: MCPJSONValue] {
    [
      "operationID": .string(UUID().uuidString),
      "expectedWorkspaceRevision": .string(try MCPWorkspaceControl.revision(control.store)),
    ]
  }
  @Test func discoveryAndStrictSchemas() throws {
    let definitions = MCPToolCatalog.definitions
    #expect(Set(definitions.map(\.name)).count == definitions.count)
    for name in [
      "eval_project_create", "eval_production_upload_begin", "eval_production_job_start",
      "eval_intent_run", "eval_runner_trust",
    ] { #expect(definitions.contains(where: { $0.name == name })) }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_production_upload_chunk",
        arguments: .object([
          "uploadID": .string(UUID().uuidString), "index": .number(0.5),
          "dataBase64": .string("YQ=="), "operationID": .string(UUID().uuidString),
        ]))
    }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_runner_discovery",
        arguments: .object(["enabled": .string("true"), "operationID": .string(UUID().uuidString)]))
    }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_project_create",
        arguments: .object([
          "name": .string("fixture"), "operationID": .string(UUID().uuidString),
          "expectedWorkspaceRevision": .string("revision"), "shell": .string("arbitrary"),
        ]))
    }
  }
  @Test func workspaceMutationReceiptsSurviveRestartAndRejectConflicts() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = try workspace(control)
    request["name"] = .string("MCP created")
    let first = try await call("eval_project_create", request, control: control)
    #expect(!first.isError)
    let count = control.store.projects.count
    let retry = try await call("eval_project_create", request, control: control)
    #expect(!retry.isError)
    #expect(retry.structuredContent.objectValue?["duplicate"] == .bool(true))
    #expect(control.store.projects.count == count)
    let restarted = EvaluationAppControl(store: EvaluationStore(supportDirectory: root))
    let replay = try await call("eval_project_create", request, control: restarted)
    #expect(!replay.isError)
    #expect(restarted.store.projects.count == count)
    request["name"] = .string("different")
    #expect(try await call("eval_project_create", request, control: restarted).isError)
    request["operationID"] = .string(UUID().uuidString)
    #expect(try await call("eval_project_create", request, control: restarted).isError)
  }
  @Test func confirmationsAndNavigationShareAppState() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var fields = try workspace(control)
    fields["projectID"] = .string(control.store.selectedProjectID.uuidString)
    fields["confirm"] = .bool(false)
    #expect(try await call("eval_project_archive", fields, control: control).isError)
    var navigate = try workspace(control)
    navigate["section"] = .string("batchRuns")
    navigate["pane"] = .string("workers")
    #expect(!(try await call("eval_workspace_navigate", navigate, control: control)).isError)
    #expect(control.store.selection == .batchRuns)
    #expect(control.production.pane == .workers)
    let intent = try await call("eval_intent_state", [:], control: control)
    #expect(!intent.isError)
    let revision = try #require(intent.structuredContent.objectValue?["intentRevision"])
    let failure = try await call(
      "eval_intent_build",
      [
        "operationID": .string(UUID().uuidString), "expectedIntentRevision": revision,
        "confirm": .bool(false),
      ], control: control)
    // Dispatch acknowledgement is followed by a failed durable receipt; no build was authorized.
    #expect(!failure.isError)
    let id = try #require(failure.structuredContent.objectValue?["operationID"])
    for _ in 0..<100 { await Task.yield() }
    let status = try await call("eval_operation_status", ["operationID": id], control: control)
    #expect(
      status.structuredContent.objectValue?["receipt"]?.objectValue?["phase"] == .string("failed"))
    #expect(!control.scenarios.projectTrusted)
  }
  @Test func fullConfigurationCannotManufactureDisclosureApproval() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var candidate = control.store.suite
    candidate.judgeConfiguration.externalEvidenceApprovedAt = Date()
    candidate.judgeConfiguration.approvedConnectionDigest = String(repeating: "a", count: 64)
    var fields = try workspace(control)
    fields["projectID"] = .string(control.store.selectedProjectID.uuidString)
    fields["suiteID"] = .string(control.store.selectedSuiteID.uuidString)
    fields["expectedRevision"] = .string(try control.store.currentSuiteRevision())
    fields["suiteJSON"] = .string(
      String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self))
    #expect(try await call("eval_suite_configure", fields, control: control).isError)
    #expect(control.store.suite.judgeConfiguration.externalEvidenceApprovedAt == nil)
  }
  @Test func completeDraftReplacementClearsStaleEditorErrors() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await call("eval_intent_state", [:], control: control)
    control.scenarios.invalidParameterDraftIndices = [0]
    control.scenarios.parameterArrayDraftTexts = [0: "[invalid"]
    let state = try await call("eval_intent_state", [:], control: control)
    let revision = try #require(state.structuredContent.objectValue?["intentRevision"])
    let text = String(decoding: try JSONEncoder().encode(control.scenarios.draft), as: UTF8.self)
    let output = try await call(
      "eval_intent_draft",
      [
        "operationID": .string(UUID().uuidString), "expectedIntentRevision": revision,
        "draftJSON": .string(text),
      ], control: control)
    #expect(!output.isError)
    #expect(control.scenarios.invalidParameterDraftIndices.isEmpty)
    #expect(control.scenarios.parameterArrayDraftTexts.isEmpty)
  }
  @Test func exportsUseRelativePathsThroughAliasesAndRejectSymlinks() async throws {
    let root = URL(fileURLWithPath: "/tmp/mcp-export-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = EvaluationAppControl(store: EvaluationStore(supportDirectory: root))
    let storage = try #require(control.production.storage)
    let source = root.appendingPathComponent("source.jsonl")
    try Data("{\"id\":\"one\",\"prompt\":\"original\",\"capturedOutput\":\"retained\"}\n".utf8)
      .write(to: source)
    let dataset = try storage.importDataset(from: source, name: "fixture", version: "1")
    let job = try storage.createCapturedJob(name: "fixture", datasetRevision: dataset.revision)
    let exported = try await call(
      "eval_production_export",
      [
        "operationID": .string(UUID().uuidString), "jobID": .string(job.id.uuidString),
        "expectedJobRevision": .string(job.revision),
      ], control: control)
    #expect(!exported.isError)
    let id = try #require(exported.structuredContent.objectValue?["exportID"])
    let listed = try await call("eval_production_export_list", ["exportID": id], control: control)
    let value = try #require(listed.structuredContent.objectValue?["files"])
    guard case .array(let files) = value else { throw MCPToolInputError.invalidArguments }
    #expect(files.contains(.string("report.json")))
    #expect(files.contains(.string("Dataset/manifest.json")))
    let read = try await call(
      "eval_production_export_read", ["exportID": id, "path": .string("report.json")],
      control: control)
    #expect(!read.isError)
    let encoded = try #require(read.structuredContent.objectValue?["dataBase64"]?.stringValue)
    let bytes = try #require(Data(base64Encoded: encoded))
    #expect(
      (try JSONDecoder().decode(MCPJSONValue.self, from: bytes)).objectValue?["completed"]
        == .integer(0))
    let directory = storage.root.appendingPathComponent("MCPExports/\(id.stringValue!)")
    let report = directory.appendingPathComponent("report.json")
    try FileManager.default.removeItem(at: report)
    try FileManager.default.createSymbolicLink(at: report, withDestinationURL: source)
    #expect(
      try await call("eval_production_export_list", ["exportID": id], control: control).isError)
    #expect(
      try await call(
        "eval_production_export_read", ["exportID": id, "path": .string("report.json")],
        control: control
      ).isError)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
    #expect(
      try await call("eval_production_export_list", ["exportID": id], control: control).isError)
    #expect(
      try await call(
        "eval_production_export_read", ["exportID": id, "path": .string("source.jsonl")],
        control: control
      ).isError)
  }
  @Test func largeResultIsDurableWithoutAnOversizedReceipt() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var fields = try workspace(control)
    fields["name"] = .string("large-result")
    #expect(!(try await call("eval_project_create", fields, control: control)).isError)
    let id = try #require(fields["operationID"])
    let uuid = try #require(UUID(uuidString: id.stringValue!))
    let payload = MCPToolPayload(
      structuredContent: .object(["report": .string(String(repeating: "a", count: 1_100_000))]))
    control.mcp.completeOperation(uuid, payload: payload)
    let status = try await call("eval_operation_status", ["operationID": id], control: control)
    #expect(
      status.structuredContent.objectValue?["receipt"]?.objectValue?["phase"]
        == .string("completed"))
    #expect(
      status.structuredContent.objectValue?["receipt"]?.objectValue?["content"]?.objectValue?[
        "resultFile"] == .bool(true))
    let data = try await call(
      "eval_operation_result_read", ["operationID": id, "bytes": .integer(100)], control: control)
    let encoded = try #require(data.structuredContent.objectValue?["dataBase64"]?.stringValue)
    #expect(
      Data(base64Encoded: encoded)
        == Data(try payload.structuredContent.jsonText().utf8).prefix(100))
    #expect(
      try await call(
        "eval_operation_result_read", ["operationID": id, "offset": .integer(8_388_608)],
        control: control
      ).isError)
  }
}
