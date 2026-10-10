#if os(macOS)
import Foundation
@testable import IntentsAutomationCore
import IntentsAutomationDateCodec

enum AutomationFileExecutionFixture {
    static let bytes = Data("private-file-content".utf8)
    static func export(root: URL, scope: AutomationScope, app: AppIdentity, hostPath: String, tamper: Bool) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = try AutomationIntentFileMetadata(filename: "sample.txt", typeIdentifier: "public.plain-text", data: bytes)
        let file = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
        let receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": Int32.max, "startIdentity": "100:0", "executablePath": hostPath + "/Contents/MacOS/OwnedHost-Runner"],
            "runID": scope.runId, "attemptID": scope.attemptId, "segmentID": scope.segmentId, "leaseGeneration": scope.leaseGeneration,
            "bundleID": app.bundleID, "productDigest": app.productDigest!, "productDigestVersion": app.productDigestVersion ?? 1, "complete": true,
            "operations": [["operationID": "probe", "dispatched": true, "value": ["kind": "intentFile", "value": "intents-file-probe", "file": file]]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: root.appendingPathComponent("receipt.json"))
        try (tamper ? Data("foreign".utf8) : bytes).write(to: root.appendingPathComponent("file.bin"))
        let entries = [("receipt.json", "intents-system-receipt"), ("file.bin", "intents-file-probe")].map { file, name in
            ["exportedFileName": file, "suggestedHumanReadableName": name, "isAssociatedWithFailure": false,
             "configurationName": "Debug", "deviceName": "fixture", "deviceId": "owned"] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: [["testIdentifier": "SegmentTests/testSegment()", "attachments": entries]])
            .write(to: root.appendingPathComponent("manifest.json"))
    }
}
#endif
