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
        let attachmentDirectory = directory.appending(path: "store/Attachments")
        #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentDirectory.path).isEmpty)
        store.notice = nil
        store.importFiles([imageURL, textURL])
        try await waitForImport(store)
        #expect(store.notice == nil)
        #expect(Set(store.suite.attachments.map(\.name)) == ["good.png", "good.txt"])
        #expect(EvaluationStore(supportDirectory: directory.appending(path: "store")).suite.attachments.count == 2)
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
