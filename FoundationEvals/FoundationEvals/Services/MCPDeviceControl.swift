import Foundation

@MainActor enum MCPDeviceControl {
  static func revision(_ lab: ScenarioCoordinator) throws -> String {
    let value = MCPJSONValue.object([
      "draft": try .encode(lab.draft), "configuration": try .encode(lab.configuration),
      "trusted": .bool(lab.projectTrusted), "backend": .string(lab.featureBackend.rawValue),
      "execution": lab.selectedExecutionID.map { .string($0.uuidString) } ?? .null,
      "collection": lab.selectedCollectionID.map { .string($0.uuidString) } ?? .null,
      "batch": lab.selectedBatchID.map { .string($0.uuidString) } ?? .null,
    ])
    return ProductionCodec.digest(Data(try value.jsonText().utf8))
  }
  static func encode<T: Encodable & Sendable>(_ value: T) throws -> MCPJSONValue {
    let result = try MCPJSONValue.encode(value)
    guard try result.jsonText().utf8.count <= 4_194_304 else {
      throw EvaluationStoreError.resourceConflict(
        "Response exceeds 4 MiB. Reduce its page or read an evidence export.")
    }
    return result
  }
  static func execute(
    _ call: MCPControlCall, control: EvaluationAppControl, service: MCPControlService
  ) async throws -> MCPToolPayload {
    if call.name.hasPrefix("eval_runner_") { return try runner(call, control: control) }
    let lab = control.scenarios
    if !lab.hasLoaded { await lab.load() }
    if call.name == "eval_intent_state" { return try state(call, lab: lab) }
    if call.name == "eval_intent_get" { return try get(call, lab: lab) }
    if call.name == "eval_intent_install_inspect" {
      return try MCPIntentInstallation.execute(call, control: control, service: service)
    }
    guard try call.text("expectedIntentRevision") == revision(lab) else {
      throw EvaluationStoreError.resourceConflict(
        "Intent Lab changed. Reread its revision before acting.")
    }
    if call.name == "eval_intent_cancel" {
      await lab.cancel()
      return try result(lab)
    }
    guard !lab.isRunning, !lab.isDiscoveringConnection, !lab.isVerifyingIntegration,
      !lab.isGeneratingSuggestions, service.deviceOperationID == nil
    else { throw EvaluationStoreError.runBusy }
    lab.notice = nil
    if call.name.hasPrefix("eval_intent_install_") {
      return try MCPIntentInstallation.execute(call, control: control, service: service)
    }
    switch call.name {
    case "eval_intent_select":
      let id = try call.id("id")
      switch try call.text("kind") {
      case "definition":
        guard
          lab.definitions.contains(where: {
            $0.id == id && $0.version == call.integer("version", default: 1)
          })
        else { throw MCPToolInputError.invalidArguments }
        await lab.selectSavedDefinition(id: id, version: call.integer("version", default: 1))
      case "execution":
        guard lab.executionRecords.contains(where: { $0.id == id }) else {
          throw MCPToolInputError.invalidArguments
        }
        lab.selectExecution(id)
      case "collection":
        guard lab.collections.contains(where: { $0.id == id }) else {
          throw MCPToolInputError.invalidArguments
        }
        lab.selectedCollectionID = id
      case "batch":
        guard lab.batchManifests.contains(where: { $0.id == id }) else {
          throw MCPToolInputError.invalidArguments
        }
        lab.selectedBatchID = id
      default: throw MCPToolInputError.invalidArguments
      }
    case "eval_intent_connect": try await connect(call, lab: lab, store: control.store)
    case "eval_intent_draft":
      var draft = try call.value("draftJSON", as: ScenarioDefinition.self)
      guard draft.id == lab.draft.id, draft.version == lab.draft.version,
        draft.target == lab.draft.target, draft.integration == lab.draft.integration
      else {
        throw EvaluationStoreError.resourceConflict(
          "Retain draft identity and selected integration/target. Use connection and new-version tools for those changes."
        )
      }
      draft.definitionDigest = ""
      draft.testContractDigest = nil
      lab.draft = draft
      lab.invalidParameterDraftIndices = []
      lab.parameterArrayDraftTexts = [:]
      lab.invalidatePreflight()
    case "eval_intent_new":
      if call.flag("duplicate") { lab.duplicateAsNewVersion() } else { lab.startStableCheck() }
    case "eval_intent_save":
      let frozen = try await lab.freezeAndSave()
      return try result(
        lab,
        ["definitionID": .string(frozen.id.uuidString), "version": .integer(Int64(frozen.version))])
    case "eval_intent_collection_save":
      let ids = try call.value("caseIDsJSON", as: [UUID].self)
      guard !ids.isEmpty, ids.count <= 1000 else { throw MCPToolInputError.invalidArguments }
      let collection: ScenarioCollection
      if call.flag("revise") {
        collection = try await lab.reviseSelectedCollection(caseIDs: ids)
      } else {
        collection = try await lab.createCollection(name: call.text("name"), caseIDs: ids)
      }
      return try result(lab, ["collectionID": .string(collection.id.uuidString)])
    case "eval_intent_variation_approve":
      try MCPControlService.confirm(call)
      _ = try await lab.addApprovedVariation(
        call.value("approvalJSON", as: ScenarioApprovedVariation.self))
    case "eval_intent_suggestion_approve":
      try MCPControlService.confirm(call)
      let id = try call.id("suggestionID")
      guard lab.suggestions.contains(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      lab.approveSuggestion(id: id)
    case "eval_intent_quarantine_clear":
      try MCPControlService.confirm(call)
      guard call.flag("fixtureReadinessProven") else {
        throw MCPToolInputError.confirmationRequired
      }
      await lab.clearDeviceQuarantine(fixtureReadinessProven: true)
    default:
      let expected = try revision(lab)
      return try service.dispatch(call) {
        guard try revision(lab) == expected else {
          throw EvaluationStoreError.resourceConflict(
            "Intent Lab changed before dispatch. Inspect its current state.")
        }
        return try await longOperation(call, lab: lab, control: control)
      }
    }
    if let notice = lab.notice { throw EvaluationStoreError.invalidSuite(notice) }
    return try result(lab)
  }
  private static func result(_ lab: ScenarioCoordinator, _ values: [String: MCPJSONValue] = [:])
    throws -> MCPToolPayload
  {
    var values = values
    values["intentRevision"] = .string(try revision(lab))
    values["notice"] = lab.notice.map(MCPJSONValue.string) ?? .null
    return MCPControlService.committed(values)
  }
  private static func state(_ call: MCPControlCall, lab: ScenarioCoordinator) throws
    -> MCPToolPayload
  {
    let offset = call.integer("offset")
    let limit = call.integer("limit", default: 20)
    func page<T>(_ values: [T]) -> [T] { Array(values.dropFirst(offset).prefix(limit)) }
    return MCPControlService.read([
      "intentRevision": .string(try revision(lab)), "draft": try encode(lab.draft),
      "configuration": try encode(lab.configuration), "projectTrusted": .bool(lab.projectTrusted),
      "backend": .string(lab.featureBackend.rawValue),
      "discovery": try encode(lab.connectionDiscovery),
      "devices": try encode(lab.discoveredDevices),
      "declarations": try encode(lab.declarationCatalog), "preflight": try encode(lab.preflight),
      "readiness": try encode(lab.routeReadiness),
      "validation": try encode(lab.currentValidationIssues), "running": .bool(lab.isRunning),
      "stage": lab.executionStage.map(MCPJSONValue.string) ?? .null,
      "notice": lab.notice.map(MCPJSONValue.string) ?? .null,
      "definitions": try encode(page(lab.definitions)),
      "executions": try encode(page(lab.executionRecords)), "runs": try encode(page(lab.runs)),
      "collections": try encode(page(lab.collections)),
      "batches": try encode(page(lab.batchResults)),
      "suggestions": try encode(page(lab.suggestions)),
      "recovery": try encode(page(lab.recoveryJournals)),
      "pendingSaves": try encode(page(lab.pendingOrdinarySaves)),
    ])
  }
  private static func get(_ call: MCPControlCall, lab: ScenarioCoordinator) throws -> MCPToolPayload
  {
    let id = try call.id("id")
    let value: MCPJSONValue
    switch try call.text("kind") {
    case "definition":
      guard
        let item = lab.definitions.first(where: {
          $0.id == id && $0.version == call.integer("version", default: 1)
        })
      else { throw MCPToolInputError.invalidArguments }
      value = try encode(item)
    case "run":
      guard let item = lab.runs.first(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      value = try encode(item)
    case "execution":
      guard let item = lab.executionRecords.first(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      value = try encode(item)
    case "collection":
      guard let item = lab.collections.first(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      value = try encode(item)
    case "batch":
      guard let item = lab.batchResults.first(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      value = try encode(item)
    default: throw MCPToolInputError.invalidArguments
    }
    return MCPControlService.read(["value": value])
  }
  private static func connect(
    _ call: MCPControlCall, lab: ScenarioCoordinator, store: EvaluationStore
  ) async throws {
    switch try call.text("action") {
    case "project":
      let file = URL(filePath: try call.text("value"))
      guard FileManager.default.fileExists(atPath: file.path),
        ["xcodeproj", "xcworkspace"].contains(file.pathExtension)
      else { throw MCPToolInputError.invalidArguments }
      lab.selectContainer(file)
    case "scheme":
      let value = try call.text("value")
      guard lab.connectionDiscovery?.schemes.contains(value) == true else {
        throw MCPToolInputError.invalidArguments
      }
      lab.selectScheme(value)
    case "configuration": lab.selectBuildConfiguration(try call.text("value"))
    case "team": lab.selectDevelopmentTeam(try call.text("value"))
    case "provisioning":
      guard call.arguments.objectValue?["enabled"] != nil else {
        throw MCPToolInputError.invalidArguments
      }
      lab.setAllowsProvisioningUpdates(call.flag("enabled"))
    case "application":
      guard
        let product = lab.connectionDiscovery?.applications.first(where: {
          $0.id == call.optionalText("value")
        })
      else { throw MCPToolInputError.invalidArguments }
      lab.selectApplication(product)
    case "testBundle":
      guard
        let product = lab.connectionDiscovery?.uiTestBundles.first(where: {
          $0.id == call.optionalText("value")
        })
      else { throw MCPToolInputError.invalidArguments }
      lab.selectUITestBundle(product)
    case "device":
      let id = try call.text("value")
      guard lab.discoveredDevices.contains(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      await lab.selectDevice(id)
    case "backend":
      guard let backend = ScenarioFeatureBackend(rawValue: try call.text("value")) else {
        throw MCPToolInputError.invalidArguments
      }
      lab.featureBackend = backend
      lab.invalidatePreflight()
    case "assignProject":
      let id = try call.id("projectID")
      guard store.projects.contains(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      lab.assignProject(id: id)
    default: throw MCPToolInputError.invalidArguments
    }
  }
  private static func longOperation(
    _ call: MCPControlCall, lab: ScenarioCoordinator, control: EvaluationAppControl
  ) async throws -> MCPToolPayload {
    lab.notice = nil
    switch call.name {
    case "eval_intent_refresh":
      if try call.text("kind") == "devices" {
        await lab.refreshDevices()
      } else {
        await lab.refreshPreflight()
      }
    case "eval_intent_build":
      try MCPControlService.confirm(call)
      await lab.approveBuildAndDiscover()
      guard lab.connectionDiscovery != nil else {
        throw EvaluationStoreError.invalidSuite(lab.notice ?? "Project discovery failed.")
      }
    case "eval_intent_verify":
      await lab.verifyInstalledIntegration()
      guard lab.verifiedIntegrationSummary != nil else {
        throw EvaluationStoreError.invalidSuite(lab.notice ?? "Integration verification failed.")
      }
    case "eval_intent_run":
      let executions = Set(lab.executionRecords.map(\.id))
      let runs = Set(lab.runs.map(\.id))
      let batches = Set(lab.batchResults.map(\.id))
      switch try call.text("mode") {
      case "current": await lab.run()
      case "diagnostic":
        let lanes = try call.value("lanesJSON", as: Set<ScenarioLane>.self)
        await lab.checkThisFix(on: lanes)
      case "execution":
        guard await lab.rerunSelectedExecution() != nil else {
          throw EvaluationStoreError.invalidSuite(lab.notice ?? "Rerun failed.")
        }
      case "collection":
        guard await lab.runSelectedCollection() != nil else {
          throw EvaluationStoreError.invalidSuite(lab.notice ?? "Collection run failed.")
        }
      case "failedBatch":
        guard await lab.rerunFailedSelectedBatch() != nil else {
          throw EvaluationStoreError.invalidSuite(lab.notice ?? "Batch rerun failed.")
        }
      default: throw MCPToolInputError.invalidArguments
      }
      let newExecutions = lab.executionRecords.map(\.id).filter { !executions.contains($0) }
      let newRuns = lab.runs.map(\.id).filter { !runs.contains($0) }
      let newBatches = lab.batchResults.map(\.id).filter { !batches.contains($0) }
      guard !newExecutions.isEmpty || !newRuns.isEmpty || !newBatches.isEmpty else {
        throw EvaluationStoreError.invalidSuite(
          lab.notice ?? "No new execution evidence was saved. Inspect readiness and recovery state."
        )
      }
      return try result(
        lab,
        [
          "executionIDs": try encode(newExecutions), "runIDs": try encode(newRuns),
          "batchIDs": try encode(newBatches),
        ])
    case "eval_intent_suggest":
      await lab.generateSuggestions()
      if let notice = lab.notice { throw EvaluationStoreError.invalidSuite(notice) }
      return try result(lab, ["suggestions": try encode(lab.suggestions)])
    case "eval_intent_assess":
      let coordinate = try call.id("coordinateID")
      let assertion = try call.id("assertionID")
      if call.optionalText("judgeJSON") != nil {
        try MCPWorkspaceControl.requireServerApproval(
          call.value("judgeJSON", as: EvaluationJudgeConfiguration.self), store: control.store)
      }
      switch try call.text("action") {
      case "freeze":
        guard
          await lab.freezeSelectedSemanticPolicy(
            coordinateID: coordinate, assertionID: assertion,
            judgeConfiguration: try call.value("judgeJSON", as: EvaluationJudgeConfiguration.self))
        else { throw EvaluationStoreError.invalidSuite(lab.notice ?? "Policy freeze failed.") }
      case "reassess":
        guard
          let assessment = await lab.reassessSelectedCoordinate(
            coordinateID: coordinate, assertionID: assertion,
            judgeConfiguration: try call.value("judgeJSON", as: EvaluationJudgeConfiguration.self))
        else { throw EvaluationStoreError.invalidSuite(lab.notice ?? "Reassessment failed.") }
        return try result(lab, ["assessment": try encode(assessment)])
      case "select":
        guard
          await lab.selectAssessment(
            try call.id("assessmentID"), coordinateID: coordinate, assertionID: assertion)
        else {
          throw EvaluationStoreError.invalidSuite(lab.notice ?? "Assessment selection failed.")
        }
      default: throw MCPToolInputError.invalidArguments
      }
    case "eval_intent_recover":
      switch try call.text("kind") {
      case "ordinary":
        guard await lab.retryPendingOrdinarySave(invocationID: try call.id("id")) != nil else {
          throw MCPToolInputError.invalidArguments
        }
      case "feature":
        guard await lab.retryPendingFeatureSave(planID: try call.id("id")) != nil else {
          throw MCPToolInputError.invalidArguments
        }
      case "native":
        guard
          await lab.retryPendingNativeSave(
            planID: try call.id("id"), coordinateID: try call.id("coordinateID")) != nil
        else { throw MCPToolInputError.invalidArguments }
      case "assessment":
        guard await lab.retryAssessmentSelectionSave() else {
          throw EvaluationStoreError.invalidSuite(
            lab.notice ?? "Assessment selection recovery failed.")
        }
      default: throw MCPToolInputError.invalidArguments
      }
    case "eval_intent_export":
      guard let storage = control.production.storage else {
        throw MCPToolInputError.invalidArguments
      }
      let id = try call.id("operationID")
      let root = storage.root.appendingPathComponent("MCPExports")
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count
          < 100
      else { throw MCPToolInputError.invalidArguments }
      let destination = root.appendingPathComponent(id.uuidString)
      if try call.text("kind") == "batch" {
        try await lab.exportSelectedBatch(to: destination)
      } else {
        try await lab.exportSelectedExecution(to: destination)
      }
      return try result(lab, ["exportID": .string(id.uuidString)])
    default: throw MCPToolInputError.unknownTool
    }
    return try result(lab)
  }
  private static func runner(_ call: MCPControlCall, control: EvaluationAppControl) throws
    -> MCPToolPayload
  {
    let runners = control.runners
    switch call.name {
    case "eval_runner_state":
      return MCPControlService.read([
        "runners": try encode(runners.runners),
        "runs": try encode(Array(runners.activeRuns.values)),
        "selectedRunnerID": runners.selectedRunnerID.map { .string($0.uuidString) } ?? .null,
        "selectedFeatureID": runners.selectedFeatureID.map(MCPJSONValue.string) ?? .null,
        "browsing": .bool(runners.isBrowsing),
        "error": runners.lastError.map(MCPJSONValue.string) ?? .null,
      ])
    case "eval_runner_select":
      let id = try call.id("runnerID")
      guard let runner = runners.runners.first(where: { $0.id == id }) else {
        throw MCPToolInputError.invalidArguments
      }
      if let feature = call.optionalText("featureID") {
        guard runner.features.contains(where: { $0.id == feature }) else {
          throw MCPToolInputError.invalidArguments
        }
        runners.selectedFeatureID = feature
      }
      runners.selectedRunnerID = id
    case "eval_runner_discovery":
      if call.flag("enabled") { runners.start() } else { runners.stop() }
    case "eval_runner_pair":
      if call.flag("cancel") {
        runners.cancelPairing(with: try call.id("runnerID"))
      } else {
        try runners.beginPairing(with: call.id("runnerID"))
      }
    case "eval_runner_trust":
      try MCPControlService.confirm(call, key: "confirmCodeCompared")
      try runners.trustRunner(call.id("runnerID"), pairingCode: call.text("pairingCode"))
    case "eval_runner_disconnect":
      if call.flag("forgetTrust") {
        try MCPControlService.confirm(call)
        try runners.forgetTrust(for: call.id("runnerID"))
      } else {
        runners.disconnect(try call.id("runnerID"))
      }
    case "eval_runner_run":
      try MCPWorkspaceControl.requireTarget(call, store: control.store)
      let id = try runners.runSelectedSuite(
        on: call.id("runnerID"), featureID: call.text("featureID"),
        timeout: .seconds(call.number("timeoutSeconds", default: 120)))
      let operation = try call.id("operationID")
      control.mcp.track(operation) {
        while let status = runners.status(for: id),
          [.preparing, .dispatching, .running].contains(status.phase)
        { try? await Task.sleep(for: .milliseconds(100)) }
        guard let status = runners.status(for: id) else {
          return .failure(
            code: "needs_evidence",
            message: "Runner status unavailable. Inspect saved run evidence.")
        }
        do {
          return .init(
            structuredContent: .object([
              "runID": .string(id.uuidString), "status": try encode(status),
            ]), isError: status.phase != .completed && status.phase != .cancelled)
        } catch { return MCPControlService.failure(error) }
      }
      return MCPControlService.committed([
        "runID": .string(id.uuidString), "operationID": .string(operation.uuidString),
        "execution": .string("dispatched"),
      ])
    case "eval_runner_cancel":
      let id = try call.id("runID")
      guard runners.status(for: id) != nil else { throw MCPToolInputError.invalidArguments }
      runners.cancelRun(id)
    default: throw MCPToolInputError.unknownTool
    }
    return MCPControlService.committed()
  }
}
