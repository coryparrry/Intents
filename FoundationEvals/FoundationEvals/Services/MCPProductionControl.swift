import Foundation

@MainActor enum MCPProductionControl {
  static func json<T: Encodable>(_ value: T) throws -> MCPJSONValue {
    let bytes = try ProductionCodec.encode(value)
    guard bytes.count <= 4_194_304 else {
      throw ProductionFailure.invalid(
        "Response exceeds 4 MiB. Reduce page size or read the evidence export in chunks.")
    }
    return try JSONDecoder().decode(MCPJSONValue.self, from: bytes)
  }
  static func stripped(_ job: ProductionJob) -> ProductionJob {
    var copy = job
    copy.configuration.executionContext = Data()
    return copy
  }
  static func execute(_ call: MCPControlCall, control: EvaluationAppControl) async throws
    -> MCPToolPayload
  {
    guard let storage = control.production.storage else {
      throw ProductionFailure.unavailable("Production storage is unavailable.")
    }
    let mutating =
      MCPControlTools.definitions.first(where: { $0.name == call.name })?.annotations.readOnlyHint
      == false
    let values: [String: MCPJSONValue] = try await Task.detached(priority: .utility) {
      try readOrPersist(call, storage: storage)
    }.value
    if values["delegate"] == .bool(true) {
      switch call.name {
      case "eval_production_dataset_snapshot":
        try MCPWorkspaceControl.requireTarget(call, store: control.store)
        let suite = control.store.draftSuite
        let dataset = try await Task.detached(priority: .utility) {
          let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-dataset-\(UUID()).jsonl")
          defer { try? FileManager.default.removeItem(at: file) }
          var bytes = Data()
          for example in suite.cases {
            let value = ProductionExample(
              id: example.id.uuidString, prompt: example.prompt, expected: example.expected,
              metadata: ["task": example.name], input: try ProductionCodec.encode(example))
            bytes.append(try ProductionCodec.encode(value))
            bytes.append(10)
          }
          try bytes.write(to: file)
          return try storage.importDataset(from: file, name: suite.name, version: suite.version)
        }.value
        await control.production.refresh()
        return MCPControlService.committed(["dataset": try json(dataset)])
      case "eval_production_job_create":
        try MCPWorkspaceControl.requireTarget(call, store: control.store)
        let id = try call.id("jobID")
        let name = try call.text("name")
        let revision = try call.text("datasetRevision")
        let job: ProductionJob
        if try call.text("kind") == "captured" {
          guard call.optionalText("optionsJSON") == nil else {
            throw MCPToolInputError.invalidArguments
          }
          job = try await Task.detached(priority: .utility) {
            try storage.createCapturedJob(name: name, datasetRevision: revision, id: id)
          }.value
        } else {
          var config = try control.production.nativeConfiguration(store: control.store)
          if let options = call.optionalText("optionsJSON") {
            config = try optionsConfiguration(options, base: config)
          }
          let frozen = config
          job = try await Task.detached(priority: .utility) {
            try storage.createJob(
              name: name, datasetRevision: revision, configuration: frozen, id: id)
          }.value
        }
        control.production.select(job.id)
        await control.production.refresh()
        return MCPControlService.committed([
          "jobID": .string(job.id.uuidString), "jobRevision": .string(job.revision),
        ])
      case "eval_production_job_start":
        let job = try storage.loadJob(call.id("jobID"))
        try expected(call, job: job)
        try control.production.start(
          job: job, store: control.store,
          externalDisclosureApproved: call.flag("externalDisclosureApproved"))
        control.production.select(job.id)
        let operation = try call.id("operationID")
        control.mcp.track(operation) {
          while control.production.runningJobID == job.id {
            try? await Task.sleep(for: .milliseconds(100))
          }
          if let error = control.production.executionErrors[job.id] {
            return .failure(code: "execution_failed", message: error)
          }
          do {
            let report = try await Task.detached(priority: .utility) {
              try storage.report(jobID: job.id)
            }.value
            return MCPControlService.committed([
              "jobID": .string(job.id.uuidString), "phase": .string(report.phase),
              "completed": .integer(Int64(report.completed)),
              "planned": .integer(Int64(report.planned)),
              "gateExitCode": .integer(Int64(report.exitCode)),
            ])
          } catch { return MCPControlService.failure(error) }
        }
        return MCPControlService.committed([
          "jobID": .string(job.id.uuidString), "operationID": .string(operation.uuidString),
          "execution": .string("dispatched"),
        ])
      default: throw MCPToolInputError.unknownTool
      }
    }
    if mutating { await control.production.refresh() }
    if call.name == "eval_production_job_control", call.flag("paused") || call.flag("cancelled") {
      control.production.interrupt(jobID: try call.id("jobID"))
    }
    var output = values
    if call.name == "eval_production_job_get" {
      let id = try call.id("jobID")
      output["runningOnThisMac"] = .bool(control.production.runningJobID == id)
      output["executionError"] =
        control.production.executionErrors[id].map(MCPJSONValue.string) ?? .null
    }
    return mutating ? MCPControlService.committed(output) : MCPControlService.read(output)
  }
  nonisolated private static func expected(_ call: MCPControlCall, job: ProductionJob) throws {
    guard try call.text("expectedJobRevision") == job.revision else {
      throw ProductionFailure.invalid("Frozen job revision changed. Reread its identity.")
    }
  }
  nonisolated private static func optionsConfiguration(
    _ text: String, base: ProductionJobConfiguration
  ) throws -> ProductionJobConfiguration {
    guard let options = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw MCPToolInputError.invalidArguments }
    let allowed = Set([
      "repetitions", "chunkSize", "maximumAttempts", "timeoutSeconds", "maximumElapsedSeconds",
      "maximumCost", "maximumCostPerAttempt", "targets", "gate", "baselineJobID",
    ])
    guard Set(options.keys).isSubset(of: allowed) else { throw MCPToolInputError.invalidArguments }
    var native =
      try JSONSerialization.jsonObject(with: ProductionCodec.encode(base)) as! [String: Any]
    for (key, value) in options { native[key] = value }
    return try ProductionCodec.decode(
      ProductionJobConfiguration.self, JSONSerialization.data(withJSONObject: native))
  }
  nonisolated private static func readOrPersist(_ call: MCPControlCall, storage: ProductionStorage)
    throws -> [String: MCPJSONValue]
  {
    func encode<T: Encodable>(_ value: T) throws -> MCPJSONValue {
      let bytes = try ProductionCodec.encode(value)
      guard bytes.count <= 4_194_304 else {
        throw ProductionFailure.invalid(
          "Response exceeds 4 MiB. Reduce page size or use chunked exports.")
      }
      return try JSONDecoder().decode(MCPJSONValue.self, from: bytes)
    }
    func stripped(_ job: ProductionJob) -> ProductionJob {
      var copy = job
      copy.configuration.executionContext = Data()
      return copy
    }
    func job() throws -> ProductionJob {
      let value = try storage.loadJob(call.id("jobID"))
      try expected(call, job: value)
      return value
    }
    let offset = call.integer("offset")
    let limit = call.integer("limit", default: 50)
    switch call.name {
    case "eval_production_state":
      let datasets = try storage.datasets()
      let jobs = try storage.jobs()
      let workers = try storage.workers()
      let schedules = try storage.schedules()
      func page<T>(_ values: [T]) -> [T] { Array(values.dropFirst(offset).prefix(limit)) }
      return [
        "datasets": try encode(page(datasets)), "jobs": try encode(page(jobs).map(stripped)),
        "workers": try encode(page(workers)), "schedules": try encode(page(schedules)),
        "scheduleRevisions": .object(
          try Dictionary(
            uniqueKeysWithValues: page(schedules).map {
              (
                $0.id.uuidString,
                MCPJSONValue.string(try ProductionCodec.digest(ProductionCodec.encode($0)))
              )
            })),
        "counts": .object([
          "datasets": .integer(Int64(datasets.count)), "jobs": .integer(Int64(jobs.count)),
          "workers": .integer(Int64(workers.count)), "schedules": .integer(Int64(schedules.count)),
        ]),
      ]
    case "eval_production_upload_begin":
      let upload = ProductionUpload(
        id: try call.id("uploadID"), name: try call.text("name"), version: try call.text("version"),
        sampling: ProductionSampling(rawValue: call.optionalText("sampling") ?? "curated")!,
        productionData: call.flag("productionData"), expectedChunks: call.integer("chunks"),
        expectedBytes: call.integer("bytes"), expectedDigest: try call.text("sha256"))
      return ["upload": try encode(storage.beginUpload(upload))]
    case "eval_production_upload_chunk":
      guard let bytes = Data(base64Encoded: try call.text("dataBase64")) else {
        throw MCPToolInputError.invalidArguments
      }
      let id = try call.id("uploadID")
      try storage.appendUpload(id, index: call.integer("index"), data: bytes)
      return ["uploadID": .string(id.uuidString), "index": .integer(Int64(call.integer("index")))]
    case "eval_production_upload_status":
      let id = try call.id("uploadID")
      return [
        "upload": try encode(storage.upload(id)),
        "receivedChunks": try encode(storage.uploadStatus(id)),
      ]
    case "eval_production_upload_preview":
      let id = try call.id("uploadID")
      return [
        "examples": try encode(storage.previewUpload(id)),
        "previewDigest": .string(try storage.upload(id).expectedDigest),
      ]
    case "eval_production_upload_finish":
      return [
        "dataset": try encode(
          storage.finishUpload(
            call.id("uploadID"), previewDigest: call.text("previewDigest"),
            redactionConfirmed: call.flag("redactionConfirmed")))
      ]
    case "eval_production_upload_discard":
      try MCPControlService.confirm(call)
      try storage.discardUpload(call.id("uploadID"))
      return [:]
    case "eval_production_dataset_get":
      let reader = try ProductionDatasetReader(storage: storage, revision: call.text("revision"))
      var examples: [ProductionExample] = []
      for position
        in offset..<min(
          offset + call.integer("limit", default: 3), max(offset, reader.dataset.count))
      { examples.append(try reader.example(at: position)) }
      return ["dataset": try encode(reader.dataset), "examples": try encode(examples)]
    case "eval_production_dataset_snapshot", "eval_production_job_create",
      "eval_production_job_start":
      return ["delegate": .bool(true)]
    case "eval_production_job_clone":
      let source = try job()
      let clone = try storage.createJob(
        name: call.text("name"), datasetRevision: source.datasetRevision,
        configuration: source.configuration, id: call.id("newJobID"))
      return ["jobID": .string(clone.id.uuidString), "jobRevision": .string(clone.revision)]
    case "eval_production_job_control":
      let value = try job()
      guard
        call.arguments.objectValue?["paused"] != nil
          || call.arguments.objectValue?["cancelled"] != nil
      else { throw MCPToolInputError.invalidArguments }
      try storage.setControl(
        jobID: value.id,
        paused: call.arguments.objectValue?["paused"].map { _ in call.flag("paused") },
        cancelled: call.arguments.objectValue?["cancelled"].map { _ in call.flag("cancelled") },
        expectedControlRevision: call.text("expectedControlRevision"))
      return ["jobID": .string(value.id.uuidString)]
    case "eval_production_job_get":
      let value = try storage.loadJob(call.id("jobID"))
      var report = try storage.report(jobID: value.id)
      report.job = stripped(report.job)
      let currentControl = try storage.control(value)
      return [
        "job": try encode(stripped(value)),
        "contextBytes": .integer(Int64(value.configuration.executionContext.count)),
        "control": try encode(currentControl),
        "controlRevision": .string(ProductionStorage.controlRevision(currentControl)),
        "report": try encode(report),
      ]
    case "eval_production_context_read":
      let value = try storage.loadJob(call.id("jobID"))
      return try dataChunk(value.configuration.executionContext, call: call)
    case "eval_production_results":
      var records = try storage.records(jobID: call.id("jobID"), offset: offset, limit: limit)
      for i in records.indices {
        records[i].response.output = String(records[i].response.output.prefix(500))
        records[i].response.explanation = records[i].response.explanation.map {
          String($0.prefix(500))
        }
        records[i].response.artifact = nil
      }
      return [
        "records": try encode(records), "offset": .integer(Int64(offset)),
        "count": .integer(Int64(records.count)), "summaries": .bool(true),
      ]
    case "eval_production_result_get":
      let value = try storage.loadJob(call.id("jobID"))
      let slot = call.integer("slot")
      let record = try storage.record(jobID: value.id, slot: slot)
      let reader = try ProductionDatasetReader(storage: storage, revision: value.datasetRevision)
      return [
        "record": try encode(record),
        "example": try encode(
          reader.example(
            at: slot / (value.configuration.repetitions * value.configuration.targets.count))),
        "review": try encode(storage.review(jobID: value.id, requestID: record.response.requestID)),
      ]
    case "eval_production_review_append":
      guard call.flag("confirmHumanReview") else { throw MCPToolInputError.confirmationRequired }
      let value = try job()
      let event = try ProductionCodec.decode(
        ProductionReviewEvent.self, Data(call.text("eventJSON").utf8))
      try storage.appendReview(jobID: value.id, slot: call.integer("slot"), event: event)
      return ["eventID": .string(event.id.uuidString)]
    case "eval_production_schedule_save":
      guard call.flag("confirm") else { throw MCPToolInputError.confirmationRequired }
      let schedule = try ProductionCodec.decode(
        ProductionSchedule.self, Data(call.text("scheduleJSON").utf8))
      try storage.saveSchedule(schedule, expectedRevision: call.text("expectedScheduleRevision"))
      return ["scheduleID": .string(schedule.id.uuidString)]
    case "eval_production_schedule_tick":
      return ["createdJobIDs": try encode(storage.tickSchedules())]
    case "eval_production_export":
      let value = try job()
      let id = try call.id("operationID")
      let folder = storage.root.appendingPathComponent("MCPExports")
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
          .count < 100
      else {
        throw ProductionFailure.invalid(
          "Export retention limit reached; preserve exports before operator cleanup.")
      }
      try storage.exportJob(value.id, to: folder.appendingPathComponent(id.uuidString))
      return ["exportID": .string(id.uuidString)]
    case "eval_production_export_list":
      let root = try exportRoot(storage: storage, id: call.id("exportID"))
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles])
      else { throw ProductionFailure.invalid("Export missing.") }
      var paths: [String] = []
      for case let url as URL in enumerator {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true else {
          throw ProductionFailure.integrity("Export contains a symlink.")
        }
        if info.isRegularFile == true {
          let components = url.standardizedFileURL.pathComponents
          let prefix = root.pathComponents
          guard components.starts(with: prefix), components.count > prefix.count else {
            throw ProductionFailure.integrity("Export file escaped its directory.")
          }
          paths.append(components.dropFirst(prefix.count).joined(separator: "/"))
        }
      }
      paths.sort()
      return [
        "files": try encode(Array(paths.dropFirst(offset).prefix(limit))),
        "count": .integer(Int64(paths.count)),
      ]
    case "eval_production_export_read":
      let path = try call.text("path")
      let root = try exportRoot(storage: storage, id: call.id("exportID"))
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
      guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw MCPToolInputError.invalidArguments
      }
      var file = root
      for component in components {
        file.appendPathComponent(String(component))
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
          throw MCPToolInputError.invalidArguments
        }
      }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let size = try ProductionCodec.fileSize(file)
      guard offset <= size else { throw MCPToolInputError.invalidArguments }
      try handle.seek(toOffset: UInt64(offset))
      let bytes = try handle.read(upToCount: call.integer("bytes", default: 262144)) ?? Data()
      return [
        "dataBase64": .string(bytes.base64EncodedString()), "offset": .integer(Int64(offset)),
        "totalBytes": .integer(Int64(size)), "nextOffset": .integer(Int64(offset + bytes.count)),
      ]
    default: throw MCPToolInputError.unknownTool
    }
  }
  nonisolated private static func exportRoot(storage: ProductionStorage, id: UUID) throws -> URL {
    let directory = storage.root.appendingPathComponent("MCPExports", isDirectory: true)
    let root = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    for url in [directory, root] {
      let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard info.isDirectory == true, info.isSymbolicLink != true else {
        throw ProductionFailure.integrity("Export directory is missing or is a symlink.")
      }
    }
    // FileManager enumeration resolves system aliases such as /tmp to /private/tmp.
    // Use the same canonical base for both relative listing and bounded reads.
    return root.resolvingSymlinksInPath().standardizedFileURL
  }
  nonisolated private static func dataChunk(_ bytes: Data, call: MCPControlCall) throws -> [String:
    MCPJSONValue]
  {
    let offset = call.integer("offset")
    let count = call.integer("bytes", default: 262144)
    guard offset <= bytes.count else { throw MCPToolInputError.invalidArguments }
    let part = bytes.subdata(in: offset..<min(bytes.count, offset + count))
    return [
      "dataBase64": .string(part.base64EncodedString()), "offset": .integer(Int64(offset)),
      "nextOffset": .integer(Int64(offset + part.count)),
      "totalBytes": .integer(Int64(bytes.count)),
    ]
  }
}
