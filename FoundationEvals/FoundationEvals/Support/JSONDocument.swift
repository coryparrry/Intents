import SwiftUI
import UniformTypeIdentifiers

/// Shared sorted-key JSON encoding and ISO-8601 date handling used by exports and evidence digests.
enum CanonicalJSON {
    /// Encodes with sorted keys and ISO-8601 dates, optionally adding whitespace for readable exports.
    static func data<Value: Encodable>(for value: Value, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decodes using ISO-8601 dates to match canonical run and suite exports.
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data = Data()

    /// Creates an empty JSON document for the file-document workflow.
    init() {}

    /// Preserves already encoded export bytes without parsing, validating, or reformatting JSON.
    init(data: Data) {
        self.data = data
    }

    /// Encodes a run into a readable canonical JSON document, propagating encoding failures.
    init(run: EvaluationRun) throws {
        data = try CanonicalJSON.data(for: run)
    }

    /// Reads regular file bytes without parsing JSON, using empty data if the wrapper has no regular-file contents.
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    /// Wraps the document's bytes as a regular file without re-encoding or validating JSON.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
