import Foundation

enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    /// Decodes a JSON value, trying signed and unsigned integers before floating point to preserve
    /// integer precision where supported. Unsupported representations propagate a decoding error.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    /// Encodes the associated JSON value through a single-value container; encoder failures propagate.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Converts an Encodable value to the MCP JSON representation through Foundation JSON encoding and
    /// decoding.
    static func encode<T: Encodable & Sendable>(_ value: T) throws -> MCPJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPJSONValue.self, from: data)
    }

    /// Decodes this JSON representation into the requested type using Foundation's default JSON coding
    /// conventions.
    func decode<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Returns compact JSON with sorted object keys and unescaped slashes. Throws on encoding failure
    /// or an invalid UTF-8 conversion.
    func jsonText() throws -> String {
        let data = try JSONEncoder.sorted.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPCodecError.invalidUTF8
        }
        return text
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum MCPCodecError: Error {
    case invalidUTF8
}

struct MCPHTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Normalizes the HTTP method to uppercase and header keys to lowercase while retaining the
    /// supplied body and path. Header keys must remain unique after normalization.
    init(method: String, path: String = "/mcp", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    /// Looks up a request header without regard to the case of its name.
    subscript(header name: String) -> String? { headers[name.lowercased()] }
}

struct MCPHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data?

    /// Builds a bodyless response with security headers and an optional Allow header.
    static func empty(_ status: Int, allow: String? = nil) -> Self {
        var headers = securityHeaders
        if let allow { headers["Allow"] = allow }
        return Self(status: status, headers: headers, body: nil)
    }

    static var securityHeaders: [String: String] {
        [
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff"
        ]
    }
}
