#if os(macOS)
import Foundation

public struct AutomationPhysicalDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    public var operatingSystem: String
    public var available: Bool
    public var coreDeviceIdentifier: String? = nil
    public var selectionLabel: String { name + " · " + model + " · " + id.suffix(8) }
}

public enum AutomationPhysicalDeviceInventory {
    private actor IdentifierCache {
        var identifiers: [String: [String: String]] = [:]
        func get(_ developer: String) -> [String: String]? { identifiers[developer] }
        func set(_ developer: String, identifiers: [String: String]) { self.identifiers[developer] = identifiers }
    }
    private static let identifierCache = IdentifierCache()
    public static func cachedLeaseAliases(developerDirectory: URL) async throws -> [String: String]? {
        await identifierCache.get(try AutomationPath.canonical(developerDirectory).path)
    }
    public static func leaseAliases(developerDirectory: URL, workspace: URL) async throws -> [String: String] {
        try await readCoreIdentifiers(developerDirectory: developerDirectory, workspace: workspace)
    }
    public static func read(developerDirectory: URL, workspace: URL) async throws -> [AutomationPhysicalDevice] {
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcdevice", "list", "--timeout", "5"], directory: workspace,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": try AutomationPath.canonical(developerDirectory).path,
                          "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: .seconds(20))
        guard result.exitStatus == 0, !result.logsTruncated else {
            throw AutomationContractError.missingEvidence("Device discovery is unavailable. Check the selected Xcode and try Refresh devices.")
        }
        let identifiers = try await readCoreIdentifiers(developerDirectory: developerDirectory, workspace: workspace, refresh: true)
        return try parse(result.stdout).map { device in
            var device = device
            device.coreDeviceIdentifier = identifiers[device.id.lowercased()]
                ?? UUID(uuidString: device.id)?.uuidString
            // A destination without canonical ownership cannot be selected for a run.
            device.available = device.available && device.coreDeviceIdentifier != nil
            return device
        }
    }
    public static func canonicalTarget(_ target: TargetIdentity, developerDirectory: URL, workspace: URL) async throws -> TargetIdentity {
        try AutomationPhysicalExecutable.validateTarget(target)
        if let identifier = target.physicalDeviceIdentifier, UUID(uuidString: identifier) != nil { return target }
        var target = target
        if let identifier = UUID(uuidString: target.id) {
            target.physicalDeviceIdentifier = identifier.uuidString
        } else {
            let identifiers = try await readCoreIdentifiers(developerDirectory: developerDirectory, workspace: workspace)
            guard let identifier = identifiers[target.id.lowercased()] else {
                throw AutomationContractError.missingEvidence("Device ownership could not be resolved. Refresh devices and try again.")
            }
            target.physicalDeviceIdentifier = identifier
        }
        return target
    }
    private static func readCoreIdentifiers(developerDirectory: URL, workspace: URL, refresh: Bool = false) async throws -> [String: String] {
        let developer = try AutomationPath.canonical(developerDirectory).path
        if !refresh, let cached = await identifierCache.get(developer) { return cached }
        let output = workspace.appendingPathComponent("coredevice-discovery-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "list", "devices", "--json-output", output.path, "--timeout", "10", "--quiet"], directory: workspace,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer,
                          "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: .seconds(20))
        guard result.exitStatus == 0, !result.logsTruncated else {
            throw AutomationContractError.missingEvidence("Device ownership discovery is unavailable. Check the selected Xcode and try Refresh devices.")
        }
        let identifiers = try parseCoreIdentifiers(Data(contentsOf: output))
        await identifierCache.set(developer, identifiers: identifiers)
        return identifiers
    }
    static func parseCoreIdentifiers(_ data: Data) throws -> [String: String] {
        guard !data.isEmpty, data.count <= 2_097_152,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]],
              devices.count <= 1024 else { throw AutomationContractError.invalidIdentity }
        var identifiers: [String: String] = [:]
        for device in devices {
            guard let raw = device["identifier"] as? String, let uuid = UUID(uuidString: raw) else {
                throw AutomationContractError.invalidIdentity
            }
            let properties = device["properties"] as? [String: Any]
            let hardware = device["hardwareProperties"] as? [String: Any] ?? properties?["hardware"] as? [String: Any]
            let identity = properties?["identifiers"] as? [String: Any]
            let udid = hardware?["udid"] as? String ?? identity?["udid"] as? String
            for alias in [raw, udid].compactMap({ $0 }) {
                try AutomationPhysicalExecutable.validateTarget(.init(id: alias, kind: .physical))
                if let prior = identifiers[alias.lowercased()], prior != uuid.uuidString { throw AutomationContractError.invalidIdentity }
                identifiers[alias.lowercased()] = uuid.uuidString
            }
        }
        return identifiers
    }
    public static func parse(_ data: Data) throws -> [AutomationPhysicalDevice] {
        struct Entry: Decodable {
            var simulator: Bool
            var platform: String
            var identifier: String
            var name: String
            var modelName: String?
            var operatingSystemVersion: String?
            var available: Bool
            var ignored: Bool?
        }
        guard !data.isEmpty, data.count <= 2_097_152 else { throw AutomationContractError.invalidIdentity }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard entries.count <= 1024 else { throw AutomationContractError.invalidIdentity }
        var devices: [AutomationPhysicalDevice] = [], seen: Set<String> = []
        for entry in entries where !entry.simulator && entry.platform == "com.apple.platform.iphoneos" && entry.ignored != true {
            try AutomationPhysicalExecutable.validateTarget(.init(id: entry.identifier, kind: .physical))
            guard seen.insert(entry.identifier.lowercased()).inserted,
                  [entry.name, entry.modelName ?? "iPhone or iPad", entry.operatingSystemVersion ?? "Unknown version"].allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  }) else { throw AutomationContractError.invalidIdentity }
            devices.append(.init(id: entry.identifier, name: entry.name, model: entry.modelName ?? "iPhone or iPad",
                                 operatingSystem: entry.operatingSystemVersion ?? "Unknown version", available: entry.available))
        }
        return devices.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}
#endif
