import Foundation
import Testing
@testable import FoundationEvals

struct CaseImportBoundedReadTests {
    private let maximumBytes = EvaluationStore.maximumTextFileBytes

    @Test func exactlyAtLimitSucceeds() throws {
        let body = Data(repeating: 0x61, count: maximumBytes)
        let url = try temporaryFile(data: body)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try EvaluationAttachmentStorage.readCaseImportFile(
            at: url,
            maximumBytes: maximumBytes
        )

        #expect(result == body)
    }

    @Test func metadataOverLimitFailsBeforeReturningBody() throws {
        let url = try temporaryFile(data: Data(repeating: 0x61, count: maximumBytes + 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var error: EvaluationCaseImportError?
        do {
            _ = try EvaluationAttachmentStorage.readCaseImportFile(at: url, maximumBytes: maximumBytes)
            Issue.record("Expected the over-limit case file to be rejected.")
        } catch let caught as EvaluationCaseImportError {
            error = caught
        } catch let caught {
            Issue.record("Expected EvaluationCaseImportError, got \(caught).")
        }
        #expect(error?.errorDescription == "Case import files must be 5000000 bytes or smaller.")
    }

    @Test func streamingGrowthFailsWhenMetadataLies() {
        let streamedByteCount = maximumBytes + 1
        var emitted = 0

        #expect(throws: EvaluationCaseImportError.self) {
            _ = try EvaluationAttachmentStorage.readBoundedData(
                reportedByteCount: maximumBytes,
                maximumBytes: maximumBytes,
                tooLargeError: { EvaluationCaseImportError.fileTooLarge(maximumBytes: maximumBytes) },
                readChunk: { requested in
                    guard emitted < streamedByteCount else { return nil }
                    let count = min(requested, streamedByteCount - emitted)
                    emitted += count
                    return Data(repeating: 0x61, count: count)
                }
            )
        }
        #expect(emitted == streamedByteCount)
    }

    private func temporaryFile(data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaseImportBoundedReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cases.csv")
        try data.write(to: url)
        return url
    }
}
