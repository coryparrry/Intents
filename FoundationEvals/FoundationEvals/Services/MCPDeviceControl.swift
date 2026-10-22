import Foundation

@MainActor enum MCPDeviceControl {
  static func encode<T: Encodable & Sendable>(_ value: T) throws -> MCPJSONValue {
    let result = try MCPJSONValue.encode(value)
    guard try result.jsonText().utf8.count <= 4_194_304 else {
      throw EvaluationStoreError.resourceConflict("Response exceeds 4 MiB. Reduce its page.")
    }
    return result
  }
  static func execute(_ call: MCPControlCall, control: EvaluationAppControl) throws
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
      try control.mcp.track(operation) {
        while let status = runners.status(for: id),
          [.preparing, .dispatching, .running].contains(status.phase)
        {
          if Task.isCancelled {
            return .failure(code: "cancelled", message: "App control stopped waiting during shutdown. Inspect saved runner evidence.")
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
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
