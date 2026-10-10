#if os(macOS)
import Foundation
import Darwin

/// Validation evidence only. This unit supplies neither Node nor an executable Intents route.
public enum AutomationPrivateMacSDKUnit {
    public struct Evidence: Codable, Equatable, Sendable {
        public let artifactVariant: String
        public let receiptSHA256: String
        public let helperSHA256: String
        public let fileCount: Int
        public let customerRuntimeEnabled: Bool
        public let hardwareQualified: Bool
        public let developerIDSigned: Bool
    }
    struct Receipt: Codable {
        var schemaVersion: Int
        var artifactVariant: String
        var customerRuntimeEnabled: Bool
        var hardwareQualified: Bool
        var developerIDSigned: Bool
        var helperInvoked: Bool
        var sourceRevision: String
        var officialArchiveSHA256: String
        var sdkInventorySHA256: String
        var helperCheckpointSHA256: String
        var helperRelativePath: String
        var requiredHelperEnvironment: String
        var files: [String: String]
    }
    static let receiptName = "intents-private-runtime.json"
    static let pinnedReceiptSHA256 = "9fda71ac61b4d2428e4a08f6a9afb4ad363bd8fb20b8bc3dc10f03cc8f608bb3"
    static let helperPath = "helpers/agent-device-macos-helper"
    private static let metadataKeys: Set<String> = ["schemaVersion", "artifactVariant", "customerRuntimeEnabled",
        "hardwareQualified", "developerIDSigned", "helperInvoked", "sourceRevision", "officialArchiveSHA256",
        "sdkInventorySHA256", "helperCheckpointSHA256", "helperRelativePath", "requiredHelperEnvironment", "files"]

    public static func verify(root: URL) throws -> Evidence {
        try verify(root: root, expectedReceiptSHA256: pinnedReceiptSHA256)
    }
    // Internal seam for synthetic fixtures; the public loader accepts only the frozen receipt.
    static func verify(root: URL, expectedReceiptSHA256: String) throws -> Evidence {
        guard root.isFileURL, try AutomationPath.canonical(root).path == root.path,
              expectedReceiptSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        let bytes = try read(root, receiptName, maximumBytes: 1_048_576)
        guard AutomationArtifactRegistry.digest(bytes) == expectedReceiptSHA256,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == metadataKeys else { throw AutomationContractError.invalidIdentity }
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.schemaVersion == 1, receipt.artifactVariant == "private-owned-mac-source",
              !receipt.customerRuntimeEnabled, !receipt.hardwareQualified, !receipt.developerIDSigned, !receipt.helperInvoked,
              receipt.sourceRevision == "35f407e6e9352544847732d3b8aa74b7b3d34d51",
              receipt.officialArchiveSHA256 == "2dadf033c359810e0623479206048c6d4696874d1cf6aa03f1b0090a531b2e48",
              receipt.sdkInventorySHA256 == "872fd17f3a397e7b058813dd1ed2132e18834a47733c880acb6cfeb88dc56105",
              receipt.helperCheckpointSHA256 == "2ec8bc561a0d36802ee9a1a99849d3e0d6c000aba7132178d92294a5ac8debd4",
              receipt.helperRelativePath == helperPath, receipt.requiredHelperEnvironment == "AGENT_DEVICE_MACOS_HELPER_BIN",
              receipt.files.count == 472,
              [helperPath, "agent-device/package.json", "agent-device/bin/agent-device.mjs", "agent-device/LICENSE",
               "agent-device/intents-private-lifecycle-patch.json", "agent-device/dist/src/index.js"].allSatisfy({ receipt.files[$0] != nil }) else {
            throw AutomationContractError.invalidIdentity
        }
        for (relative, digest) in receipt.files {
            guard validRelativePath(relative), relative != receiptName,
                  relative == helperPath || relative.hasPrefix("agent-device/"),
                  digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw AutomationContractError.invalidIdentity
            }
        }
        let expected = Set(receipt.files.keys).union([receiptName])
        guard try inventory(root) == expected else { throw AutomationContractError.invalidIdentity }
        var total = 0
        for (relative, digest) in receipt.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let data = try read(root, relative, maximumBytes: 16_777_216)
            total += data.count
            guard total <= 134_217_728, AutomationArtifactRegistry.digest(data) == digest else {
                throw AutomationContractError.conflictingOperation
            }
        }
        guard try inventory(root) == expected, try read(root, receiptName, maximumBytes: 1_048_576) == bytes else {
            throw AutomationContractError.conflictingOperation
        }
        return .init(artifactVariant: receipt.artifactVariant, receiptSHA256: expectedReceiptSHA256,
            helperSHA256: receipt.files[helperPath]!, fileCount: receipt.files.count,
            customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
    }
    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\0") && !path.contains("\\") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    private static func read(_ root: URL, _ relative: String, maximumBytes: Int) throws -> Data {
        try AutomationReadOnlyFile.read(root: root, relativePath: relative,
            maximumBytes: maximumBytes, requirePrivateOwnership: true)
    }
    private static func inventory(_ root: URL) throws -> Set<String> {
        var failed = false
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
            errorHandler: { _, _ in failed = true; return false }) else { throw AutomationContractError.invalidIdentity }
        var files = Set<String>(), entries = 0
        for case let url as URL in iterator {
            entries += 1
            guard entries <= 2048, iterator.level <= 32, url.path.hasPrefix(root.path + "/") else {
                throw AutomationContractError.invalidIdentity
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw AutomationContractError.invalidIdentity
            }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AutomationContractError.invalidIdentity }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard validRelativePath(relative), files.insert(relative).inserted else { throw AutomationContractError.invalidIdentity }
        }
        guard !failed else { throw AutomationContractError.invalidIdentity }
        return files
    }
}
#endif
