import Foundation
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Attachment preparation extracted from the app store. Storage remains the host's responsibility.
@available(macOS 27.0, *)
enum AppEngineReferenceImporter {
    struct Request: Decodable { var fileURL: URL; var name: String; var mimeType: String }
    struct Output: Encodable {
        var attachment: EvaluationAttachment
        var truncated: Bool
        var text: String? { attachment.text }
        var kind: String { attachment.kind.rawValue }
        var byteCount: Int { attachment.byteCount }
        var sha256: String { attachment.sha256 }
        enum CodingKeys: String, CodingKey { case attachment, truncated, text, kind, byteCount, sha256 }
        /// Encodes the attachment and import metadata, omitting the extracted text field when no text exists.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(attachment, forKey: .attachment)
            try values.encode(truncated, forKey: .truncated)
            try values.encodeIfPresent(text, forKey: .text)
            try values.encode(kind, forKey: .kind)
            try values.encode(byteCount, forKey: .byteCount)
            try values.encode(sha256, forKey: .sha256)
        }
    }
    /// Reads a regular local file within the 10 MB reference limit and prepares its attachment metadata.
    /// Throws for invalid URLs, oversized or growing files, read failures, or unsupported contents; file storage remains the host’s responsibility.
    static func extract(_ request: Request) throws -> Output {
        guard request.fileURL.isFileURL else { throw RunnerFailure.validation("Reference must be a local file URL.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: request.fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= AppEngineValidation.maximumImageBytes else {
            throw RunnerFailure.validation("Reference must be a regular file of at most 10,000,000 bytes.")
        }
        let handle = try FileHandle(forReadingFrom: request.fileURL)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= AppEngineValidation.maximumImageBytes else { throw RunnerFailure.validation("Reference grew beyond the file size limit.") }
        }
        return try prepare(id: UUID(), name: request.name, mediaType: request.mimeType, data: data)
    }
    /// Validates a basename and declared media category, hashes the original bytes, and prepares image metadata or extracted text.
    /// Throws for type mismatches, unreadable contents, or size limits; text exceeding 16,000 characters is truncated and marked.
    static func prepare(
        id: UUID,
        name: String,
        mediaType: String,
        data: Data
    ) throws -> Output {
        let basename = (name as NSString).lastPathComponent
        guard !basename.isEmpty, basename == name, !name.contains("\\") else {
            throw ImportFailure.invalidFilename
        }
        guard let declaredType = UTType(mimeType: mediaType) else {
            throw ImportFailure.unsupportedType
        }
        let filenameType = UTType(filenameExtension: (name as NSString).pathExtension)
        let isImage = declaredType.conforms(to: .image)
        let isPDF = declaredType.conforms(to: .pdf)
        let isText = declaredType.conforms(to: .text)
            || declaredType.conforms(to: .json)
            || declaredType.conforms(to: .commaSeparatedText)
        guard isImage || isPDF || isText else { throw ImportFailure.unsupportedType }

        if let filenameType {
            let filenameCategoryMatches = (isImage && filenameType.conforms(to: .image))
                || (isPDF && filenameType.conforms(to: .pdf))
                || (isText && (filenameType.conforms(to: .text)
                    || filenameType.conforms(to: .json)
                    || filenameType.conforms(to: .commaSeparatedText)))
            guard filenameCategoryMatches else { throw ImportFailure.typeMismatch }
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if isImage {
            guard data.count <= AppEngineValidation.maximumImageBytes else { throw ImportFailure.imageTooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ImportFailure.unreadableImage
            }
            let fileExtension = declaredType.preferredFilenameExtension
                ?? (name as NSString).pathExtension.lowercased()
            let storedFilename = "\(id.uuidString).\(fileExtension)"
            return Output(
                attachment: EvaluationAttachment(
                    id: id,
                    name: name,
                    kind: .image,
                    text: nil,
                    storedFilename: storedFilename,
                    byteCount: data.count,
                    sha256: digest
                ),
                truncated: false
            )
        }

        guard data.count <= AppEngineValidation.maximumTextFileBytes else { throw ImportFailure.fileTooLarge }
        let text: String
        if isPDF {
            guard let document = PDFDocument(data: data),
                  let extracted = document.string,
                  !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportFailure.unreadablePDF
            }
            text = extracted
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { throw ImportFailure.notUTF8 }
            text = decoded
        }
        let truncated = text.count > AppEngineValidation.maximumExtractedTextCharacters
        return Output(
            attachment: EvaluationAttachment(
                id: id,
                name: name,
                kind: .text,
                text: truncated
                    ? String(text.prefix(AppEngineValidation.maximumExtractedTextCharacters)) + "\n[File truncated during import.]"
                    : text,
                storedFilename: nil,
                byteCount: data.count,
                sha256: digest
            ),
            truncated: truncated
        )
    }

    enum ImportFailure: String, LocalizedError {
        case invalidFilename, unsupportedType, typeMismatch, imageTooLarge, unreadableImage
        case fileTooLarge, unreadablePDF, notUTF8
        var errorDescription: String? { "Reference import failed: \(rawValue)." }
    }
}
