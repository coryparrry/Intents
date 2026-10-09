#if os(macOS)
import Foundation
import Darwin

/// Evidence for a separately frozen development runtime. Public verification
/// never enables the customer route or accepts a caller-selected receipt.
public enum AutomationPrivateMacDaemonUnit {
    public struct Evidence: Codable, Equatable, Sendable {
        public let receiptSHA256: String
        public let checkpointSHA256: String
        public let fileCount: Int
        public let customerRuntimeEnabled: Bool
        public let hardwareQualified: Bool
        public let developerIDSigned: Bool
    }
    static let pinnedReceiptSHA256 = "0dbd9f8b9a83181d94cbbe47103c1b55daeb147c211994ce3b0d571f7e5c8aaf"
    static let pinnedProgramReceiptSHA256 = "44e1c9e8282104212da918a393539d1d8a7d8e66e73c711a7ae88076716590e0"
    static let pinnedFillProgramReceiptSHA256 = "9efc31cf525273c2727a01fde61f7870e01d9e0a6fe060fb2522ee035b733a7f"
    static let pinnedV2ProgramReceiptSHA256 = "631f7d60b4f56a76f145533dd278f1752f2b3e91b2903e6b6767f06c3930deb8"
    static let pinnedSecretProgramReceiptSHA256 = "80fe19fb94080790458f39dc81ca199dabd32d99f0befe323c4ea0040de0c592"
    static let pinnedPolicyDiagnosticsProgramReceiptSHA256 = "5ff1f0e74f8474882340e5f68c3dfc2b1abc8882f4224df365c990818438f354"
    static func programDigestVersion(receiptSHA256: String) -> AutomationUIPayloadDigestVersion? {
        switch receiptSHA256 {
        case pinnedV2ProgramReceiptSHA256, pinnedSecretProgramReceiptSHA256, pinnedPolicyDiagnosticsProgramReceiptSHA256: return .lexicalV2
        case pinnedReceiptSHA256, pinnedProgramReceiptSHA256, pinnedFillProgramReceiptSHA256: return .legacyV1
        default: return nil
        }
    }
    static func programInputCapabilities(receiptSHA256: String) -> AutomationMacInputCapabilities? {
        switch receiptSHA256 {
        case pinnedProgramReceiptSHA256: return .tapOnly
        case pinnedFillProgramReceiptSHA256, pinnedV2ProgramReceiptSHA256, pinnedSecretProgramReceiptSHA256, pinnedPolicyDiagnosticsProgramReceiptSHA256: return .ordinaryFillAndScroll
        default: return nil
        }
    }
    static let receiptName = "intents-native-daemon-runtime.json"
    struct Loaded: Sendable {
        let evidence: Evidence
        let root: URL
        let node: URL
        let entry: URL
        let helper: URL
        var secretProgramEntry: URL? {
            [AutomationPrivateMacDaemonUnit.pinnedSecretProgramReceiptSHA256, AutomationPrivateMacDaemonUnit.pinnedPolicyDiagnosticsProgramReceiptSHA256].contains(evidence.receiptSHA256) ? root.appendingPathComponent("sidecar/src/secretProgramMain.js") : nil
        }
        var programDigestVersion: AutomationUIPayloadDigestVersion { AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: evidence.receiptSHA256) ?? .legacyV1 }
        var inputCapabilities: AutomationMacInputCapabilities { programInputCapabilities(receiptSHA256: evidence.receiptSHA256) ?? .tapOnly }
    }
    private struct Receipt: Decodable {
        let schemaVersion: Int
        let artifactVariant: String
        let customerRuntimeEnabled: Bool
        let hardwareQualified: Bool
        let developerIDSigned: Bool
        let checkpointSHA256: String
        let entryRelativePath: String
        let nodeRelativePath: String
        let helperRelativePath: String
        let enclosingApplicationVerified: Bool
        let privateEntryExecuted: Bool
        let files: [String: String]
    }
    private static let keys: Set<String> = ["schemaVersion", "artifactVariant", "customerRuntimeEnabled",
        "hardwareQualified", "developerIDSigned", "checkpointSHA256", "entryRelativePath", "nodeRelativePath",
        "helperRelativePath", "enclosingApplicationVerified", "privateEntryExecuted", "files"]
    public static func verify(root: URL) throws -> Evidence { try load(root: root).evidence }
    static func load(root: URL) throws -> Loaded {
        let selected = AutomationArtifactRegistry.digest(try read(root, receiptName, limit: 8_388_608))
        guard [pinnedReceiptSHA256, pinnedProgramReceiptSHA256, pinnedFillProgramReceiptSHA256, pinnedV2ProgramReceiptSHA256, pinnedSecretProgramReceiptSHA256, pinnedPolicyDiagnosticsProgramReceiptSHA256].contains(selected) else { throw AutomationContractError.conflictingOperation }
        return try load(root: root, expectedReceiptSHA256: selected)
    }
    // Internal fixture seam. Shipping callers can only use the frozen digests above.
    static func load(root: URL, expectedReceiptSHA256: String) throws -> Loaded {
        guard root.isFileURL, try AutomationPath.canonical(root).path == root.path,
              digest(expectedReceiptSHA256) else { throw AutomationContractError.invalidIdentity }
        let bytes = try read(root, receiptName, limit: 8_388_608)
        guard AutomationArtifactRegistry.digest(bytes) == expectedReceiptSHA256,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == keys else { throw AutomationContractError.invalidIdentity }
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.schemaVersion == 1, receipt.artifactVariant == "private-owned-mac-daemon-integration",
              !receipt.customerRuntimeEnabled, !receipt.hardwareQualified, !receipt.developerIDSigned,
              !receipt.enclosingApplicationVerified, !receipt.privateEntryExecuted, digest(receipt.checkpointSHA256),
              receipt.entryRelativePath == "sidecar/src/macOwnedDaemonMain.js", receipt.nodeRelativePath == "node",
              receipt.helperRelativePath == "helpers/agent-device-macos-helper",
              (1...20_000).contains(receipt.files.count),
              [receipt.entryRelativePath, receipt.nodeRelativePath, receipt.helperRelativePath,
               "sdk/dist/src/intents-daemon.js", "intents-native-daemon-stage.json", "package-lock.json",
               "dependencies.lock.json"].allSatisfy({ receipt.files[$0] != nil }) else { throw AutomationContractError.invalidIdentity }
        for (name, hash) in receipt.files {
            guard relative(name), name != receiptName, digest(hash) else { throw AutomationContractError.invalidIdentity }
        }
        let expected = Set(receipt.files.keys).union([receiptName])
        guard try inventory(root) == expected else { throw AutomationContractError.invalidIdentity }
        var total = 0
        for (name, hash) in receipt.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let data = try read(root, name, limit: 134_217_728); total += data.count
            guard total <= 1_073_741_824, AutomationArtifactRegistry.digest(data) == hash else { throw AutomationContractError.conflictingOperation }
        }
        guard try inventory(root) == expected, try read(root, receiptName, limit: 8_388_608) == bytes else { throw AutomationContractError.conflictingOperation }
        for name in [receipt.nodeRelativePath, receipt.helperRelativePath] {
            guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(name).path) else { throw AutomationContractError.invalidIdentity }
        }
        if expectedReceiptSHA256 == pinnedFillProgramReceiptSHA256 {
            guard receipt.files[receipt.helperRelativePath] == AutomationMacNativeHelperBridge.privateFillHelperSHA256,
                  receipt.checkpointSHA256 == "67d9447037c980891bb31ff4c856deecd5650fb794ddf7cd859ef4118e52df6e" else { throw AutomationContractError.conflictingOperation }
        }
        if expectedReceiptSHA256 == pinnedV2ProgramReceiptSHA256 {
            guard receipt.files[receipt.helperRelativePath] == AutomationMacNativeHelperBridge.privateFillHelperSHA256,
                  receipt.checkpointSHA256 == "ac3976b29f533cbf5804c1a96a029a2ee3f3b4d79a004c7829c1d26d16e54fb0",
                  ["sidecar/src/ownRecord.js", "sidecar/src/payloadDigest.js", "sidecar/src/secretFillProgram.js"].allSatisfy({ receipt.files[$0] != nil }) else { throw AutomationContractError.conflictingOperation }
        }
        if expectedReceiptSHA256 == pinnedSecretProgramReceiptSHA256 {
            guard receipt.files[receipt.helperRelativePath] == AutomationMacNativeHelperBridge.privateFillHelperSHA256,
                  receipt.checkpointSHA256 == "fe54cb48a7c88811da6f830b0cad2aa876ea56b76d350ef85bc40f37c5c25652",
                  ["sidecar/src/secretProgramMain.js", "sidecar/src/secretProgramController.js", "sidecar/src/secretFillProgram.js", "sidecar/src/ownRecord.js", "sidecar/src/payloadDigest.js"].allSatisfy({ receipt.files[$0] != nil }) else { throw AutomationContractError.conflictingOperation }
        }
        if expectedReceiptSHA256 == pinnedPolicyDiagnosticsProgramReceiptSHA256 {
            guard receipt.files[receipt.helperRelativePath] == AutomationMacNativeHelperBridge.privateFillHelperSHA256,
                  receipt.checkpointSHA256 == "867b2d1ffad2eda87739fc42609f1a7ab8c2676bbf106939ed97b40b2f9ea528",
                  ["sidecar/src/policyReview.js", "sidecar/src/secretProgramMain.js", "sidecar/src/secretProgramController.js", "sidecar/src/secretFillProgram.js", "sidecar/src/ownRecord.js", "sidecar/src/payloadDigest.js"].allSatisfy({ receipt.files[$0] != nil }) else { throw AutomationContractError.conflictingOperation }
        }
        return .init(evidence: .init(receiptSHA256: expectedReceiptSHA256, checkpointSHA256: receipt.checkpointSHA256,
            fileCount: receipt.files.count, customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false),
            root: root, node: root.appendingPathComponent(receipt.nodeRelativePath), entry: root.appendingPathComponent(receipt.entryRelativePath),
            helper: root.appendingPathComponent(receipt.helperRelativePath))
    }
    private static func digest(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    private static func relative(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\0") && !value.contains("\\") &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    }
    private static func read(_ root: URL, _ name: String, limit: Int) throws -> Data {
        try AutomationReadOnlyFile.read(root: root, relativePath: name, maximumBytes: limit, requirePrivateOwnership: true)
    }
    private static func inventory(_ root: URL) throws -> Set<String> {
        var failed = false
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
            errorHandler: { _, _ in failed = true; return false }) else { throw AutomationContractError.invalidIdentity }
        var files = Set<String>(), count = 0
        for case let file as URL in iterator {
            count += 1
            guard count <= 40_000, iterator.level <= 32, file.path.hasPrefix(root.path + "/") else { throw AutomationContractError.invalidIdentity }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw AutomationContractError.invalidIdentity }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AutomationContractError.invalidIdentity }
            let name = String(file.path.dropFirst(root.path.count + 1))
            guard relative(name), files.insert(name).inserted else { throw AutomationContractError.invalidIdentity }
        }
        guard !failed else { throw AutomationContractError.invalidIdentity }
        return files
    }
}
#endif
