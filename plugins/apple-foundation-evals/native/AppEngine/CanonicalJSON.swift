import Foundation
enum CanonicalJSON {
    /// Encodes sorted-key JSON with ISO 8601 dates, optionally adding indentation, and propagates encoding failures.
    static func data<Value: Encodable>(for value: Value, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decodes JSON using ISO 8601 dates and propagates type or data decoding failures.
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
