import Foundation

struct MCPControlReceipt: Codable, Sendable {
  var id: UUID
  var digest: String
  var phase: String
  var content: MCPJSONValue?
  var isError: Bool = false
}

@MainActor final class MCPControlService {
  unowned let control: EvaluationAppControl
  private let directory: URL
  private var activeMutation: UUID?
  private var tasks: [UUID: Task<Void, Never>] = [:]
  var deviceOperationID: UUID?
  var installations: [UUID: MCPIntentInstallationPreview] = [:]
  init(control: EvaluationAppControl) {
    self.control = control
    directory = control.store.overviewStorageDirectory.appendingPathComponent("MCPControl")
  }
  func execute(_ call: MCPControlCall) async -> MCPToolPayload {
    do {
      guard let definition = MCPControlTools.definitions.first(where: { $0.name == call.name })
      else { throw MCPToolInputError.unknownTool }
      if call.name == "eval_control_capabilities" {
        return Self.read([
          "tools": .array(MCPControlTools.definitions.map { .string($0.name) }),
          "boundary": .string(
            "Authenticated app control; original suite tools remain available. Operator confirmations, pairing, readiness, disclosure and execution leases remain required."
          ),
        ])
      }
      if call.name == "eval_operation_status" {
        let receipt = try load(call.id("operationID"))
        guard let receipt else {
          throw EvaluationStoreError.resourceConflict(
            "No mutation receipt exists for this operation.")
        }
        return Self.read([
          "receipt": try .encode(receipt),
          "interrupted": .bool(
            (receipt.phase == "pending" || receipt.phase == "dispatched")
              && activeMutation != receipt.id && tasks[receipt.id] == nil),
        ])
      }
      if call.name == "eval_operation_result_read" {
        let id = try call.id("operationID")
        guard let receipt = try load(id), receipt.content?.objectValue?["resultFile"] == .bool(true)
        else { throw EvaluationStoreError.resourceNotFound("Operation result artifact") }
        let file = directory.appendingPathComponent(id.uuidString + ".result")
        let size = try ProductionCodec.fileSize(file)
        let offset = call.integer("offset")
        guard size <= 8_388_608, offset <= size else { throw MCPToolInputError.invalidArguments }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: call.integer("bytes", default: 262144)) ?? Data()
        return Self.read([
          "dataBase64": .string(bytes.base64EncodedString()), "totalBytes": .integer(Int64(size)),
          "nextOffset": .integer(Int64(offset + bytes.count)),
        ])
      }
      if definition.annotations.readOnlyHint { return try await route(call) }
      let id = try call.id("operationID")
      let digest = ProductionCodec.digest(
        Data(try call.arguments.jsonText().utf8) + Data(call.name.utf8))
      if let receipt = try load(id) {
        guard receipt.digest == digest else {
          throw EvaluationStoreError.resourceConflict(
            "Operation ID belongs to a different request. Reread state and use a new ID for a new action."
          )
        }
        guard let content = receipt.content else {
          return .failure(
            code: "needs_evidence",
            message:
              "This operation is active or was interrupted. Inspect its target state before deciding another action; it will not be automatically replayed."
          )
        }
        var value = content.objectValue ?? [:]
        value["duplicate"] = .bool(true)
        return .init(structuredContent: .object(value), isError: receipt.isError)
      }
      guard activeMutation == nil else {
        throw EvaluationStoreError.resourceConflict(
          "Another MCP mutation is in progress. Read its status and retry after it finishes.")
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .count < 10000
      else {
        throw EvaluationStoreError.resourceConflict(
          "MCP receipt retention limit reached. Preserve receipts before operator-managed cleanup.")
      }
      activeMutation = id
      defer { activeMutation = nil }
      var receipt = MCPControlReceipt(id: id, digest: digest, phase: "pending")
      try save(receipt)
      do {
        let payload = try await route(call)
        receipt.phase =
          payload.isError
          ? "failed"
          : (payload.structuredContent.objectValue?["execution"] == .string("dispatched")
            ? "dispatched" : "committed")
        receipt.content = payload.structuredContent
        receipt.isError = payload.isError
        try save(receipt)
        return payload
      } catch {
        let failure = Self.failure(error)
        receipt.phase = "failed"
        receipt.content = failure.structuredContent
        receipt.isError = true
        try? save(receipt)
        return failure
      }
    } catch { return Self.failure(error) }
  }
  func completeOperation(_ id: UUID, payload: MCPToolPayload) {
    do {
      guard var receipt = try load(id) else { return }
      receipt.phase = payload.isError ? "failed" : "completed"
      receipt.content = payload.structuredContent
      receipt.isError = payload.isError
      try save(receipt)
    } catch {
      control.store.notice =
        "MCP completion receipt could not be saved: \(error.localizedDescription)"
    }
  }
  func track(_ id: UUID, body: @escaping @MainActor () async -> MCPToolPayload) {
    tasks[id] = Task {
      defer { tasks[id] = nil }
      let payload = await body()
      completeOperation(id, payload: payload)
    }
  }
  func dispatch(
    _ call: MCPControlCall, body: @escaping @MainActor () async throws -> MCPToolPayload
  ) throws -> MCPToolPayload {
    guard deviceOperationID == nil else { throw EvaluationStoreError.runBusy }
    let id = try call.id("operationID")
    deviceOperationID = id
    tasks[id] = Task {
      defer {
        tasks[id] = nil
        deviceOperationID = nil
      }
      let result: MCPToolPayload
      do { result = try await body() } catch { result = Self.failure(error) }
      do {
        guard var receipt = try load(id) else { return }
        receipt.phase = result.isError ? "failed" : "completed"
        receipt.content = result.structuredContent
        receipt.isError = result.isError
        try save(receipt)
      } catch {
        control.scenarios.notice =
          "MCP operation finished but its receipt could not be saved: \(error.localizedDescription)"
      }
    }
    return Self.committed([
      "operationID": .string(id.uuidString), "execution": .string("dispatched"),
    ])
  }
  private func route(_ call: MCPControlCall) async throws -> MCPToolPayload {
    if call.name.hasPrefix("eval_production_") {
      return try await MCPProductionControl.execute(call, control: control)
    }
    if call.name.hasPrefix("eval_intent_") || call.name.hasPrefix("eval_runner_") {
      return try await MCPDeviceControl.execute(call, control: control, service: self)
    }
    return try await MCPWorkspaceControl.execute(call, control: control)
  }
  private func load(_ id: UUID) throws -> MCPControlReceipt? {
    let file = directory.appendingPathComponent(id.uuidString + ".json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard try ProductionCodec.fileSize(file) <= 1_048_576 else {
      throw EvaluationStoreError.persistence("MCP receipt exceeds its bound.")
    }
    let bytes = try Data(contentsOf: file)
    guard bytes.count <= 1_048_576 else {
      throw EvaluationStoreError.persistence("MCP operation receipt exceeds its bound.")
    }
    return try JSONDecoder().decode(MCPControlReceipt.self, from: bytes)
  }
  private func save(_ receipt: MCPControlReceipt) throws {
    var receipt = receipt
    if let content = receipt.content {
      let resultBytes = Data(try content.jsonText().utf8)
      if resultBytes.count > 786_432 {
        guard resultBytes.count <= 8_388_608 else {
          throw EvaluationStoreError.persistence(
            "Operation result exceeds 8 MiB. Inspect its saved domain evidence.")
        }
        let file = directory.appendingPathComponent(receipt.id.uuidString + ".result")
        try resultBytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        receipt.content = .object([
          "operationID": .string(receipt.id.uuidString), "outcome": .string(receipt.phase),
          "resultFile": .bool(true), "resultBytes": .integer(Int64(resultBytes.count)),
          "resultSHA256": .string(ProductionCodec.digest(resultBytes)),
        ])
      }
    }
    let bytes = try JSONEncoder.sorted.encode(receipt)
    guard bytes.count <= 1_048_576 else {
      throw EvaluationStoreError.persistence(
        "MCP mutation result exceeds the receipt bound. Inspect the target state.")
    }
    let file = directory.appendingPathComponent(receipt.id.uuidString + ".json")
    try bytes.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  static func read(_ values: [String: MCPJSONValue]) -> MCPToolPayload {
    .init(structuredContent: .object(values))
  }
  static func committed(_ values: [String: MCPJSONValue] = [:]) -> MCPToolPayload {
    var values = values
    values["outcome"] = .string("committed")
    return read(values)
  }
  nonisolated static func failure(_ error: Error) -> MCPToolPayload {
    .failure(
      code: error is MCPToolInputError ? "invalid_arguments" : "control_failed",
      message: error.localizedDescription)
  }
  nonisolated static func confirm(_ call: MCPControlCall, key: String = "confirm") throws {
    guard call.flag(key) else { throw MCPToolInputError.confirmationRequired }
  }
}
