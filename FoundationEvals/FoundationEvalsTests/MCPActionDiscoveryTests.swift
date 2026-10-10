import Foundation
import Testing

@testable import FoundationEvals

struct MCPActionDiscoveryTests {
  private func response(_ name: String, _ fields: [String: MCPJSONValue] = [:]) throws
    -> MCPJSONValue
  {
    let parsed = try MCPToolCatalog.parse(name: name, arguments: .object(fields))
    guard case .actionCatalog(let call) = parsed else { throw MCPToolInputError.invalidArguments }
    let payload = MCPActionDiscovery.respond(call)
    #expect(!payload.isError)
    return payload.structuredContent
  }
  private func page(_ value: MCPJSONValue) throws -> [MCPJSONValue] {
    guard case .array(let values) = value.objectValue?["actions"] else {
      throw MCPToolInputError.invalidArguments
    }
    return values
  }

  @Test func smallDefaultCatalogRetainsEveryOriginalAction() throws {
    #expect(MCPToolCatalog.definitions.count == 24)
    #expect(MCPToolCatalog.allDefinitions.count == 123)
    #expect(Set(MCPToolCatalog.definitions.map(\.name)).count == 24)
    #expect(!MCPToolCatalog.definitions.contains { $0.name == "eval_intent_install_apply" })
    let compact = try MCPJSONValue.encode(MCPToolCatalog.definitions).jsonText().utf8.count
    let full = try MCPJSONValue.encode(MCPToolCatalog.allDefinitions).jsonText().utf8.count
    print("MCP catalog: 24 default tools / 123 actions; schema bytes \(compact) / \(full)")
    #expect(compact * 2 < full)
    #expect(
      MCPActionDiscovery.coreNames.isSubset(of: Set(MCPToolCatalog.allDefinitions.map(\.name))))
  }

  @Test func boundedDiscoveryCoversAllActionsWithoutReturningSchemas() throws {
    var names: [String] = []
    var offset = 0
    repeat {
      let value = try response(
        "eval_find_actions", ["offset": .integer(Int64(offset)), "limit": .integer(7)])
      let values = try page(value)
      #expect(values.count <= 7)
      #expect(
        values.allSatisfy {
          $0.objectValue?["inputSchema"] == nil && $0.objectValue?["arguments"] == nil
        })
      names += values.compactMap { $0.objectValue?["name"]?.stringValue }
      guard case .integer(let next) = value.objectValue?["nextOffset"] else { break }
      #expect(next > offset)
      offset = Int(next)
    } while offset < 10000
    #expect(names.count == 123)
    #expect(Set(names) == Set(MCPToolCatalog.allDefinitions.map(\.name)))
    let empty = try response("eval_find_actions", ["query": .string("no_such_capability_zzzz")])
    #expect(try page(empty).isEmpty)
  }

  @Test func focusedSearchLoadsOnlyAnExactOriginalSchema() throws {
    let name = "eval_intent_install_preview"
    let matches = try page(
      response(
        "eval_find_actions",
        ["query": .string(name), "domain": .string("intentLab"), "limit": .integer(1)]))
    #expect(matches.count == 1)
    #expect(matches.first?.objectValue?["name"] == .string(name))
    let described = try response("eval_describe_action", ["action": .string(name)])
    let original = try #require(MCPToolCatalog.allDefinitions.first { $0.name == name })
    #expect(described.objectValue?["action"] == (try MCPJSONValue.encode(original)))
    #expect(described.objectValue?["invokeWith"] == .string("eval_apply_action"))
    let read = try response("eval_describe_action", ["action": .string("eval_intent_state")])
    #expect(read.objectValue?["invokeWith"] == .string("eval_read_action"))
  }

  @Test func invocationRetainsTypedValidationAndRejectsWrongAuthority() throws {
    let args: MCPJSONValue = .object([
      "operationID": .string(UUID().uuidString), "name": .string("created"),
      "expectedWorkspaceRevision": .string(String(repeating: "a", count: 64)),
    ])
    let parsed = try MCPToolCatalog.parse(
      name: "eval_apply_action",
      arguments: .object([
        "action": .string("eval_project_create"), "arguments": args,
      ]))
    guard case .control(let actual) = parsed else { throw MCPToolInputError.invalidArguments }
    #expect(actual.name == "eval_project_create")
    #expect(actual.arguments == args)
    for (gateway, action, fields) in [
      ("eval_read_action", "eval_project_create", args),
      ("eval_apply_action", "eval_intent_state", .object([:])),
      ("eval_read_action", "eval_apply_action", .object([:])),
      ("eval_apply_action", "unknown_action", .object([:])),
      (
        "eval_apply_action", "eval_project_create",
        .object(["name": .string("missing revisions and operation ID")])
      ),
      ("eval_read_action", "eval_intent_state", .object(["shell": .string("arbitrary")])),
    ] {
      #expect(throws: MCPToolInputError.self) {
        try MCPToolCatalog.parse(
          name: gateway, arguments: .object(["action": .string(action), "arguments": fields]))
      }
    }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_read_action",
        arguments: .object([
          "action": .string("eval_intent_state"), "arguments": .object([:]), "confirm": .bool(true),
        ]))
    }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_find_actions", arguments: .object(["limit": .integer(11)]))
    }
    #expect(throws: MCPToolInputError.self) {
      try MCPToolCatalog.parse(
        name: "eval_find_actions", arguments: .object(["offset": .integer(-1)]))
    }
  }
}
