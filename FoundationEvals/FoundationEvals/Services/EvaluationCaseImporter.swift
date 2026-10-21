import Foundation

enum EvaluationCaseImportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case jsonLines

    var id: Self { self }
}

struct EvaluationCaseImportMapping: Equatable, Sendable {
    var nameColumn: String?
    var promptColumn: String
    var expectedColumn: String?
}

struct EvaluationCaseImportRow: Identifiable, Sendable {
    var id = UUID()
    var sourceLine: Int
    var name: String
    var prompt: String
    var expected: String
}

struct EvaluationCaseImportIssue: Identifiable, Equatable, Sendable {
    var id: String { "\(line ?? 0):\(message)" }
    var line: Int?
    var message: String
}

struct EvaluationCaseImportPreview: Sendable {
    var columns: [String]
    var rows: [EvaluationCaseImportRow]
    var issues: [EvaluationCaseImportIssue]
    var totalValidRowCount: Int

    var canImport: Bool { totalValidRowCount > 0 && issues.isEmpty }
}

enum EvaluationCaseImporter {
    static func columns(in data: Data, format: EvaluationCaseImportFormat) throws -> [String] {
        try validateFileSize(data)
        switch format {
        case .csv:
            let rows = try csvRows(data, stopAfterRows: 1)
            guard let header = rows.first else { throw EvaluationCaseImportError.emptyFile }
            return try validatedColumns(header.fields)
        case .jsonLines:
            let records = try jsonLineRecords(data, maximumRecords: EvaluationStore.maximumCases)
            guard !records.isEmpty else { throw EvaluationCaseImportError.emptyFile }
            return records.reduce(into: Set<String>()) { columns, record in
                columns.formUnion(record.object.keys)
            }.sorted()
        }
    }

    static func preview(
        data: Data,
        format: EvaluationCaseImportFormat,
        mapping: EvaluationCaseImportMapping,
        limit: Int = 20
    ) throws -> EvaluationCaseImportPreview {
        try validateFileSize(data)
        switch format {
        case .csv:
            return try csvPreview(
                data: data,
                mapping: mapping,
                limit: limit,
                maximumCases: EvaluationStore.maximumCases
            )
        case .jsonLines:
            return try jsonLinesPreview(
                data: data,
                mapping: mapping,
                limit: limit,
                maximumCases: EvaluationStore.maximumCases
            )
        }
    }

    static func cases(
        data: Data,
        format: EvaluationCaseImportFormat,
        mapping: EvaluationCaseImportMapping,
        maximumCases: Int
    ) throws -> [EvaluationCase] {
        try validateFileSize(data)
        let preview: EvaluationCaseImportPreview
        switch format {
        case .csv:
            preview = try csvPreview(
                data: data,
                mapping: mapping,
                limit: maximumCases,
                maximumCases: EvaluationStore.maximumCases
            )
        case .jsonLines:
            preview = try jsonLinesPreview(
                data: data,
                mapping: mapping,
                limit: maximumCases,
                maximumCases: EvaluationStore.maximumCases
            )
        }
        guard preview.issues.isEmpty else { throw EvaluationCaseImportError.validation(preview.issues) }
        return preview.rows.map {
            EvaluationCase(name: $0.name, prompt: $0.prompt, expected: $0.expected)
        }
    }

    private static func csvPreview(
        data: Data,
        mapping: EvaluationCaseImportMapping,
        limit: Int,
        maximumCases: Int
    ) throws -> EvaluationCaseImportPreview {
        let parsed = try csvRows(data, maximumDataRows: maximumCases)
        guard let header = parsed.first else { throw EvaluationCaseImportError.emptyFile }
        let columns = try validatedColumns(header.fields)
        try validate(mapping: mapping, columns: columns)
        var rows: [EvaluationCaseImportRow] = []
        var issues: [EvaluationCaseImportIssue] = []
        var totalValidRowCount = 0
        for row in parsed.dropFirst() {
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            guard row.fields.count == columns.count else {
                issues.append(.init(line: row.line, message: "Expected \(columns.count) columns but found \(row.fields.count)."))
                continue
            }
            let object = Dictionary(uniqueKeysWithValues: zip(columns, row.fields))
            append(
                object: object, line: row.line, mapping: mapping, rows: &rows, issues: &issues,
                limit: limit, totalValidRowCount: &totalValidRowCount
            )
        }
        return EvaluationCaseImportPreview(
            columns: columns, rows: rows, issues: issues, totalValidRowCount: totalValidRowCount
        )
    }

    private static func jsonLinesPreview(
        data: Data,
        mapping: EvaluationCaseImportMapping,
        limit: Int,
        maximumCases: Int
    ) throws -> EvaluationCaseImportPreview {
        let records = try jsonLineRecords(data, maximumRecords: maximumCases)
        let columns = records.reduce(into: Set<String>()) { $0.formUnion($1.object.keys) }.sorted()
        try validate(mapping: mapping, columns: columns)
        var rows: [EvaluationCaseImportRow] = []
        var issues: [EvaluationCaseImportIssue] = []
        var totalValidRowCount = 0
        for record in records {
            var object: [String: String] = [:]
            for (key, value) in record.object {
                if let value = value as? String {
                    object[key] = value
                } else if value is NSNull {
                    object[key] = ""
                } else {
                    issues.append(.init(line: record.line, message: "Column '\(key)' must be a string or null."))
                }
            }
            append(
                object: object, line: record.line, mapping: mapping, rows: &rows, issues: &issues,
                limit: limit, totalValidRowCount: &totalValidRowCount
            )
        }
        return EvaluationCaseImportPreview(
            columns: columns, rows: rows, issues: issues, totalValidRowCount: totalValidRowCount
        )
    }

    private static func append(
        object: [String: String],
        line: Int,
        mapping: EvaluationCaseImportMapping,
        rows: inout [EvaluationCaseImportRow],
        issues: inout [EvaluationCaseImportIssue],
        limit: Int,
        totalValidRowCount: inout Int
    ) {
        let prompt = object[mapping.promptColumn] ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(.init(line: line, message: "The mapped prompt value is empty."))
            return
        }
        guard prompt.count <= EvaluationStore.maximumFieldCharacters else {
            issues.append(.init(line: line, message: "The prompt exceeds \(EvaluationStore.maximumFieldCharacters) characters."))
            return
        }
        let importedName = mapping.nameColumn.flatMap { object[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = importedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Imported case \(line)"
        let expected = mapping.expectedColumn.flatMap { object[$0] } ?? ""
        guard expected.count <= EvaluationStore.maximumFieldCharacters else {
            issues.append(.init(line: line, message: "The expected answer exceeds \(EvaluationStore.maximumFieldCharacters) characters."))
            return
        }
        totalValidRowCount += 1
        if rows.count < limit {
            rows.append(.init(sourceLine: line, name: name, prompt: prompt, expected: expected))
        }
    }

    private static func validate(mapping: EvaluationCaseImportMapping, columns: [String]) throws {
        guard columns.contains(mapping.promptColumn) else {
            throw EvaluationCaseImportError.missingColumn(mapping.promptColumn)
        }
        if let name = mapping.nameColumn, !columns.contains(name) {
            throw EvaluationCaseImportError.missingColumn(name)
        }
        if let expected = mapping.expectedColumn, !columns.contains(expected) {
            throw EvaluationCaseImportError.missingColumn(expected)
        }
    }

    private static func validateFileSize(_ data: Data) throws {
        guard data.count <= EvaluationStore.maximumTextFileBytes else {
            throw EvaluationCaseImportError.fileTooLarge(maximumBytes: EvaluationStore.maximumTextFileBytes)
        }
    }

    private static func validatedColumns(_ columns: [String]) throws -> [String] {
        let trimmed = columns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isEmpty }) else {
            throw EvaluationCaseImportError.invalidHeader
        }
        guard Set(trimmed).count == trimmed.count else { throw EvaluationCaseImportError.duplicateColumns }
        return trimmed
    }

    private struct CSVRow {
        var line: Int
        var fields: [String]

        var isBlank: Bool {
            fields.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private static func csvRows(
        _ data: Data,
        maximumDataRows: Int? = nil,
        stopAfterRows: Int? = nil
    ) throws -> [CSVRow] {
        let text = try utf8Text(data)
        var rows: [CSVRow] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var line = 1
        var rowStart = 1
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)
                    if isRecordNewline(character) { line += 1 }
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    quoted = true
                case ",":
                    fields.append(field)
                    field = ""
                case "\n", "\r\n", "\r":
                    fields.append(field)
                    let row = CSVRow(line: rowStart, fields: fields)
                    if try appendCSVRow(
                        row, to: &rows,
                        maximumDataRows: maximumDataRows, stopAfterRows: stopAfterRows
                    ) { return rows }
                    fields = []
                    field = ""
                    line += 1
                    rowStart = line
                default:
                    field.append(character)
                }
            }
            index = next
        }
        guard !quoted else { throw EvaluationCaseImportError.unterminatedQuote(line: rowStart) }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            _ = try appendCSVRow(
                CSVRow(line: rowStart, fields: fields), to: &rows,
                maximumDataRows: maximumDataRows, stopAfterRows: stopAfterRows
            )
        }
        return rows
    }

    private static func appendCSVRow(
        _ row: CSVRow,
        to rows: inout [CSVRow],
        maximumDataRows: Int?,
        stopAfterRows: Int?
    ) throws -> Bool {
        if !rows.isEmpty, row.isBlank { return false }
        rows.append(row)
        if let maximumDataRows, rows.count > maximumDataRows + 1 {
            throw EvaluationCaseImportError.tooManyRows(maximum: maximumDataRows)
        }
        return stopAfterRows.map { rows.count >= $0 } ?? false
    }

    private struct JSONLineRecord {
        var line: Int
        var object: [String: Any]
    }

    private static func jsonLineRecords(_ data: Data, maximumRecords: Int) throws -> [JSONLineRecord] {
        let text = try utf8Text(data)
        var records: [JSONLineRecord] = []
        var lineNumber = 1
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(where: isRecordNewline)
            let end = newline ?? text.endIndex
            let line = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                guard records.count < maximumRecords else {
                    throw EvaluationCaseImportError.tooManyRows(maximum: maximumRecords)
                }
                guard let lineData = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    throw EvaluationCaseImportError.invalidJSONLine(line: lineNumber)
                }
                records.append(JSONLineRecord(line: lineNumber, object: object))
            }
            guard let newline else { break }
            start = text.index(after: newline)
            lineNumber += 1
        }
        return records
    }

    // Swift treats CRLF as one extended grapheme cluster, so testing only
    // Character("\n") misses Windows record separators.
    private static func isRecordNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    private static func utf8Text(_ data: Data) throws -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            throw EvaluationCaseImportError.notUTF8
        }
        if text.first == "\u{FEFF}" {
            text.removeFirst()
        }
        return text
    }
}

enum EvaluationCaseImportError: LocalizedError, Sendable {
    case emptyFile
    case notUTF8
    case invalidHeader
    case duplicateColumns
    case unterminatedQuote(line: Int)
    case invalidJSONLine(line: Int)
    case missingColumn(String)
    case validation([EvaluationCaseImportIssue])
    case tooManyRows(maximum: Int)
    case fileTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .emptyFile: "The import file has no records."
        case .notUTF8: "Case import files must use UTF-8 encoding."
        case .invalidHeader: "CSV headers must be non-empty."
        case .duplicateColumns: "CSV headers must be unique."
        case .unterminatedQuote(let line): "CSV line \(line) has an unterminated quoted field."
        case .invalidJSONLine(let line): "JSONL line \(line) is not a JSON object."
        case .missingColumn(let name): "The mapped column '\(name)' does not exist."
        case .validation(let issues): issues.first?.message ?? "The imported cases are invalid."
        case .tooManyRows(let maximum): "Import at most \(maximum) cases at a time."
        case .fileTooLarge(let maximumBytes): "Case import files must be \(maximumBytes) bytes or smaller."
        }
    }
}
