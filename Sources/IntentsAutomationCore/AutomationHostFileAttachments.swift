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
/// This strict file path is separate from legacy JSON-only import; qualification
/// must establish the actual runner's test identifier and export naming convention.
enum AutomationHostFileAttachments {
    struct Imported: Sendable { let receiptData: Data; let receipt: AutomationImportedHostReceipt }
    static func importExport(root: URL, scope: AutomationScope, app: AppIdentity, program: AutomationHostProgram,
                             artifacts: AutomationArtifactRegistry, planDigest: String, testIdentifier: String = "SegmentTests/testSegment()") async throws -> Imported {
        let entries = try exportEntries(root: root, testIdentifier: testIdentifier)
        guard let finalName = entries["intents-system-receipt"] else { throw invalid() }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: finalName, maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard let receiptRoot = try JSONDecoder().decode(AutomationJSON.self, from: data).object,
              case .array(let operations) = receiptRoot["operations"], operations.count == program.operations.count else { throw invalid() }
        var claims: [String: (AutomationHostFileDescriptor, Data)] = [:], placeholders: [String: AutomationValue] = [:]
        var allowedNames: Set<String> = ["intents-system-receipt"]
        for (expected, operation) in zip(program.operations, operations) {
            allowedNames.formUnion(["intents-dispatch-" + expected.id, "intents-system-receipt-" + expected.id])
            if expected.resultCodec == "intentFile" {
                guard let value = operation.object?["value"] else { throw invalid() }
                let descriptor = try AutomationHostFileDescriptor(value, operationID: expected.id)
                guard let exportedName = entries[descriptor.attachmentName] else { throw invalid() }
                let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: exportedName, maximumBytes: 8192, requirePrivateOwnership: true)
                try descriptor.metadata.verify(bytes)
                claims[expected.id] = (descriptor, bytes); allowedNames.insert(descriptor.attachmentName)
                placeholders[expected.id] = .artifact(handle: "validated-file", sha256: descriptor.metadata.sha256)
            }
        }
        guard Set(entries.keys).isSubset(of: allowedNames) else { throw invalid() }
        // Validate the complete receipt and every declared binary before persisting any file artifact.
        _ = try AutomationHostReceiptImporter.importValidatedReceipt(data, scope: scope, app: app, program: program, fileValues: placeholders)
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
        return .init(receiptData: data, receipt: try AutomationHostReceiptImporter.importValidatedReceipt(data, scope: scope, app: app, program: program, fileValues: fileValues))
    }
    static func exportEntries(root: URL, testIdentifier: String) throws -> [String: String] {
        let manifestData = try AutomationReadOnlyFile.read(root: root, relativePath: "manifest.json", maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard case .array(let records) = try JSONDecoder().decode(AutomationJSON.self, from: manifestData), records.count == 1,
              let record = records.first?.object, Set(record.keys).isSubset(of: ["testIdentifier", "testIdentifierURL", "attachments"]),
              record["testIdentifier"] == .string(testIdentifier), case .array(let attachments) = record["attachments"],
              !attachments.isEmpty, attachments.count <= 100 else { throw invalid() }
        if let url = record["testIdentifierURL"] { guard case .string(let text) = url, text.utf8.count <= 4096 else { throw invalid() } }
        let required: Set<String> = ["exportedFileName", "suggestedHumanReadableName", "isAssociatedWithFailure", "configurationName", "deviceName", "deviceId"]
        let optional: Set<String> = ["timestamp", "repetitionNumber", "arguments"]
        var exported = Set<String>(), names = Set<String>(), entries: [String: String] = [:], context: [AutomationJSON]?
        for attachment in attachments {
            guard let fields = attachment.object, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional)),
                  case .string(let filename) = fields["exportedFileName"], safeBasename(filename), filename != "manifest.json",
                  case .string(let name) = fields["suggestedHumanReadableName"], name.utf8.count <= 512,
                  fields["isAssociatedWithFailure"] == .bool(false), exported.insert(filename).inserted, names.insert(name).inserted else { throw invalid() }
            let identity = try ["configurationName", "deviceName", "deviceId"].map { key -> AutomationJSON in
                guard case .string(let value) = fields[key], !value.isEmpty, value.utf8.count <= 512 else { throw invalid() }
                return .string(value)
            }
            if let context { guard context == identity else { throw invalid() } } else { context = identity }
            if let timestamp = fields["timestamp"] { guard case .number(let value) = timestamp, value.isFinite else { throw invalid() } }
            if let repetition = fields["repetitionNumber"] { guard case .number(let value) = repetition, value == 1 else { throw invalid() } }
            if let arguments = fields["arguments"] { guard case .array(let values) = arguments, values.isEmpty else { throw invalid() } }
            entries[name] = filename
        }
        let actual = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard Set(actual.map(\.lastPathComponent)) == exported.union(["manifest.json"]), actual.count == exported.count + 1 else { throw invalid() }
        return entries
    }
    private static func safeBasename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\u{0}")
    }
    private static func invalid() -> AutomationContractError { .missingEvidence("No unique bounded file attachment for the exact host receipt") }
}
