import Foundation

enum MCPActionCatalogCall: Sendable {
  case search(query: String, domain: String?, offset: Int, limit: Int)
  case describe(name: String)
}

/// A stable small surface for clients that cannot defer MCP tool loading themselves.
enum MCPActionDiscovery {
  static let coreNames: Set<String> = [
    "eval_get_state", "eval_list_projects", "eval_check", "eval_release_report",
    "eval_project_release_report", "eval_suite_configure", "eval_start_run", "eval_get_run",
    "eval_list_runs", "eval_analyze_run", "eval_cancel_run", "eval_workspace_state",
    "eval_workspace_select", "eval_project_create", "eval_production_state",
    "eval_production_job_create", "eval_production_job_start", "eval_production_job_get",
    "eval_production_results", "eval_operation_status",
  ]
  static let domains = [
    "workspace", "evaluations", "production", "reviews", "judges", "runners", "intentLab",
  ]
  static let definitions: [MCPToolDefinition] = {
    let s = MCPControlSchema.self
    let arguments: MCPJSONValue = .object([
      "type": .string("object"), "properties": .object([:]),
      "additionalProperties": .bool(true), "maxProperties": .integer(64),
      "description": .string(
        "Exact arguments from eval_describe_action. The server validates the selected action's original schema, revisions and approvals."
      ),
    ])
    let invokeFields = ["action": s.text(128), "arguments": arguments]
    return [
      s.tool(
        "eval_find_actions",
        "Find app operations by keywords and domain. Returns at most ten short summaries, without loading their schemas. Describe only the actions needed for this task.",
        [
          "query": s.text(256, minimum: 0), "domain": s.choices(domains),
          "offset": s.number(0, 10000, integer: true), "limit": s.number(1, 10, integer: true),
        ]),
      s.tool(
        "eval_describe_action",
        "Load one action's exact input schema, annotations and read/write entry point. Every original app operation remains available.",
        ["action": s.text(128)], required: ["action"]),
      s.tool(
        "eval_read_action",
        "Invoke a read-only app action using its described arguments. Mutation actions are rejected before execution.",
        invokeFields, required: ["action", "arguments"]),
      s.tool(
        "eval_apply_action",
        "Invoke a mutation using its described arguments and operator authorization. Original operation IDs, conflict checks, consent and durable receipts still apply. Read-only actions are rejected.",
        invokeFields, required: ["action", "arguments"], mutation: false, destructive: true),
    ].map { value in
      guard value.name == "eval_apply_action" else { return value }
      // Mixed mutations include legacy operations; do not promise universal idempotence.
      return MCPToolDefinition(
        name: value.name, title: value.title, description: value.description,
        inputSchema: value.inputSchema,
        annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false))
    }
  }()
  static let names = Set(definitions.map(\.name))

  static func parse(name: String, arguments: MCPJSONValue) throws -> MCPToolCall {
    guard let definition = definitions.first(where: { $0.name == name }) else {
      throw MCPToolInputError.unknownTool
    }
    try MCPControlSchema.validate(arguments, schema: definition.inputSchema)
    let call = MCPControlCall(name: name, arguments: arguments)
    switch name {
    case "eval_find_actions":
      return .actionCatalog(
        .search(
          query: try call.text("query", default: ""), domain: call.optionalText("domain"),
          offset: call.integer("offset"), limit: call.integer("limit", default: 5)))
    case "eval_describe_action":
      let action = try call.text("action")
      guard MCPToolCatalog.allDefinitions.contains(where: { $0.name == action }) else {
        throw MCPToolInputError.unknownTool
      }
      return .actionCatalog(.describe(name: action))
    default:
      let action = try call.text("action")
      guard let target = MCPToolCatalog.allDefinitions.first(where: { $0.name == action }) else {
        // Discovery entry points are not actions, preventing recursive invocation.
        throw MCPToolInputError.unknownTool
      }
      guard target.annotations.readOnlyHint == (name == "eval_read_action"),
        let exactArguments = arguments.objectValue?["arguments"]
      else { throw MCPToolInputError.invalidArguments }
      // Return the original typed call. Receipt identity and all authority checks are unchanged.
      return try MCPToolCatalog.parse(name: action, arguments: exactArguments)
    }
  }

  static func domain(_ name: String) -> String {
    if name.hasPrefix("eval_production_") { return "production" }
    if name.hasPrefix("eval_runner_") { return "runners" }
    if name.hasPrefix("eval_intent_") || name.contains("scenario") { return "intentLab" }
    if name.hasPrefix("eval_judge_") || name.contains("calibration") { return "judges" }
    if name.contains("review") || name.contains("baseline") || name.contains("experiment")
      || name.contains("regression_promote")
    {
      return "reviews"
    }
    if name.hasPrefix("eval_workspace_") || name.hasPrefix("eval_project_")
      || name.hasPrefix("eval_suite_") || name.hasPrefix("eval_operation_")
      || name == "eval_control_capabilities"
    {
      return "workspace"
    }
    return "evaluations"
  }

  static func metrics() throws -> MCPJSONValue {
    let compact = try MCPJSONValue.encode(MCPToolCatalog.definitions).jsonText().utf8.count
    let full = try MCPJSONValue.encode(MCPToolCatalog.allDefinitions).jsonText().utf8.count
    return .object([
      "defaultToolCount": .integer(Int64(MCPToolCatalog.definitions.count)),
      "actionCount": .integer(Int64(MCPToolCatalog.allDefinitions.count)),
      "defaultSchemaBytes": .integer(Int64(compact)), "fullSchemaBytes": .integer(Int64(full)),
    ])
  }

  static func respond(_ call: MCPActionCatalogCall) -> MCPToolPayload {
    do {
      switch call {
      case .describe(let name):
        guard let value = MCPToolCatalog.allDefinitions.first(where: { $0.name == name }) else {
          throw MCPToolInputError.unknownTool
        }
        return .init(
          structuredContent: .object([
            "action": try .encode(value), "domain": .string(domain(name)),
            "invokeWith": .string(
              value.annotations.readOnlyHint ? "eval_read_action" : "eval_apply_action"),
          ]))
      case .search(let query, let requestedDomain, let offset, let limit):
        let words = query.lowercased().split { $0.isWhitespace || $0 == "_" || $0 == "-" }
        let matches = MCPToolCatalog.allDefinitions.filter { value in
          let text = (value.name + " " + value.description).lowercased()
          return (requestedDomain == nil || domain(value.name) == requestedDomain)
            && words.allSatisfy { text.contains($0) }
        }.sorted { a, b in
          func rank(_ value: MCPToolDefinition) -> Int {
            if value.name == query { return Int.max }
            return words.filter { value.name.contains($0) }.count
          }
          let first = rank(a)
          let second = rank(b)
          return first == second ? a.name < b.name : first > second
        }
        let page = matches.dropFirst(offset).prefix(limit).map { value in
          MCPJSONValue.object([
            "name": .string(value.name), "description": .string(value.description),
            "domain": .string(domain(value.name)),
            "annotations": (try? .encode(value.annotations)) ?? .null,
            "direct": .bool(coreNames.contains(value.name)),
          ])
        }
        return .init(
          structuredContent: .object([
            "actions": .array(page), "total": .integer(Int64(matches.count)),
            "nextOffset": offset + page.count < matches.count
              ? .integer(Int64(offset + page.count)) : .null,
            "catalog": try metrics(),
          ]))
      }
    } catch {
      return .failure(
        code: "action_discovery_failed", message: "The requested action schema is unavailable.")
    }
  }
}
