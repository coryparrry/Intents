import Foundation

/// JSON transport vocabulary. Exact business numbers remain tagged strings in AutomationValue.
public indirect enum AutomationJSON: Codable, Equatable, Sendable {
    case object([String: AutomationJSON]), array([AutomationJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < 40 else { throw AutomationRPCError.invalidFrame }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode([AutomationJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AutomationJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): guard value.isFinite else { throw AutomationRPCError.invalidFrame }; try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public var object: [String: AutomationJSON]? { if case .object(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
}

public enum AutomationRPCError: Error, Equatable, Sendable {
    case invalidFrame, timedOut
}
