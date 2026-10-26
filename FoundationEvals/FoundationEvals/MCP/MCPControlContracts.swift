import Foundation

struct MCPControlCall: Sendable {
  let name: String
  let arguments: MCPJSONValue
  /// Reads a string argument or the supplied fallback; throws invalidArguments when neither is
  /// available.
  func text(_ key: String, default fallback: String? = nil) throws -> String {
    if let value = arguments.objectValue?[key]?.stringValue { return value }
    if let fallback { return fallback }
    throw MCPToolInputError.invalidArguments
  }
  /// Returns a string argument, or nil for an absent key or a value of another JSON type.
  func optionalText(_ key: String) -> String? { arguments.objectValue?[key]?.stringValue }
  /// Parses a required string argument as a UUID and throws invalidArguments when it is missing or
  /// malformed.
  func id(_ key: String) throws -> UUID {
    guard let value = UUID(uuidString: try text(key)) else {
      throw MCPToolInputError.invalidArguments
    }
    return value
  }
  /// Parses an optional string argument as a UUID, returning nil when no string is present and throwing
  /// for a malformed UUID string.
  func optionalID(_ key: String) throws -> UUID? {
    try optionalText(key).map { value in
      guard let id = UUID(uuidString: value) else { throw MCPToolInputError.invalidArguments }
      return id
    }
  }
  /// Reads a Boolean argument, falling back when it is absent or has another JSON type.
  func flag(_ key: String, default fallback: Bool = false) -> Bool {
    if case .bool(let value) = arguments.objectValue?[key] { return value }
    return fallback
  }
  /// Reads a signed integer or floating-point argument as Double, otherwise returning the fallback.
  func number(_ key: String, default fallback: Double = 0) -> Double {
    switch arguments.objectValue?[key] {
    case .integer(let v): Double(v)
    case .number(let v): v
    default: fallback
    }
  }
  /// Converts a numeric argument to Int using the fallback when no supported number is present. Callers
  /// must first validate that the value is finite and representable.
  func integer(_ key: String, default fallback: Int = 0) -> Int {
    Int(number(key, default: Double(fallback)))
  }
  /// Decodes a JSON document stored in a required string argument using Foundation's default
  /// JSONDecoder conventions. Missing strings and decoding failures throw.
  func value<T: Decodable & Sendable>(_ key: String, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: Data(try text(key).utf8))
  }
}

enum MCPControlSchema {
  /// Declares a bounded string property for the control-schema validator, with default minimum length
  /// one.
  static func text(_ max: Int = 1024, minimum: Int = 1) -> MCPJSONValue {
    .object([
      "type": .string("string"), "minLength": .integer(Int64(minimum)),
      "maxLength": .integer(Int64(max)),
    ])
  }
  static var uuid: MCPJSONValue { .object(["type": .string("string"), "format": .string("uuid")]) }
  static var boolean: MCPJSONValue { .object(["type": .string("boolean")]) }
  /// Declares an inclusive numeric range, optionally requiring integral values.
  static func number(_ min: Double, _ max: Double, integer: Bool = false) -> MCPJSONValue {
    .object([
      "type": .string(integer ? "integer" : "number"), "minimum": .number(min),
      "maximum": .number(max),
    ])
  }
  /// Declares a string property restricted to the supplied choices.
  static func choices(_ values: [String]) -> MCPJSONValue {
    .object(["type": .string("string"), "enum": .array(values.map(MCPJSONValue.string))])
  }
  /// Builds a closed control-tool schema and annotations, adding a required UUID operationID to
  /// mutations. The title is derived from the action name.
  static func tool(
    _ name: String, _ description: String, _ fields: [String: MCPJSONValue] = [:],
    required: [String] = [], mutation: Bool = false, destructive: Bool = false
  ) -> MCPToolDefinition {
    var fields = fields
    var required = required
    if mutation {
      fields["operationID"] = uuid
      required.append("operationID")
    }
    return .init(
      name: name,
      title: name.replacingOccurrences(of: "eval_", with: "").replacingOccurrences(
        of: "_", with: " "), description: description,
      inputSchema: .object([
        "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
        "type": .string("object"), "properties": .object(fields),
        "required": .array(required.map(MCPJSONValue.string)), "additionalProperties": .bool(false),
      ]),
      annotations: .init(
        readOnlyHint: !mutation, destructiveHint: destructive, idempotentHint: mutation))
  }
  /// Validates the supported control-schema subset recursively, including required/extra properties,
  /// enums, UUIDs, and finite numeric bounds. String maxima count UTF-8 bytes while minima count
  /// characters; unsupported schema types throw invalidArguments.
  static func validate(_ value: MCPJSONValue, schema: MCPJSONValue) throws {
    guard let s = schema.objectValue else { throw MCPToolInputError.invalidArguments }
    if case .array(let allowed) = s["enum"], !allowed.contains(value) {
      throw MCPToolInputError.invalidArguments
    }
    switch s["type"]?.stringValue {
    case "object":
      guard let values = value.objectValue, let fields = s["properties"]?.objectValue else {
        throw MCPToolInputError.invalidArguments
      }
      if case .array(let required) = s["required"],
        required.contains(where: { values[$0.stringValue ?? ""] == nil })
      {
        throw MCPToolInputError.invalidArguments
      }
      if case .integer(let max) = s["maxProperties"], values.count > max {
        throw MCPToolInputError.invalidArguments
      }
      let acceptsAdditional = s["additionalProperties"] == .bool(true)
      guard acceptsAdditional || values.keys.allSatisfy({ fields[$0] != nil }) else {
        throw MCPToolInputError.invalidArguments
      }
      for (key, v) in values {
        if let field = fields[key] { try validate(v, schema: field) }
      }
    case "string":
      guard let text = value.stringValue else { throw MCPToolInputError.invalidArguments }
      if case .integer(let limit) = s["maxLength"], text.utf8.count > limit {
        throw MCPToolInputError.invalidArguments
      }
      if case .integer(let limit) = s["minLength"], text.count < limit {
        throw MCPToolInputError.invalidArguments
      }
      if s["format"]?.stringValue == "uuid", UUID(uuidString: text) == nil {
        throw MCPToolInputError.invalidArguments
      }
    case "boolean": guard case .bool = value else { throw MCPToolInputError.invalidArguments }
    case "number", "integer":
      let number: Double
      switch value {
      case .integer(let v): number = Double(v)
      case .number(let v): number = v
      default: throw MCPToolInputError.invalidArguments
      }
      guard number.isFinite, s["type"]?.stringValue != "integer" || number.rounded() == number
      else { throw MCPToolInputError.invalidArguments }
      if case .number(let min) = s["minimum"], number < min {
        throw MCPToolInputError.invalidArguments
      }
      if case .number(let max) = s["maximum"], number > max {
        throw MCPToolInputError.invalidArguments
      }
    default: throw MCPToolInputError.invalidArguments
    }
  }
}
