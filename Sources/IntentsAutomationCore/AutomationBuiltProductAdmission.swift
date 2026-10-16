import Foundation

/// Packaging failures are preparation gaps even when compilation succeeded.
/// Inspection never changes an extension's identity or fills in customer metadata.
enum AutomationBuiltProductAdmission {
    static func validateEmbeddedExtensions(bundle: URL, macOS: Bool) throws {
        let root = try AutomationPath.canonical(bundle)
        let relative = macOS ? "Contents/PlugIns" : "PlugIns"
        let plugins = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: plugins.path) else { return }
        guard try AutomationPath.canonical(plugins).path == plugins.path else { throw AutomationContractError.invalidIdentity }
        let extensions = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }
        guard extensions.count <= 256 else { throw AutomationContractError.invalidIdentity }
        for item in extensions {
            guard try AutomationPath.canonical(item).path == item.path else { throw AutomationContractError.invalidIdentity }
            let infoPath = relative + "/" + item.lastPathComponent + (macOS ? "/Contents/Info.plist" : "/Info.plist")
            let data = try AutomationReadOnlyFile.read(root: root, relativePath: infoPath, maximumBytes: 1_048_576)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw AutomationContractError.missingEvidence("Built extension \(item.lastPathComponent) has an invalid Info.plist; correct its app packaging configuration before retrying.")
            }
            for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
                guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AutomationContractError.missingEvidence("Built extension \(item.lastPathComponent) is missing \(key). The app compiled, but this product cannot be admitted for installation. Correct the extension's version/build packaging configuration before retrying.")
                }
            }
        }
    }
}
