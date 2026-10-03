import CryptoKit
import XCTest

enum EvidenceAttachmentWriter {
    static func attach(_ envelope: IntentLabEvidenceEnvelope, to testCase: XCTestCase, checkpoint: Bool = false) throws {
        let data = try JSONEncoder.intentLab.encode(envelope)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        let stage = checkpoint ? "checkpoint" : "final"
        attachment.name = "IntentLabEvidence-\(envelope.invocation.id.uuidString)-\(stage).json"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    static func attachScreenshot(to testCase: XCTestCase) -> IntentLabArtifactReference {
        let id = UUID()
        let filename = "IntentLabArtifact-\(id.uuidString).png"
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = filename
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        return .init(
            id: id,
            kind: "screenshot",
            filename: filename,
            relativePath: filename,
            contentType: "image/png",
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            manuallySupplied: false
        )
    }
}
