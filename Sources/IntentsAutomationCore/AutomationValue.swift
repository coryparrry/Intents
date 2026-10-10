import Foundation

/// Explicit tags shared with the private Node protocol. Exact numbers never pass
/// through a JavaScript floating-point conversion.
public indirect enum AutomationValue: Equatable, Sendable {
    case text(String), bool(Bool), integer(String), decimal(String)
    case date(String, timeZone: String), enumeration(typeID: String, value: String)
    case entity(typeID: String, value: String), artifact(handle: String, sha256: String)
    case array([AutomationValue]), object([String: AutomationValue]), null, omission
}

extension AutomationValue: Codable {
    private enum Key: String, CodingKey { case kind, value, timeZone, typeId, sha256 }
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 32 else { throw Self.invalid(decoder, "Value nesting limit") }
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let allowed: Set<String>
        switch kind {
        case "null", "omission": allowed = ["kind"]
        case "date": allowed = ["kind", "value", "timeZone"]
        case "enum", "entity": allowed = ["kind", "value", "typeId"]
        case "artifact": allowed = ["kind", "value", "sha256"]
        default: allowed = ["kind", "value"]
        }
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: allowed) else { throw Self.invalid(decoder, "Unknown value key") }
        switch kind {
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "integer", "decimal":
            let value = try c.decode(String.self, forKey: .value)
            let pattern = kind == "integer" ? #"^-?(0|[1-9][0-9]*)$"# : #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#
            guard value.count <= (kind == "integer" ? 128 : 256), value.range(of: pattern, options: .regularExpression) != nil else {
                throw Self.invalid(decoder, "Invalid exact number")
            }
            self = kind == "integer" ? .integer(value) : .decimal(value)
        case "date":
            let zone = try c.decode(String.self, forKey: .timeZone)
            guard TimeZone(identifier: zone) != nil else { throw Self.invalid(decoder, "Invalid timezone") }
            self = .date(try c.decode(String.self, forKey: .value), timeZone: zone)
        case "enum": self = .enumeration(typeID: try c.decode(String.self, forKey: .typeId), value: try c.decode(String.self, forKey: .value))
        case "entity": self = .entity(typeID: try c.decode(String.self, forKey: .typeId), value: try c.decode(String.self, forKey: .value))
        case "artifact":
            let digest = try c.decode(String.self, forKey: .sha256)
            guard digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw Self.invalid(decoder, "Invalid digest") }
            self = .artifact(handle: try c.decode(String.self, forKey: .value), sha256: digest)
        case "array":
            let values = try c.decode([AutomationValue].self, forKey: .value)
            guard values.count <= 1000 else { throw Self.invalid(decoder, "Array limit") }; self = .array(values)
        case "object": self = .object(try c.decode([String: AutomationValue].self, forKey: .value))
        case "null": self = .null
        case "omission": self = .omission
        default: throw Self.invalid(decoder, "Unknown value tag")
        }
        try validate()
    }
    private static func invalid(_ decoder: Decoder, _ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: Key.self)
        func scalar<T: Encodable>(_ kind: String, _ value: T) throws {
            try c.encode(kind, forKey: .kind); try c.encode(value, forKey: .value)
        }
        switch self {
        case .text(let v): try scalar("text", v)
        case .bool(let v): try scalar("bool", v)
        case .integer(let v): try scalar("integer", v)
        case .decimal(let v): try scalar("decimal", v)
        case .date(let v, let zone): try scalar("date", v); try c.encode(zone, forKey: .timeZone)
        case .enumeration(let id, let v): try scalar("enum", v); try c.encode(id, forKey: .typeId)
        case .entity(let id, let v): try scalar("entity", v); try c.encode(id, forKey: .typeId)
        case .artifact(let h, let sha): try scalar("artifact", h); try c.encode(sha, forKey: .sha256)
        case .array(let v): try scalar("array", v)
        case .object(let v): try scalar("object", v)
        case .null: try c.encode("null", forKey: .kind)
        case .omission: try c.encode("omission", forKey: .kind)
        }
    }
}


extension AutomationValue {
    public func validate() throws {
        var nodes = 0
        try validate(depth: 0, nodes: &nodes)
    }
    private func validate(depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 16, nodes <= 10_000 else { throw AutomationContractError.invalidPlan("Value nesting/node limit") }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 256 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
        }
        func require(_ valid: Bool) throws {
            guard valid else { throw AutomationContractError.invalidPlan("Invalid tagged value") }
        }
        switch self {
        case .text(let value): try require(value.utf16.count <= 32_768)
        case .integer(let value): try require(value.count <= 128 && value.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil)
        case .decimal(let value): try require(value.count <= 256 && value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil)
        case .date(let value, let zone):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fraction = formatter.date(from: value)
            formatter.formatOptions = [.withInternetDateTime]
            try require(zone.count <= 128 && TimeZone(identifier: zone) != nil && (fraction != nil || formatter.date(from: value) != nil))
        case .enumeration(let type, let value): try require(identifier(type) && identifier(value))
        case .entity(let type, let value): try require(identifier(type) && !value.isEmpty && value.utf16.count <= 1024)
        case .artifact(let handle, let digest): try require(identifier(handle) && digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil)
        case .array(let values):
            try require(values.count <= 1000)
            for value in values { try value.validate(depth: depth + 1, nodes: &nodes) }
        case .object(let values):
            for (key, value) in values { try require(identifier(key)); try value.validate(depth: depth + 1, nodes: &nodes) }
        case .bool, .null, .omission: break
        }
    }
}
