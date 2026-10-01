import AppKit
import CoreText
import PDFKit
import Testing
@testable import FoundationEvals

@MainActor
struct AttachmentImportTests {
    @Test(arguments: ["txt", "json", "csv"])
    func utf8ReferencesPreserveContentAcrossRelaunch(ext: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let texts = ["txt": "Café 東京\nReference ✓", "json": "{\"city\":\"東京\",\"count\":2}", "csv": "city,count\nLondon,2\n"]
        let types = ["txt": "text/plain", "json": "application/json", "csv": "text/csv"]
        let text = try #require(texts[ext])
        let result = try await upload(store, name: "reference.\(ext)", type: try #require(types[ext]), data: Data(text.utf8))
        #expect(result.attachment.kind == .text)
        #expect(result.attachment.text == text)
        #expect(!result.truncated)
        let restored = EvaluationStore(supportDirectory: directory)
        #expect(restored.suite.attachments == store.suite.attachments)
        #expect(try restored.attachmentData(id: result.attachment.id).data == Data(text.utf8))
    }

    @Test func extractsRealPDFAndPersistsRealImageBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let pdf = try pdfData(text: "Reference order A104 is delivered.")
        let importedPDF = try await upload(store, name: "reference.pdf", type: "application/pdf", data: pdf)
        #expect(importedPDF.attachment.text?.contains("A104 is delivered") == true)
        #expect(try store.attachmentData(id: importedPDF.attachment.id).data == Data(try #require(importedPDF.attachment.text).utf8))
        let png = try imageData()
        let image = try await upload(store, name: "reference.png", type: "image/png", data: png)
        #expect(image.attachment.kind == .image)
        #expect(image.attachment.text == nil)
        #expect(image.attachment.storedFilename != nil)
        let restored = EvaluationStore(supportDirectory: directory)
        #expect(restored.suite.attachments == store.suite.attachments)
        #expect(try restored.attachmentData(id: image.attachment.id).data == png)
    }

    @Test func malformedAndUnsupportedReferencesLeaveStoreUnchanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let fixtures: [(String, String, Data)] = [
            ("bad.txt", "text/plain", Data([0xFF, 0xFE, 0x80])),
            ("bad.png", "image/png", Data("not an image".utf8)),
            ("bad.pdf", "application/pdf", Data("not a PDF".utf8)),
            ("empty.pdf", "application/pdf", try pdfData(text: nil)),
            ("archive.zip", "application/zip", Data([0x50, 0x4B])),
            ("mismatch.png", "text/plain", Data("text".utf8))
        ]
        let revision = store.suiteRevision
        for (name, type, data) in fixtures {
            await expectRejected(store, name: name, type: type, data: data)
            #expect(store.suite.attachments.isEmpty)
            #expect(store.suiteRevision == revision)
        }
        #expect(EvaluationStore(supportDirectory: directory).suite.attachments.isEmpty)
    }

    @Test func filePickerBatchFailureIsAtomicAndNextBatchSucceeds() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory.appending(path: "store"))
        let imageURL = directory.appending(path: "good.png")
        let textURL = directory.appending(path: "good.txt")
        let badURL = directory.appending(path: "bad.txt")
        try imageData().write(to: imageURL)
        try Data("batch reference".utf8).write(to: textURL)
        try Data([0xFF]).write(to: badURL)
        store.importFiles([imageURL, textURL, badURL])
        try await waitForImport(store)
        #expect(store.notice?.contains("Could not import") == true)
        #expect(store.suite.attachments.isEmpty)
        let attachmentDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory.appending(path: "store"),
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "Attachments")
        #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentDirectory.path).isEmpty)
        store.notice = nil
        store.importFiles([imageURL, textURL])
        try await waitForImport(store)
        #expect(store.notice == nil)
        #expect(Set(store.suite.attachments.map(\.name)) == ["good.png", "good.txt"])
        #expect(EvaluationStore(supportDirectory: directory.appending(path: "store")).suite.attachments.count == 2)
    }

    @Test func filePickerRejectsRemoteURLsAndDirectoriesBeforeReading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory.appending(path: "store"))

        store.importFiles([try #require(URL(string: "https://example.invalid/reference.txt"))])
        try await waitForImport(store)
        #expect(store.notice?.contains("regular local files") == true)
        #expect(store.suite.attachments.isEmpty)

        let folder = directory.appending(path: "folder.txt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.notice = nil
        store.importFiles([folder])
        try await waitForImport(store)
        #expect(store.notice?.contains("regular local files") == true)
        #expect(store.suite.attachments.isEmpty)
    }

    @Test func persistedAttachmentFilenamesCannotEscapeTheirPrivateDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let imported = try await upload(
            store,
            name: "reference.png",
            type: "image/png",
            data: try imageData()
        )
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let outsideURL = suiteDirectory.appending(path: "outside.png")
        let outsideData = try imageData()
        try outsideData.write(to: outsideURL)

        var poisoned = store.suite
        poisoned.attachments[0].storedFilename = "../outside.png"
        try CanonicalJSON.data(for: poisoned).write(
            to: suiteDirectory.appending(path: "suite.json"),
            options: .atomic
        )
        let restored = EvaluationStore(supportDirectory: directory)

        #expect(throws: EvaluationStoreError.self) {
            _ = try restored.attachmentData(id: imported.attachment.id)
        }
        #expect(throws: EvaluationStoreError.self) {
            _ = try restored.removeAttachment(
                id: imported.attachment.id,
                expectedRevision: restored.suiteRevision
            )
        }
        #expect(try Data(contentsOf: outsideURL) == outsideData)
        #expect(restored.suite.attachments.map(\.id) == [imported.attachment.id])
    }

    @Test func persistedAttachmentCannotAliasAnotherAttachmentsStoredFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let first = try await upload(
            store, name: "first.png", type: "image/png", data: try imageData()
        )
        let second = try await upload(
            store, name: "second.png", type: "image/png", data: try imageData()
        )
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let attachmentsDirectory = suiteDirectory.appending(path: "Attachments")
        let secondFilename = try #require(second.attachment.storedFilename)
        let secondURL = attachmentsDirectory.appending(path: secondFilename)

        var poisoned = store.suite
        poisoned.attachments[0].storedFilename = secondFilename
        try CanonicalJSON.data(for: poisoned).write(
            to: suiteDirectory.appending(path: "suite.json"),
            options: .atomic
        )
        let restored = EvaluationStore(supportDirectory: directory)

        #expect(throws: EvaluationStoreError.self) {
            _ = try restored.attachmentData(id: first.attachment.id)
        }
        #expect(throws: EvaluationStoreError.self) {
            _ = try restored.removeAttachment(
                id: first.attachment.id,
                expectedRevision: restored.suiteRevision
            )
        }
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        let expectedData = try imageData()
        #expect(try restored.attachmentData(id: second.attachment.id).data == expectedData)
        #expect(restored.suite.attachments.map(\.id) == [first.attachment.id, second.attachment.id])
    }

    @Test func corruptStoredAttachmentFailsReadsAndDuplicateRetriesClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = try imageData()
        let id = UUID()
        let imported = try await store.importAttachment(
            id: id, name: "evidence.png", mediaType: "image/png", data: original,
            expectedRevision: store.suiteRevision
        )
        let storedFilename = try #require(imported.attachment.storedFilename)
        let storedURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "Attachments/\(storedFilename)")
        try Data("corrupt replacement".utf8).write(to: storedURL, options: .atomic)

        #expect(throws: EvaluationStoreError.self) {
            _ = try store.attachmentData(id: id)
        }
        await #expect(throws: EvaluationStoreError.self) {
            _ = try await store.importAttachment(
                id: id, name: "evidence.png", mediaType: "image/png", data: original,
                expectedRevision: store.suiteRevision
            )
        }
    }

    @Test func corruptInlineTextProjectionFailsDuplicateRetryClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let imported = try await upload(
            store, name: "reference.txt", type: "text/plain", data: Data("trusted text".utf8)
        )
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        var poisoned = store.suite
        poisoned.attachments[0].text = "poisoned projection"
        try CanonicalJSON.data(for: poisoned).write(
            to: suiteDirectory.appending(path: "suite.json"), options: .atomic
        )
        let restored = EvaluationStore(supportDirectory: directory)

        await #expect(throws: EvaluationStoreError.self) {
            _ = try await restored.importAttachment(
                id: imported.attachment.id,
                name: "reference.txt",
                mediaType: "text/plain",
                data: Data("trusted text".utf8),
                expectedRevision: restored.suiteRevision
            )
        }
    }

    @Test func oversizedReplacementImageFailsBeforeUnboundedBuffering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let imported = try await upload(
            store, name: "replacement.png", type: "image/png", data: try imageData()
        )
        let filename = try #require(imported.attachment.storedFilename)
        let storedURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "Attachments/\(filename)")
        try Data(repeating: 0x41, count: EvaluationStore.maximumImageBytes + 1)
            .write(to: storedURL, options: .atomic)

        #expect(throws: EvaluationStoreError.self) {
            _ = try store.attachmentData(id: imported.attachment.id)
        }
    }

    @Test func catalogFailureRollsBackAttachmentMetadataAndPrivateBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalSuite = store.suite
        let originalWorkspace = store.workspace
        let suiteURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "suite.json")
        let originalSuiteData = try Data(contentsOf: suiteURL)
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        await #expect(throws: EvaluationStoreError.self) {
            _ = try await store.importAttachment(
                id: UUID(), name: "evidence.png", mediaType: "image/png",
                data: try imageData(), expectedRevision: store.suiteRevision
            )
        }

        #expect(store.suite == originalSuite)
        #expect(store.workspace == originalWorkspace)
        #expect(try Data(contentsOf: suiteURL) == originalSuiteData)
        let attachmentsURL = suiteURL.deletingLastPathComponent().appending(path: "Attachments")
        #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentsURL.path).isEmpty)
    }

    @Test func textByteBoundaryAndCharacterTruncationAreEnforced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let limitText = String(repeating: "é", count: 16_000)
        let exact = try await upload(store, name: "exact.txt", type: "text/plain", data: Data(limitText.utf8))
        #expect(!exact.truncated)
        #expect(exact.attachment.text == limitText)
        let truncated = try await upload(store, name: "long.txt", type: "text/plain", data: Data((limitText + "X").utf8))
        #expect(truncated.truncated)
        #expect(truncated.attachment.text == limitText + "\n[File truncated during import.]")
        #expect(try store.attachmentData(id: truncated.attachment.id).data == Data(try #require(truncated.attachment.text).utf8))
        let boundary = try await upload(store, name: "boundary.txt", type: "text/plain", data: Data(repeating: 65, count: 5_000_000))
        #expect(boundary.attachment.byteCount == 5_000_000)
        #expect(boundary.truncated)
        await expectRejected(store, name: "large.txt", type: "text/plain", data: Data(repeating: 65, count: 5_000_001))
        #expect(store.suite.attachments.count == 3)
        #expect(EvaluationStore(supportDirectory: directory).suite.attachments == store.suite.attachments)
    }

    @Test func imageByteBoundaryAndFourImageLimitAreEnforced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let png = try imageData()
        var boundary = png
        boundary.append(Data(repeating: 0, count: 10_000_000 - png.count))
        let result = try await upload(store, name: "boundary.png", type: "image/png", data: boundary)
        #expect(try store.attachmentData(id: result.attachment.id).data == boundary)
        boundary.append(0)
        await expectRejected(store, name: "large.png", type: "image/png", data: boundary)
        for index in 2...4 {
            _ = try await upload(store, name: "image\(index).png", type: "image/png", data: png)
        }
        await expectRejected(store, name: "fifth.png", type: "image/png", data: png)
        #expect(store.suite.attachments.count == 4)
        #expect(EvaluationStore(supportDirectory: directory).suite.attachments.count == 4)
    }

    @Test func removingLastImageExplainsHowToDisableImageTools() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let imported = try await upload(
            store,
            name: "reference.png",
            type: "image/png",
            data: try imageData()
        )
        var configured = store.suite
        configured.modelConfiguration.customization = EvaluationModelCustomization(
            visionTools: EvaluationVisionToolConfiguration(ocrEnabled: true)
        )
        let configuredRevision = try store.replaceSuite(
            configured,
            expectedRevision: store.suiteRevision,
            confirmDeletes: false
        )

        do {
            _ = try store.removeAttachment(
                id: imported.attachment.id,
                expectedRevision: configuredRevision
            )
            Issue.record("Expected the last image removal to be rejected while OCR is enabled.")
        } catch let error as EvaluationStoreError {
            #expect(
                error.localizedDescription
                    == "Turn off OCR and barcode tools in Model before removing the last image."
            )
        }
        #expect(store.suite.attachments.map(\.id) == [imported.attachment.id])
    }

    @Test func twentiethAttachmentSucceedsAndTwentyFirstIsAtomic() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        for index in 1...20 {
            _ = try await upload(store, name: "reference\(index).txt", type: "text/plain", data: Data("Reference \(index)".utf8))
        }
        let revision = store.suiteRevision
        await expectRejected(store, name: "overflow.txt", type: "text/plain", data: Data("overflow".utf8))
        #expect(store.suite.attachments.count == 20)
        #expect(store.suiteRevision == revision)
        #expect(EvaluationStore(supportDirectory: directory).suite.attachments.count == 20)
    }

    private func upload(_ store: EvaluationStore, name: String, type: String, data: Data) async throws -> EvaluationAttachmentImportResult {
        try await store.importAttachment(id: UUID(), name: name, mediaType: type, data: data, expectedRevision: store.suiteRevision)
    }

    private func expectRejected(_ store: EvaluationStore, name: String, type: String, data: Data) async {
        do {
            _ = try await upload(store, name: name, type: type, data: data)
            Issue.record("Unexpectedly imported invalid fixture: \(name)")
        } catch {}
    }

    private func waitForImport(_ store: EvaluationStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isProcessingFiles, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isProcessingFiles, "File import did not complete within ten seconds.")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AttachmentImportTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func imageData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func pdfData(text: String?) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        return try #require(document.dataRepresentation())
    }
}
