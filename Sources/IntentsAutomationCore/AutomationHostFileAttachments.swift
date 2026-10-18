import Foundation
import IntentsAutomationDateCodec

struct AutomationHostFileDescriptor {
    let attachmentName: String
    let metadata: AutomationIntentFileMetadata
    init(_ value: AutomationJSON, operationID: String) throws {
        guard let fields = value.object, Set(fields.keys) == ["kind", "value", "file"], fields["kind"] == .string("intentFile"),
              fields["value"] == .string("intents-file-" + operationID), let file = fields["file"]?.object,
              Set(file.keys).subtracting(["typeIdentifier"]) == ["filename", "byteCount", "sha256"] else { throw AutomationContractError.invalidIdentity }
        metadata = try JSONDecoder().decode(AutomationIntentFileMetadata.self, from: JSONEncoder().encode(AutomationJSON.object(file)))
        try metadata.validate(); attachmentName = "intents-file-" + operationID
    }
}

/// The installed xcresulttool export schema is retained under IntentFileDeclarations.
/// Exported display names include an attachment repetition and UUID suffix.
/// Only correlated receipt/file attachments become claims; XCTest recordings remain unclaimed.
enum AutomationHostFileAttachments {
    struct Imported: Sendable { let receiptData: Data; let receipt: AutomationImportedHostReceipt }
    static func importExport(root: URL, scope: AutomationScope, app: AppIdentity, program: AutomationHostProgram,
                             artifacts: AutomationArtifactRegistry, planDigest: String, testIdentifier: String = "SegmentTests/testSegment()", allowTerminalFailure: Bool = false) async throws -> Imported {
        var allowedNames: Set<String> = ["intents-system-receipt"]
        for operation in program.operations {
            allowedNames.formUnion(["intents-dispatch-" + operation.id, "intents-system-receipt-" + operation.id])
            if operation.resultCodec == "intentFile" { allowedNames.insert("intents-file-" + operation.id) }
        }
        let entries = try exportEntries(root: root, testIdentifier: testIdentifier, expectedNames: allowedNames)
        guard let finalName = entries["intents-system-receipt"] else { throw invalid() }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: finalName, maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard let receiptRoot = try JSONDecoder().decode(AutomationJSON.self, from: data).object,
              case .array(let operations) = receiptRoot["operations"], !operations.isEmpty,
              operations.count <= program.operations.count else { throw invalid() }
        var claims: [String: (AutomationHostFileDescriptor, Data)] = [:], placeholders: [String: AutomationValue] = [:]
        for (expected, operation) in zip(program.operations, operations) {
            if expected.resultCodec == "intentFile" {
                if allowTerminalFailure, case .string = operation.object?["error"] { continue }
                guard let value = operation.object?["value"] else { throw invalid() }
                let descriptor = try AutomationHostFileDescriptor(value, operationID: expected.id)
                guard let exportedName = entries[descriptor.attachmentName] else { throw invalid() }
                let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: exportedName, maximumBytes: 8192, requirePrivateOwnership: true)
                try descriptor.metadata.verify(bytes)
                claims[expected.id] = (descriptor, bytes)
                placeholders[expected.id] = .artifact(handle: "validated-file", sha256: descriptor.metadata.sha256)
            }
        }
        guard Set(entries.keys).isSubset(of: allowedNames),
              Set(entries.keys.filter { $0.hasPrefix("intents-file-") }) == Set(claims.keys.map { "intents-file-" + $0 }) else { throw invalid() }
        // Validate the complete receipt and every declared binary before persisting any file artifact.
        _ = try AutomationHostReceiptImporter.importValidatedReceipt(data, scope: scope, app: app, program: program, fileValues: placeholders, allowTerminalFailure: allowTerminalFailure)
        for (name, filename) in entries where name != "intents-system-receipt" && !name.hasPrefix("intents-file-") {
            let progress = try AutomationReadOnlyFile.read(root: root, relativePath: filename, maximumBytes: 1_048_576, requirePrivateOwnership: true)
            let json = try JSONDecoder().decode(AutomationJSON.self, from: progress)
            guard json.object != nil, json.object?["complete"] != .bool(true) else { throw invalid() }
        }
        var fileValues: [String: AutomationValue] = [:]
        for operation in program.operations {
            if let (descriptor, bytes) = claims[operation.id] {
                let artifact = try await artifacts.storeNativeEvidence(data: bytes, scope: scope, metadata: descriptor.metadata,
                    provenance: .init(planDigest: planDigest, operationID: operation.id, receiptDigest: AutomationArtifactRegistry.digest(data)))
                fileValues[operation.id] = .artifact(handle: artifact.handle, sha256: artifact.sha256)
            }
        }
        return .init(receiptData: data, receipt: try AutomationHostReceiptImporter.importValidatedReceipt(data, scope: scope, app: app, program: program, fileValues: fileValues, allowTerminalFailure: allowTerminalFailure))
    }
    static func exportEntries(root: URL, testIdentifier: String, expectedNames: Set<String>) throws -> [String: String] {
        let manifestData = try AutomationReadOnlyFile.read(root: root, relativePath: "manifest.json", maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard case .array(let records) = try JSONDecoder().decode(AutomationJSON.self, from: manifestData), records.count == 1,
              let record = records.first?.object, Set(record.keys).isSubset(of: ["testIdentifier", "testIdentifierURL", "attachments"]),
              record["testIdentifier"] == .string(testIdentifier), case .array(let attachments) = record["attachments"],
              !attachments.isEmpty, attachments.count <= 100 else { throw invalid() }
        if let url = record["testIdentifierURL"] { guard case .string(let text) = url, text.utf8.count <= 4096 else { throw invalid() } }
        let required: Set<String> = ["exportedFileName", "suggestedHumanReadableName", "isAssociatedWithFailure", "configurationName", "deviceName", "deviceId"]
        let optional: Set<String> = ["timestamp", "repetitionNumber", "arguments"]
        let diagnosticNames = Set((1...3).map { "intents-fixture-registration-\($0)" })
        var exported = Set<String>(), names = Set<String>(), entries: [String: String] = [:], context: [AutomationJSON]?
        for attachment in attachments {
            guard let fields = attachment.object, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional)),
                  case .string(let filename) = fields["exportedFileName"], safeBasename(filename), filename != "manifest.json",
                  case .string(let name) = fields["suggestedHumanReadableName"], name.utf8.count <= 512,
                  fields["isAssociatedWithFailure"] == .bool(false), exported.insert(filename).inserted else { throw invalid() }
            let identity = try ["configurationName", "deviceName", "deviceId"].map { key -> AutomationJSON in
                guard case .string(let value) = fields[key], !value.isEmpty, value.utf8.count <= 512 else { throw invalid() }
                return .string(value)
            }
            if let context { guard context == identity else { throw invalid() } } else { context = identity }
            if let timestamp = fields["timestamp"] { guard case .number(let value) = timestamp, value.isFinite else { throw invalid() } }
            if let repetition = fields["repetitionNumber"] { guard case .number(let value) = repetition, value == 1 else { throw invalid() } }
            if let arguments = fields["arguments"] { guard case .array(let values) = arguments, values.isEmpty else { throw invalid() } }
            // XCTest adds its own video beside the attachments added by our host. It is
            // retained in the export inventory, but never imported as receipt or file data.
            if name.hasPrefix("Screen Recording "), name.hasSuffix(".mp4"), filename.hasSuffix(".mp4") { continue }
            let logicalName = try attachmentName(name, expectedNames: expectedNames.union(diagnosticNames))
            guard names.insert(logicalName).inserted else { throw invalid() }
            // Fixture readiness diagnostics stay in the checked export inventory, never in claims.
            if diagnosticNames.contains(logicalName) { continue }
            entries[logicalName] = filename
        }
        let actual = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard Set(actual.map(\.lastPathComponent)) == exported.union(["manifest.json"]), actual.count == exported.count + 1 else { throw invalid() }
        return entries
    }
    private static func attachmentName(_ exportedName: String, expectedNames: Set<String>) throws -> String {
        var candidates: Set<String> = [exportedName]
        let suffix = #"_0_[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}(?=\.[A-Za-z0-9_:-]+\z)"#
        if let range = exportedName.range(of: suffix, options: .regularExpression) {
            let stem = String(exportedName[..<range.lowerBound])
            // XCTest preserves an existing extension in the attachment name (file.echo),
            // or adds the content type extension when the original name had none.
            candidates.insert(stem)
            candidates.insert(stem + exportedName[range.upperBound...])
        }
        let matches = candidates.intersection(expectedNames)
        guard matches.count == 1, let name = matches.first else { throw invalid() }
        return name
    }
    private static func safeBasename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\u{0}")
    }
    private static func invalid() -> AutomationContractError { .missingEvidence("No unique bounded file attachment for the exact host receipt") }
}
