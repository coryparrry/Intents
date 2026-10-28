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
  @Test(.timeLimit(.minutes(1))) func closingControlCancelsAndJoinsTrackedWorkBeforeReturning() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = try workspace(control)
    request["name"] = .string("Tracked operation")
    #expect(!(try await call("eval_project_create", request, control: control)).isError)
    let idValue = try #require(request["operationID"])
    let idText = try #require(idValue.stringValue)
    let id = try #require(UUID(uuidString: idText))
    let entered = AsyncStream<Void>.makeStream()
    var observedCancellation = false
    try control.mcp.track(id) {
      entered.continuation.yield(())
      entered.continuation.finish()
      do { try await Task.sleep(for: .seconds(60)) }
      catch { observedCancellation = true }
      return .failure(code: "cancelled", message: "Cancelled during shutdown.")
    }
    var enteredIterator = entered.stream.makeAsyncIterator()
    _ = await enteredIterator.next()
    await control.mcp.closeAndWait()
    #expect(observedCancellation)
    #expect(throws: EvaluationStoreError.self) {
      try control.mcp.track(UUID()) { .init(structuredContent: .object([:])) }
    }
    // Read the persisted terminal receipt through a fresh control instance.
    let restarted = EvaluationAppControl(store: EvaluationStore(supportDirectory: root))
    let status = try await call("eval_operation_status", ["operationID": idValue], control: restarted)
    #expect(status.structuredContent.objectValue?["receipt"]?.objectValue?["phase"] == .string("failed"))
  }
  @Test func resumeStartsClickedJobAfterSelectionChanges() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try #require(control.production.storage)
    let file = root.appendingPathComponent("input.jsonl")
    var bytes = try ProductionCodec.encode(ProductionExample(id: "a", prompt: "Input", capturedOutput: "Original")); bytes.append(10)
    try bytes.write(to: file)
    let dataset = try storage.importDataset(from: file, name: "Fixture", version: "v1")
    let a = try storage.createCapturedJob(name: "Clicked", datasetRevision: dataset.revision)
    let b = try storage.createCapturedJob(name: "Other", datasetRevision: dataset.revision)
    try storage.setControl(jobID: a.id, paused: true)
    control.production.jobs = [a,b]; control.production.selectedJobID = a.id
    let resume = control.production.resume(job: a, store: control.store, externalDisclosureApproved: false)
    // The async continuation has not started while the main actor changes selection.
    control.production.selectedJobID = b.id
    await resume.value
    let deadline = Date().addingTimeInterval(10)
    while control.production.runningJobID != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(control.production.error == nil && control.production.runningJobID == nil)
    #expect(try storage.report(jobID: a.id).completed == 1)
    #expect(try storage.report(jobID: b.id).completed == 0)
    #expect(control.production.selectedJobID == b.id)
  }
  @Test func baselineApprovalRequiresConfirmationAndExactEvidenceAndReplaysReceipt() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try #require(control.production.storage)
    let file = root.appendingPathComponent("input.jsonl")
    var bytes = try ProductionCodec.encode(ProductionExample(id: "a", prompt: "Input", capturedOutput: "Original")); bytes.append(10)
    try bytes.write(to: file)
    let dataset = try storage.importDataset(from: file, name: "Fixture", version: "v1")
    let job = try storage.createCapturedJob(name: "Baseline", datasetRevision: dataset.revision)
    let worker = ProductionWorker(id: "fixture", name: "Fixture", platform: "macOS", operatingSystem: "26", hardware: "Fixture", locale: "en_GB", model: "fixture")
    _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { try ProductionStorage.capturedResponse($0) }
    let record = try storage.record(jobID: job.id, slot: 0)
    try storage.appendReview(jobID: job.id, slot: 0, event: .init(requestID: record.response.requestID, reviewer: "Reviewer", outcome: .passed, note: "Inspected output"))
    let report = try storage.report(jobID: job.id)
    var request: [String:MCPJSONValue] = ["jobID": .string(job.id.uuidString), "expectedJobRevision": .string(job.revision),
      "expectedEvidenceRevision": .string(try #require(report.evidenceRevision)), "note": .string("Reviewed exact evidence"),
      "operationID": .string(UUID().uuidString), "confirm": .bool(false)]
    #expect(try await call("eval_production_baseline_approve", request, control: control).isError)
    request["confirm"] = .bool(true); request["operationID"] = .string(UUID().uuidString)
    let approved = try await call("eval_production_baseline_approve", request, control: control)
    #expect(!approved.isError)
    #expect(try storage.report(jobID: job.id).baselineApproval != nil)
    let replay = try await call("eval_production_baseline_approve", request, control: control)
    #expect(!replay.isError && replay.structuredContent.objectValue?["duplicate"] == .bool(true))
    request["operationID"] = .string(UUID().uuidString); request["expectedEvidenceRevision"] = .string(String(repeating: "0", count: 64))
    #expect(try await call("eval_production_baseline_approve", request, control: control).isError)
  }
  /// Rejects stale inspected consent without persisting a draft's changed destination or image-sharing policy.
  @Test(arguments: [false, true])
  func disclosureApprovalRejectsDivergentDraftWithoutMutation(changesConnection: Bool) async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = control.store
    let first = EvaluationJudgeConnection(id: UUID(), name: "A", kind: .localCompatible,
      baseURL: "http://127.0.0.1:1234", modelID: "fixture")
    let second = EvaluationJudgeConnection(id: UUID(), name: "B", kind: .localCompatible,
      baseURL: "http://127.0.0.1:1235", modelID: "fixture")
    try store.saveJudgeConnection(first, apiKey: nil)
    try store.saveJudgeConnection(second, apiKey: nil)
    store.draftSuite.scoringMode = .review
    store.draftSuite.judgeConfiguration.mode = .connection
    store.draftSuite.judgeConfiguration.connectionID = first.id
    store.draftSuite.judgeConfiguration.includeReferenceAttachments = false
    #expect(store.saveSuite())
    let canonical = store.suite
    var request = try workspace(control)
    request["projectID"] = .string(store.selectedProjectID.uuidString)
    request["suiteID"] = .string(store.selectedSuiteID.uuidString)
    request["expectedRevision"] = .string(store.suiteRevision)
    request["disclosureDigest"] = .string(first.disclosureDigest)
    request["confirm"] = .bool(true)
    if changesConnection { store.draftSuite.judgeConfiguration.connectionID = second.id }
    else { store.draftSuite.judgeConfiguration.includeReferenceAttachments = true }
    let draft = store.draftSuite
    #expect(draft != canonical)
    let result = try await call("eval_judge_disclosure_approve", request, control: control)
    #expect(result.isError)
    #expect(store.suite == canonical)
    #expect(store.draftSuite == draft)
    #expect(store.draftSuite.judgeConfiguration.externalEvidenceApprovedAt == nil)
    let reloaded = EvaluationStore(supportDirectory: root)
    #expect(reloaded.suite == canonical)
    await control.mcp.closeAndWait()
  }

  /// Commits the exact canonical approval when no draft content differs from the inspected revision.
  @Test func disclosureApprovalCommitsMatchingCanonicalPolicy() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = control.store
    let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
      baseURL: "http://127.0.0.1:1234", modelID: "fixture")
    try store.saveJudgeConnection(connection, apiKey: nil)
    store.draftSuite.scoringMode = .review
    store.draftSuite.judgeConfiguration.mode = .connection
    store.draftSuite.judgeConfiguration.connectionID = connection.id
    #expect(store.saveSuite())
    var request = try workspace(control)
    request["projectID"] = .string(store.selectedProjectID.uuidString)
    request["suiteID"] = .string(store.selectedSuiteID.uuidString)
    request["expectedRevision"] = .string(store.suiteRevision)
    request["disclosureDigest"] = .string(connection.disclosureDigest)
    request["confirm"] = .bool(true)
    #expect(!(try await call("eval_judge_disclosure_approve", request, control: control)).isError)
    #expect(store.suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
    #expect(store.draftSuite == store.suite)
    #expect(EvaluationStore(supportDirectory: root).suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
    await control.mcp.closeAndWait()
  }

  /// Rejects buffered prompt edits before approval without flushing them into canonical storage.
  @Test func disclosureApprovalRejectsBufferedPromptsBeforeSaving() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = control.store
    let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
      baseURL: "http://127.0.0.1:1234", modelID: "unused")
    try store.saveJudgeConnection(connection, apiKey: nil)
    store.draftSuite.scoringMode = .review
    store.draftSuite.judgeConfiguration.mode = .connection
    store.draftSuite.judgeConfiguration.connectionID = connection.id
    #expect(store.saveSuite())
    let canonical = store.suite
    store.editPrompt("Buffered edit", for: canonical.cases[0].id)
    #expect(throws: EvaluationStoreError.self) {
      try store.approveExternalJudgeDisclosure(expectedRevision: store.suiteRevision,
        disclosureDigest: connection.disclosureDigest)
    }
    #expect(store.suite == canonical)
    #expect(store.draftSuite.judgeConfiguration.externalEvidenceApprovedAt == nil)
    await store.closeAndWait()
    await control.mcp.closeAndWait()
  }

  /// Rolls back canonical disclosure approval when its catalog publication cannot be persisted.
  @Test func disclosureApprovalWriteFailureLeavesPolicyUnapproved() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mcp-approval-rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var rejectWrite = false
    let store = EvaluationStore(supportDirectory: root, workspaceCatalogWriter: { catalog, directory in
      if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
      try EvaluationWorkspacePersistence.save(catalog, in: directory)
    })
    let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
      baseURL: "http://127.0.0.1:1234", modelID: "unused")
    try store.saveJudgeConnection(connection, apiKey: nil)
    store.draftSuite.scoringMode = .review
    store.draftSuite.judgeConfiguration.mode = .connection
    store.draftSuite.judgeConfiguration.connectionID = connection.id
    #expect(store.saveSuite())
    let canonical = store.suite
    rejectWrite = true
    #expect(throws: EvaluationStoreError.self) {
      try store.approveExternalJudgeDisclosure(expectedRevision: store.suiteRevision,
        disclosureDigest: connection.disclosureDigest)
    }
    #expect(store.suite == canonical)
    #expect(store.draftSuite == canonical)
    #expect(EvaluationStore(supportDirectory: root).suite == canonical)
  }

  /// Freezes canonical dataset cases and execution configuration even while the UI has a different unsaved draft.
  @Test func productionSnapshotsBindTheInspectedCanonicalRevision() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = control.store
    store.draftSuite.scoringMode = .review
    store.draftSuite.instructions = "Canonical instructions"
    store.draftSuite.cases[0].prompt = "Canonical prompt"
    #expect(store.saveSuite())
    let canonical = store.suite
    store.draftSuite.instructions = "Pending instructions"
    store.draftSuite.cases[0].prompt = "Pending prompt"
    let target: [String: MCPJSONValue] = [
      "operationID": .string(UUID().uuidString),
      "projectID": .string(store.selectedProjectID.uuidString),
      "suiteID": .string(store.selectedSuiteID.uuidString),
      "expectedRevision": .string(store.suiteRevision),
    ]
    let snapshot = try await call("eval_production_dataset_snapshot", target, control: control)
    #expect(!snapshot.isError)
    let datasetValue = try #require(snapshot.structuredContent.objectValue?["dataset"])
    let dataset = try ProductionCodec.decode(ProductionDataset.self, Data(try datasetValue.jsonText().utf8))
    let storage = try #require(control.production.storage)
    let reader = try ProductionDatasetReader(storage: storage, revision: dataset.revision)
    #expect(try reader.example(at: 0).prompt == canonical.cases[0].prompt)
    let jobID = UUID()
    var creation = target
    creation["operationID"] = .string(UUID().uuidString)
    creation["jobID"] = .string(jobID.uuidString)
    creation["datasetRevision"] = .string(dataset.revision)
    creation["name"] = .string("Canonical batch")
    creation["kind"] = .string("native")
    #expect(!(try await call("eval_production_job_create", creation, control: control)).isError)
    let job = try storage.loadJob(jobID)
    let context = try ProductionCodec.decode(NativeProductionContext.self, job.configuration.executionContext)
    #expect(context.suite.instructions == canonical.instructions)
    #expect(store.draftSuite.instructions == "Pending instructions")
    #expect(store.suite == canonical)
    let nativeDraft = try store.productionSnapshot()
    #expect(nativeDraft.suite.instructions == "Pending instructions")
    await control.mcp.closeAndWait()
  }

  @Test func discoveryAndStrictSchemas() throws {
    let definitions = MCPToolCatalog.allDefinitions
    #expect(Set(definitions.map(\.name)).count == definitions.count)
    for name in [
      "eval_project_create", "eval_production_upload_begin", "eval_production_job_start",
      "eval_runner_trust",
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
  @Test func discoveredMutationSharesCanonicalReceiptAndAppState() async throws {
    let (control, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = try workspace(control)
    request["name"] = .string("discovered project")
    let envelope: [String: MCPJSONValue] = [
      "action": .string("eval_project_create"), "arguments": .object(request),
    ]
    let originalCount = control.store.projects.count
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(name: "eval_read_action", arguments: .object(envelope))
    }
    #expect(control.store.projects.count == originalCount)
    let first = try await call("eval_apply_action", envelope, control: control)
    #expect(!first.isError)
    #expect(control.store.projects.count == originalCount + 1)
    let retry = try await call("eval_project_create", request, control: control)
    #expect(!retry.isError)
    #expect(retry.structuredContent.objectValue?["duplicate"] == .bool(true))
    #expect(
      first.structuredContent.objectValue?["createdProjectID"]
        == retry.structuredContent.objectValue?["createdProjectID"])
    #expect(control.store.projects.count == originalCount + 1)
    request["name"] = .string("conflicting retry")
    #expect(
      try await call(
        "eval_apply_action",
        [
          "action": .string("eval_project_create"), "arguments": .object(request),
        ], control: control
      ).isError)
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
    navigate = try workspace(control)
    navigate["section"] = .string("appIntentTesting")
    #expect(!(try await call("eval_workspace_navigate", navigate, control: control)).isError)
    #expect(control.store.selection == .appIntentTesting)
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
