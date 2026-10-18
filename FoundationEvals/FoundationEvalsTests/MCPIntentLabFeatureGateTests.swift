import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct MCPIntentLabFeatureGateTests {
  private func fixture(enabled: Bool = false) async throws -> (EvaluationAppControl, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-intent-gate-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let gate = IntentLabFeatureGate(load: { enabled })
    if enabled { await gate.refresh() }
    return (EvaluationAppControl(store: EvaluationStore(supportDirectory: root), intentLabFeatureGate: gate), root)
  }

  private func array(_ value: MCPJSONValue?) throws -> [MCPJSONValue] {
    guard case .array(let values) = value else { throw MCPToolInputError.invalidArguments }
    return values
  }

  private func expectDisabled(_ payload: MCPToolPayload) {
    #expect(payload.isError)
    #expect(payload.structuredContent.objectValue?["error"]?.objectValue?["code"] == .string("feature_disabled"))
  }

  @Test func disabledGateBlocksAuthorityAndControlBeforeSideEffects() async throws {
    let (control, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let authority = MCPStoreAuthority.make(store: control.store, control: control)
    let draft = control.scenarios.draft
    let call = MCPControlCall(name: "eval_intent_new", arguments: .object([
      "operationID": .string(UUID().uuidString), "expectedIntentRevision": .string("unread")
    ]))
    expectDisabled(await authority.call(.control(call)))
    expectDisabled(await control.mcp.execute(call))
    expectDisabled(await authority.call(.listScenarioRuns(.init(scenarioID: nil, cursor: nil, limit: 20))))
    expectDisabled(await authority.call(.getScenarioReport(.init(runID: UUID()))))
    expectDisabled(await authority.call(.getScenarioExecutionReport(.init(executionID: UUID()))))
    #expect(!control.scenarios.hasLoaded)
    #expect(control.scenarios.draft.id == draft.id)
    #expect(!FileManager.default.fileExists(atPath: control.store.overviewStorageDirectory.appendingPathComponent("MCPControl").path))
    #expect(!(await authority.call(.control(.init(name: "eval_workspace_state", arguments: .object([:]))))).isError)
  }

  @Test func disabledGateAllowsCancellationWithoutLoadingOrWritingReceipts() async throws {
    let (control, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let call = MCPControlCall(name: "eval_intent_cancel", arguments: .object([:]))
    let direct = await control.mcp.execute(call)
    let authority = MCPStoreAuthority.make(store: control.store, control: control)
    let routed = await authority.call(.control(call))
    for payload in [direct, routed] {
      #expect(!payload.isError)
      #expect(payload.structuredContent.objectValue?["outcome"] == .string("committed"))
    }
    #expect(!control.scenarios.hasLoaded)
    #expect(!FileManager.default.fileExists(atPath: control.store.overviewStorageDirectory.appendingPathComponent("MCPControl").path))
  }

  @Test func disabledNavigationDoesNotWriteReceiptOrSelection() async throws {
    let (control, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let call = MCPControlCall(name: "eval_workspace_navigate", arguments: .object([
      "operationID": .string(UUID().uuidString),
      "expectedWorkspaceRevision": .string(try MCPWorkspaceControl.revision(control.store)),
      "section": .string("intentLab")
    ]))
    expectDisabled(await control.mcp.execute(call))
    #expect(control.store.selection == .overview)
    #expect(!FileManager.default.fileExists(atPath: control.store.overviewStorageDirectory.appendingPathComponent("MCPControl").path))
  }

  @Test func disabledGateTakesPrecedenceOverPersistedReceiptReplay() async throws {
    let (control, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let call = MCPControlCall(name: "eval_intent_new", arguments: .object(["operationID": .string(operationID.uuidString)]))
    let directory = control.store.overviewStorageDirectory.appendingPathComponent("MCPControl")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let digest = ProductionCodec.digest(Data(try call.arguments.jsonText().utf8) + Data(call.name.utf8))
    let receipt = MCPControlReceipt(id: operationID, digest: digest, phase: "committed", content: .object(["outcome": .string("committed")]))
    let file = directory.appendingPathComponent(operationID.uuidString + ".json")
    let bytes = try JSONEncoder().encode(receipt)
    try bytes.write(to: file)
    expectDisabled(await control.mcp.execute(call))
    #expect(try Data(contentsOf: file) == bytes)
    #expect(!control.scenarios.hasLoaded)
  }

  @Test func authorityDiscoveryReflectsFlagAndEnabledScenarioReadsWork() async throws {
    for enabled in [false, true] {
      let (control, root) = try await fixture(enabled: enabled)
      defer { try? FileManager.default.removeItem(at: root) }
      let authority = MCPStoreAuthority.make(store: control.store, control: control)
      let search = await authority.call(.actionCatalog(.search(query: "", domain: "intentLab", offset: 0, limit: 10)))
      let actions = try array(search.structuredContent.objectValue?["actions"])
      #expect(actions.isEmpty == !enabled)
      let described = await authority.call(.actionCatalog(.describe(name: "eval_intent_state")))
      #expect(described.isError == !enabled)
      let runners = await authority.call(.actionCatalog(.search(query: "", domain: "runners", offset: 0, limit: 10)))
      #expect(!(try array(runners.structuredContent.objectValue?["actions"])).isEmpty)
      let capabilities = await control.mcp.execute(.init(name: "eval_control_capabilities", arguments: .object([:])))
      let names = try array(capabilities.structuredContent.objectValue?["tools"])
      #expect(names.contains(.string("eval_intent_state")) == enabled)
      #expect(names.contains(.string("eval_runner_state")))
      let report = await authority.call(.listScenarioRuns(.init(scenarioID: nil, cursor: nil, limit: 20)))
      #expect(report.isError == !enabled)
    }
  }

  @Test func protocolDiscoveryAndWrappedCallsUseTheLiveGate() async throws {
    let (control, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let credential = String(repeating: "A", count: 43)
    let handler = MCPProtocolHandler(authority: MCPStoreAuthority.make(store: control.store, control: control), credential: credential)
    let requests: [(String, [String: MCPJSONValue])] = [
      ("eval_find_actions", ["domain": .string("intentLab")]),
      ("eval_describe_action", ["action": .string("eval_intent_state")]),
      ("eval_read_action", ["action": .string("eval_intent_state"), "arguments": .object([:])])
    ]
    for (name, arguments) in requests {
      let body = try MCPJSONValue.object([
        "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/call"),
        "params": .object(["name": .string(name), "arguments": .object(arguments)])
      ]).jsonText()
      let response = await handler.handle(.init(method: "POST", headers: [
        "host": "127.0.0.1:17873", "authorization": "Bearer \(credential)", "content-type": "application/json"
      ], body: Data(body.utf8)))
      #expect(response.status == 200)
      let data = try #require(response.body)
      let result = try #require(JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue?["result"]?.objectValue)
      if name == "eval_find_actions" {
        #expect(try array(result["structuredContent"]?.objectValue?["actions"]).isEmpty)
      } else {
        #expect(result["isError"] == .bool(true))
      }
    }
    #expect(!control.scenarios.hasLoaded)
  }

}
