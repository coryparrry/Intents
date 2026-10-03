import Foundation

@MainActor enum MCPWorkspaceControl {
  static func revision(_ store: EvaluationStore) throws -> String {
    let value = MCPJSONValue.object([
      "projects": try .encode(store.projects),
      "selectedProjectID": .string(store.selectedProjectID.uuidString),
      "selectedSuiteID": .string(store.selectedSuiteID.uuidString),
      "suiteRevision": .string(try store.currentSuiteRevision()),
      "localState": try .encode(store.suiteLocalState),
      "judgeConnections": try .encode(store.judgeConnections),
    ])
    return ProductionCodec.digest(Data(try value.jsonText().utf8))
  }
  static func requireTarget(_ call: MCPControlCall, store: EvaluationStore) throws {
    if let project = try call.optionalID("projectID"), project != store.selectedProjectID {
      throw EvaluationStoreError.resourceConflict(
        "Select this project explicitly before changing its suites.")
    }
    if let suite = try call.optionalID("suiteID"), suite != store.selectedSuiteID {
      throw EvaluationStoreError.resourceConflict(
        "Select this suite explicitly before changing its definition or review state.")
    }
    if let expected = call.optionalText("expectedRevision"), expected != store.suiteRevision {
      throw EvaluationStoreError.resourceConflict(
        "Suite revision changed. Reread state and reconcile the intended action.")
    }
  }
  static func result(_ store: EvaluationStore, _ values: [String: MCPJSONValue] = [:]) throws
    -> MCPToolPayload
  {
    var values = values
    values["workspaceRevision"] = .string(try revision(store))
    values["revision"] = .string(try store.currentSuiteRevision())
    values["projectID"] = .string(store.selectedProjectID.uuidString)
    values["suiteID"] = .string(store.selectedSuiteID.uuidString)
    return MCPControlService.committed(values)
  }
  static func requireServerApproval(
    _ configuration: EvaluationJudgeConfiguration, store: EvaluationStore
  ) throws {
    let current = store.suite.judgeConfiguration
    guard configuration.externalEvidenceApprovedAt == current.externalEvidenceApprovedAt,
      configuration.approvedConnectionID == current.approvedConnectionID,
      configuration.approvedIncludeReferenceAttachments
        == current.approvedIncludeReferenceAttachments,
      configuration.approvedConnectionDigest == current.approvedConnectionDigest
    else {
      throw EvaluationStoreError.resourceConflict(
        "Disclosure approvals are server-owned. Use eval_judge_disclosure_approve with explicit operator confirmation."
      )
    }
  }
  static func execute(_ call: MCPControlCall, control: EvaluationAppControl) async throws
    -> MCPToolPayload
  {
    let store = control.store
    if call.name == "eval_review_patterns" {
      let patterns = EvaluationReviewWorkflow.patterns(
        samples: store.reviewSamples, state: store.suiteLocalState.review)
      return MCPControlService.read([
        "patterns": .array(
          patterns.prefix(100).map { pattern in
            .object([
              "tag": .string(pattern.tag), "caseCount": .integer(Int64(pattern.caseCount)),
              "sampleCount": .integer(Int64(pattern.samples.count)),
              "sampleIDs": .array(
                pattern.samples.prefix(100).map { .string($0.sample.id.uuidString) }),
            ])
          }), "count": .integer(Int64(patterns.count)),
      ])
    }
    if call.name == "eval_workspace_state" {
      return MCPControlService.read([
        "workspaceRevision": .string(try revision(store)),
        "projectID": .string(store.selectedProjectID.uuidString),
        "suiteID": .string(store.selectedSuiteID.uuidString),
        "projects": try .encode(store.projects), "suite": try .encode(store.suite),
        "revision": .string(store.suiteRevision),
        "localState": try .encode(store.suiteLocalState),
        "judgeConnections": try .encode(store.judgeConnections),
        "externalJudgeDisclosure": store.externalJudgeDisclosure.map(MCPJSONValue.string) ?? .null,
        "notice": store.notice.map(MCPJSONValue.string) ?? .null,
        "latestJudgeCheck": try .encode(store.latestJudgeCheck),
        "activeExecution": .bool(store.hasActiveExecution),
        "isReassessing": .bool(store.isReassessing),
        "model": .object([
          "available": .bool(store.modelStatus.isAvailable),
          "label": .string(store.modelStatus.label), "detail": .string(store.modelStatus.detail),
        ]),
      ])
    }
    guard try call.text("expectedWorkspaceRevision") == revision(store) else {
      throw EvaluationStoreError.resourceConflict(
        "Workspace changed. Reread its revision before changing it.")
    }
    if ![
      "eval_workspace_select", "eval_project_rename", "eval_project_duplicate",
      "eval_project_archive",
    ].contains(call.name) {
      try requireTarget(call, store: store)
    }
    switch call.name {
    case "eval_workspace_select":
      try store.switchWorkspace(projectID: call.id("projectID"), suiteID: call.id("suiteID"))
    case "eval_project_create":
      let id = try store.createProject(name: call.text("name"))
      return try result(store, ["createdProjectID": .string(id.uuidString)])
    case "eval_project_rename":
      try store.renameProject(id: call.id("projectID"), name: call.text("name"))
    case "eval_project_duplicate":
      let id = try store.duplicateProject(id: call.id("projectID"))
      return try result(store, ["createdProjectID": .string(id.uuidString)])
    case "eval_project_archive":
      try MCPControlService.confirm(call)
      try store.archiveProject(id: call.id("projectID"))
    case "eval_suite_create":
      let id = try store.createSuite(name: call.text("name"))
      return try result(store, ["createdSuiteID": .string(id.uuidString)])
    case "eval_suite_rename": try store.renameSuite(id: call.id("suiteID"), name: call.text("name"))
    case "eval_suite_duplicate":
      let id = try store.duplicateSuite(id: call.id("suiteID"))
      return try result(store, ["createdSuiteID": .string(id.uuidString)])
    case "eval_suite_archive":
      try MCPControlService.confirm(call)
      try store.archiveSuite(id: call.id("suiteID"))
    case "eval_suite_configure":
      let candidate = try call.value("suiteJSON", as: EvaluationSuite.self)
      try requireServerApproval(candidate.judgeConfiguration, store: store)
      guard candidate.id == store.selectedSuiteID,
        try JSONEncoder.sorted.encode(candidate.attachments)
          == JSONEncoder.sorted.encode(store.suite.attachments),
        (1...100).contains(candidate.cases.count), (1...5).contains(candidate.repetitions),
        candidate.cases.count * candidate.repetitions <= 100
      else {
        throw EvaluationStoreError.invalidSuite(
          "Preserve suite identity and uploaded attachments; interactive suites allow 100 planned responses. Use production batches for larger datasets."
        )
      }
      _ = try store.replaceSuite(
        candidate, expectedRevision: call.text("expectedRevision"),
        confirmDeletes: call.flag("confirmDeletes"))
    case "eval_suite_reset":
      try MCPControlService.confirm(call)
      try store.resetSuite()
    case "eval_clear_run_history":
      try MCPControlService.confirm(call)
      try store.clearRunHistory()
    case "eval_project_repository_link":
      try MCPControlService.confirm(call)
      try store.linkSelectedProject(toRepository: call.text("rootPath"))
    case "eval_run_save_retry":
      store.retryPendingRunSave()
      if store.hasUnsavedCompletedRun {
        throw EvaluationStoreError.persistence(store.notice ?? "Evidence save remains pending.")
      }
    case "eval_baseline_approve":
      try MCPControlService.confirm(call)
      try store.approveBaseline(
        runID: call.id("runID"), assessmentID: call.optionalID("assessmentID"),
        note: call.optionalText("note"))
    case "eval_experiment_create":
      let id = try store.createInstructionExperiment(
        name: call.text("name"), candidateInstructions: call.text("instructions"))
      return try result(store, ["experimentID": .string(id.uuidString)])
    case "eval_experiment_run":
      guard !store.hasActiveExecution, !store.isReassessing else {
        throw EvaluationStoreError.runBusy
      }
      store.notice = nil
      store.runExperiment(id: try call.id("experimentID"))
      if let notice = store.notice { throw EvaluationStoreError.invalidSuite(notice) }
    case "eval_experiment_decide":
      try MCPControlService.confirm(call)
      guard let decision = EvaluationExperimentDecision(rawValue: try call.text("decision")) else {
        throw MCPToolInputError.invalidArguments
      }
      try store.decideExperiment(id: call.id("experimentID"), decision: decision)
    case "eval_review_save":
      try MCPControlService.confirm(call, key: "confirmHumanReview")
      let annotation = try call.value("annotationJSON", as: EvaluationReviewAnnotation.self)
      guard !annotation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        annotation.note.utf8.count <= 4000,
        annotation.tags.count <= 6, annotation.tags.allSatisfy({ $0.count <= 60 })
      else { throw MCPToolInputError.invalidArguments }
      try store.saveReview(annotation)
    case "eval_review_decide_proposal":
      try MCPControlService.confirm(call)
      try store.decideReviewProposal(id: call.id("proposalID"), accept: call.flag("accept"))
    case "eval_review_promote":
      try MCPControlService.confirm(call)
      let id = try store.promoteReviewToCase(
        reviewID: call.id("reviewID"), expected: call.text("expected"))
      return try result(store, ["caseID": .string(id.uuidString)])
    case "eval_judge_check_add", "eval_judge_check_partition":
      guard let partition = EvaluationJudgeCheckPartition(rawValue: try call.text("partition"))
      else { throw MCPToolInputError.invalidArguments }
      if call.name == "eval_judge_check_add" {
        try store.addReviewToJudgeChecks(reviewID: call.id("reviewID"), partition: partition)
      } else {
        try store.setJudgeCheckPartition(exampleID: call.id("exampleID"), partition: partition)
      }
    case "eval_judge_checks_run":
      guard !store.hasActiveExecution, !store.isReassessing,
        store.judgeConnections.contains(where: { $0.id == (try? call.id("connectionID")) })
      else { throw EvaluationStoreError.runBusy }
      store.notice = nil
      store.runJudgeChecks(connectionID: try call.id("connectionID"))
      if let notice = store.notice { throw EvaluationStoreError.invalidSuite(notice) }
    case "eval_judge_connection_save":
      let connection = try call.value("connectionJSON", as: EvaluationJudgeConnection.self)
      try store.saveJudgeConnection(connection, apiKey: call.optionalText("apiKey"))
    case "eval_judge_connection_delete":
      try MCPControlService.confirm(call)
      try store.deleteJudgeConnection(id: call.id("connectionID"))
    case "eval_judge_connection_check":
      guard store.judgeConnections.contains(where: { $0.id == (try? call.id("connectionID")) })
      else { throw EvaluationStoreError.resourceNotFound("Judge connection") }
      let id = try call.id("connectionID")
      let checkedAt = store.judgeConnections.first(where: { $0.id == id })?.lastCheckedAt
      await store.checkJudgeConnection(id: id)
      guard store.judgeConnections.first(where: { $0.id == id })?.lastCheckedAt != checkedAt else {
        throw EvaluationStoreError.invalidSuite(store.notice ?? "Judge check failed.")
      }
    case "eval_judge_disclosure_approve":
      try MCPControlService.confirm(call)
      guard let connectionID = store.suite.judgeConfiguration.connectionID,
        let connection = store.judgeConnections.first(where: { $0.id == connectionID }),
        connection.disclosureDigest == (try call.text("disclosureDigest")),
        store.externalJudgeDisclosure != nil
      else {
        throw EvaluationStoreError.resourceConflict(
          "External judge disclosure changed. Inspect its current connection and digest before approval."
        )
      }
      store.approveExternalJudgeDisclosure()
      guard store.suite.judgeConfiguration.approvedConnectionDigest == connection.disclosureDigest
      else { throw EvaluationStoreError.persistence("Disclosure approval was not saved.") }
    case "eval_reassess_run":
      guard !store.hasActiveExecution, !store.isReassessing,
        store.run(with: try call.id("runID")) != nil,
        store.judgeConnections.contains(where: { $0.id == (try? call.id("connectionID")) })
      else { throw EvaluationStoreError.resourceNotFound("Run or judge connection") }
      store.notice = nil
      store.reassessRun(id: try call.id("runID"), connectionID: try call.id("connectionID"))
      if let notice = store.notice { throw EvaluationStoreError.invalidSuite(notice) }
    case "eval_assessment_select":
      try store.selectAssessment(runID: call.id("runID"), assessmentID: call.id("assessmentID"))
    case "eval_coreai_load":
      guard !store.hasActiveExecution, store.draftSuite.modelConfiguration.provider == .coreAI
      else {
        throw EvaluationStoreError.invalidSuite(
          "Choose Core AI and finish active execution before loading.")
      }
      await store.loadCoreAIModel()
      guard case .loaded = store.coreAIControlStatus else {
        throw EvaluationStoreError.invalidSuite("Core AI did not load. Inspect model readiness.")
      }
    case "eval_workspace_navigate":
      switch try call.text("section") {
      case "overview": store.selection = .overview
      case "intentLab": store.selection = .intentLab
      case "evaluations": store.selection = .evaluations
      case "traces": store.selection = .traces
      case "suite": store.selection = .suite
      case "run":
        let id = try call.id("runID")
        guard store.run(with: id) != nil else { throw MCPToolInputError.invalidArguments }
        store.selection = .run(id)
      case "batchRuns":
        store.selection = .batchRuns
        if let id = try call.optionalID("jobID") {
          guard let storage = control.production.storage else {
            throw MCPToolInputError.invalidArguments
          }
          _ = try storage.loadJob(id)
          control.production.select(id)
        }
        if let text = call.optionalText("pane"), let pane = ProductionPane(rawValue: text) {
          control.production.pane = pane
        }
      default: throw MCPToolInputError.invalidArguments
      }
    default: throw MCPToolInputError.unknownTool
    }
    if ["eval_experiment_run", "eval_judge_checks_run", "eval_reassess_run"].contains(call.name) {
      let id = try call.id("operationID")
      let projectID = store.selectedProjectID
      let suiteID = store.selectedSuiteID
      control.mcp.track(id) {
        while store.isRunning || store.isReassessing {
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard store.selectedProjectID == projectID, store.selectedSuiteID == suiteID else {
          return .failure(
            code: "needs_evidence",
            message: "Workspace changed before completion was captured. Inspect saved evidence.")
        }
        if let notice = store.notice { return .failure(code: "execution_failed", message: notice) }
        do {
          if call.name == "eval_judge_checks_run" {
            guard let report = store.latestJudgeCheck else {
              return .failure(code: "execution_failed", message: "No calibration report was saved.")
            }
            return MCPControlService.committed(["report": try .encode(report)])
          }
          return try result(store, ["localState": try .encode(store.suiteLocalState)])
        } catch { return MCPControlService.failure(error) }
      }
      return try result(
        store, ["operationID": .string(id.uuidString), "execution": .string("dispatched")])
    }
    return try result(store)
  }
}
