import Foundation
import PDFKit

enum EvaluationDocumentImporter {
    static let maximumBytes = 5_000_000
    static let maximumCharacters = 128_000
    static let maximumPages = 200
    static let passageCharacters = 2_200

    /// Read a bounded PDF, Markdown, or UTF-8 text selection under scoped access and retain source anchors.
    static func importFile(at url: URL, selection: ClosedRange<Int>? = nil) throws -> EvaluationDocumentSource {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try EvaluationAttachmentStorage.readCaseImportFile(at: url, maximumBytes: maximumBytes)
        let kind = url.pathExtension.lowercased()
        guard ["pdf", "md", "markdown", "txt", "text"].contains(kind) else {
            throw EvaluationStoreError.invalidSuite("Choose a text-based PDF, UTF-8 Markdown, or text file.")
        }
        var source = EvaluationDocumentSource(name: String(url.lastPathComponent.prefix(255)),
            fileDigest: EvaluationDocumentEvidence.digest(data), passages: [])
        if kind == "pdf" {
            guard let document = PDFDocument(data: data), !document.isEncrypted, !document.isLocked else {
                throw EvaluationStoreError.invalidSuite("This PDF is locked or unreadable. Export an unlocked text-based copy.")
            }
            let range = selection ?? 1...max(1, document.pageCount)
            guard range.lowerBound >= 1, range.upperBound <= document.pageCount,
                  range.count <= maximumPages else {
                throw EvaluationStoreError.invalidSuite("This PDF has \(document.pageCount) pages. Select a valid range of at most \(maximumPages) pages.")
            }
            for page in range {
                try Task.checkCancellation()
                let text = normalize(document.page(at: page - 1)?.string ?? "")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    source.warnings.append("Page \(page) has no usable text and was omitted. OCR is not supported.")
                    continue
                }
                guard text.count <= maximumCharacters else { throw tooMuchText() }
                try append(text: text, location: "Page \(page)", prefix: "page-\(page)", to: &source)
                try checkSize(source)
            }
            source.warnings.append("PDF extraction may change reading order or omit diagrams and tables. Check the text before accepting questions.")
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw EvaluationStoreError.invalidSuite("This file is not UTF-8. Save a UTF-8 copy and import it again.")
            }
            let blocks = normalize(decoded).components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let range = selection ?? 1...max(1, blocks.count)
            guard !blocks.isEmpty, range.lowerBound >= 1, range.upperBound <= blocks.count else {
                throw EvaluationStoreError.invalidSuite("Choose a valid passage range within this document's \(blocks.count) text blocks.")
            }
            var heading = "Text"
            for (index, block) in blocks.enumerated() {
                try Task.checkCancellation()
                if ["md", "markdown"].contains(kind), let first = block.split(separator: "\n").first, first.hasPrefix("#") {
                    heading = String(first.drop(while: { $0 == "#" || $0 == " " }).prefix(180))
                }
                guard range.contains(index + 1) else { continue }
                try append(text: block, location: "\(heading) · passage \(index + 1)", prefix: "text-\(index + 1)", to: &source)
                try checkSize(source)
            }
        }
        guard !source.passages.isEmpty else { throw EvaluationStoreError.invalidSuite("The selection has no usable text. Choose another range or a text-based document.") }
        return source
    }

    /// Normalize line endings and Unicode composition before splitting or matching source text.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    /// Split text into bounded source passages while retaining a stable location and passage identifier.
    private static func append(text: String, location: String, prefix: String, to source: inout EvaluationDocumentSource) throws {
        try Task.checkCancellation()
        let retained = source.passages.reduce(0) { $0 + $1.text.count }
        guard text.count <= maximumCharacters - retained else { throw tooMuchText() }
        // Swift Character boundaries preserve Unicode; citations use exact normalized substrings, not persisted String.Index values.
        var remaining = text[...]
        var part = 1
        while !remaining.isEmpty {
            try Task.checkCancellation()
            guard source.passages.count < 512 else { throw tooMuchText() }
            var end = remaining.index(remaining.startIndex, offsetBy: passageCharacters, limitedBy: remaining.endIndex) ?? remaining.endIndex
            if end != remaining.endIndex {
                let prefix = remaining[..<end]
                let boundary = prefix.lastIndex(of: "\n") ?? prefix.lastIndex(where: \.isWhitespace)
                if let boundary, remaining.distance(from: remaining.startIndex, to: boundary) >= passageCharacters / 2 {
                    end = remaining.index(after: boundary)
                }
            }
            let content = String(remaining[..<end])
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                source.passages.append(.init(id: "\(prefix)-\(part)", location: String(location.prefix(255)), text: content))
            }
            remaining = remaining[end...]
            part += 1
        }
        if part > 2, !source.warnings.contains("Long sections were split into passages. Include neighboring passages when definitions or exceptions cross a boundary.") {
            source.warnings.append("Long sections were split into passages. Include neighboring passages when definitions or exceptions cross a boundary.")
        }
    }

    /// Reject imported sources whose passage count or raw text exceeds the published limits.
    private static func checkSize(_ source: EvaluationDocumentSource) throws {
        guard source.passages.count <= 512, source.passages.reduce(0, { $0 + $1.text.count }) <= maximumCharacters else { throw tooMuchText() }
    }

    /// Create the actionable error used when an imported selection exceeds its supported text limits.
    private static func tooMuchText() -> EvaluationStoreError {
        .invalidSuite("The selection exceeds 128,000 characters or 512 passages. Import a smaller page/passage range; no truncated document was saved.")
    }
}
