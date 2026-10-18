import Foundation
import Testing
@testable import FoundationEvals

struct AttachmentStorageDirectorySafetyTests {
    @Test func symlinkedAttachmentsDirectoryCannotAliasRunEvidence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.removeItem(at: fixture.attachments)
        try FileManager.default.createSymbolicLink(
            at: fixture.attachments,
            withDestinationURL: fixture.runEvidence
        )

        #expect(throws: EvaluationStoreError.self) {
            _ = try EvaluationAttachmentStorage.validatedStorageDirectory(fixture.attachments)
        }
        #expect(throws: EvaluationStoreError.self) {
            _ = try EvaluationAttachmentStorage.storedFileURL(
                filename: fixture.filename,
                attachmentID: fixture.attachmentID,
                in: fixture.attachments
            )
        }
        #expect(try Data(contentsOf: fixture.sentinel) == fixture.sentinelData)
    }

    @Test func nonDirectoryAttachmentsEntryIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.removeItem(at: fixture.attachments)
        try Data("not a directory".utf8).write(to: fixture.attachments)

        #expect(throws: EvaluationStoreError.self) {
            _ = try EvaluationAttachmentStorage.validatedStorageDirectory(fixture.attachments)
        }
        #expect(throws: EvaluationStoreError.self) {
            _ = try EvaluationAttachmentStorage.storedFileURL(
                filename: fixture.filename,
                attachmentID: fixture.attachmentID,
                in: fixture.attachments
            )
        }
    }

    private struct Fixture {
        let root: URL
        let attachments: URL
        let runEvidence: URL
        let sentinel: URL
        let sentinelData: Data
        let attachmentID: UUID

        var filename: String {
            "\(attachmentID.uuidString).png"
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AttachmentStorageDirectorySafetyTests-\(UUID().uuidString)")
        let attachments = root.appending(path: "Attachments")
        let runEvidence = root.appending(path: "RunEvidence")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runEvidence, withIntermediateDirectories: true)

        let sentinel = runEvidence.appending(path: "sentinel.bin")
        let sentinelData = Data("Run evidence must remain untouched.".utf8)
        try sentinelData.write(to: sentinel)

        return Fixture(
            root: root,
            attachments: attachments,
            runEvidence: runEvidence,
            sentinel: sentinel,
            sentinelData: sentinelData,
            attachmentID: UUID()
        )
    }
}
