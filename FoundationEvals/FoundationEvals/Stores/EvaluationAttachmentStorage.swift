import Foundation

enum EvaluationAttachmentStorage {
    /// Reads a regular local attachment within maximumBytes, selecting image or file size errors from isImage.
    /// Checks reported size before opening and bounds the stream to detect a file that grows during reading.
    nonisolated static func readImportFile(
        at url: URL,
        isImage: Bool,
        maximumBytes: Int
    ) throws -> Data {
        try readImportFile(at: url, maximumBytes: maximumBytes) {
            isImage ? ImportError.imageTooLarge : ImportError.fileTooLarge
        }
    }

    /// Reads a regular local case-import file within maximumBytes, reporting the case-import size error on overflow.
    nonisolated static func readCaseImportFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try readImportFile(at: url, maximumBytes: maximumBytes) {
            EvaluationCaseImportError.fileTooLarge(maximumBytes: maximumBytes)
        }
    }

    /// Validates local-file metadata before a bounded read, using tooLargeError for invalid or excessive sizes.
    /// Closes the handle after reading and propagates metadata, open, and read failures.
    private nonisolated static func readImportFile(
        at url: URL,
        maximumBytes: Int,
        tooLargeError: @escaping () -> any Error
    ) throws -> Data {
        guard url.isFileURL else { throw ImportError.notRegularLocalFile }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ImportError.notRegularLocalFile
        }
        guard let byteCount = values.fileSize else {
            throw ImportError.unknownFileSize
        }
        guard maximumBytes >= 0, byteCount >= 0, byteCount <= maximumBytes else {
            throw tooLargeError()
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readBoundedData(
            reportedByteCount: byteCount,
            maximumBytes: maximumBytes,
            tooLargeError: tooLargeError,
            readChunk: { try handle.read(upToCount: $0) }
        )
    }

    /// Reads chunks of at most 64 KiB, allowing one overflow-detection byte beyond the limit when representable.
    /// Rejects negative or excessive sizes, oversized returned chunks, and data beyond maximumBytes using tooLargeError.
    /// Returns bytes read until EOF; reportedByteCount is a capacity hint and early limit check, not an exact-length guarantee.
    nonisolated static func readBoundedData(
        reportedByteCount: Int,
        maximumBytes: Int,
        tooLargeError: @escaping () -> any Error,
        readChunk: (Int) throws -> Data?
    ) throws -> Data {
        guard maximumBytes >= 0, reportedByteCount >= 0 else {
            throw tooLargeError()
        }
        guard reportedByteCount <= maximumBytes else {
            throw tooLargeError()
        }

        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(reportedByteCount, maximumBytes))
        while data.count < readLimit {
            let remaining = readLimit - data.count
            let requested = min(remaining, 64 * 1_024)
            guard requested > 0,
                  let chunk = try readChunk(requested),
                  !chunk.isEmpty else { break }
            guard chunk.count <= requested else {
                throw tooLargeError()
            }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw tooLargeError()
        }
        return data
    }

    /// Returns a standardized storage directory only when it exists as a directory and is not itself a symlink.
    /// Wraps inaccessible or invalid directory metadata as a persistence error.
    nonisolated static func validatedStorageDirectory(_ directory: URL) throws -> URL {
        let standardizedDirectory = directory.standardizedFileURL
        do {
            let values = try standardizedDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw EvaluationStoreError.persistence(
                    "Attachment storage directory is missing, not a directory, or a symbolic link."
                )
            }
        } catch let error as EvaluationStoreError {
            throw error
        } catch {
            throw EvaluationStoreError.persistence(
                "Attachment storage directory could not be accessed."
            )
        }
        return standardizedDirectory
    }

    /// Validates an attachment-ID filename and returns a direct child of the private storage directory.
    /// Rejects path components, control characters, symlinks, resolved escapes, and existing nonregular files.
    /// The returned path may be absent so callers can stage a new stored attachment.
    nonisolated static func storedFileURL(
        filename: String,
        attachmentID: UUID,
        in directory: URL
    ) throws -> URL {
        let storedIdentity = UUID(uuidString: (filename as NSString).deletingPathExtension)
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              storedIdentity == attachmentID,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              (filename as NSString).lastPathComponent == filename else {
            throw EvaluationStoreError.persistence("Attachment storage contains an invalid filename.")
        }

        let standardizedDirectory = try validatedStorageDirectory(directory)
        let canonicalDirectory = standardizedDirectory.resolvingSymlinksInPath()
        let candidate = standardizedDirectory
            .appending(path: filename, directoryHint: .notDirectory)
            .standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard candidate.deletingLastPathComponent().path == standardizedDirectory.path,
              canonicalCandidate.deletingLastPathComponent().path == canonicalDirectory.path,
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw EvaluationStoreError.persistence("Attachment storage points outside its private directory.")
        }
        if fileManager.fileExists(atPath: candidate.path),
           try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
            throw EvaluationStoreError.persistence("Attachment storage is not a regular file.")
        }
        return candidate
    }
}

enum ImportError: LocalizedError {
    case tooManyFiles
    case tooManyImages
    case imageTooLarge
    case fileTooLarge
    case unknownFileSize
    case notRegularLocalFile
    case invalidFilename
    case unsupportedType
    case typeMismatch
    case unreadableImage
    case unreadablePDF
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .tooManyFiles: "A suite can attach up to 20 files."
        case .tooManyImages: "A suite can attach up to four images."
        case .imageTooLarge: "Images must be 10 MB or smaller."
        case .fileTooLarge: "Text and PDF files must be 5 MB or smaller."
        case .unknownFileSize: "The selected file size could not be determined."
        case .notRegularLocalFile: "Only regular local files can be imported."
        case .invalidFilename: "Attachment names must be plain filenames without path components."
        case .unsupportedType: "Attachments must be UTF-8 text, JSON, CSV, PDF, or an image."
        case .typeMismatch: "The declared media type does not match the filename extension."
        case .unreadableImage: "The image data could not be decoded."
        case .unreadablePDF: "The PDF contains no extractable text."
        case .notUTF8: "Text files must use UTF-8 encoding."
        }
    }
}
