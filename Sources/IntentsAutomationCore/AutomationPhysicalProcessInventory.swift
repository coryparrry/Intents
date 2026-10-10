import Foundation

/// Closed parsing of the inspected devicectl JSON v5 complete-inventory contract.
public struct AutomationPhysicalProcessInventory: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var executable: String
        public var processIdentifier: Int32
    }
    public let deviceIdentifier: String
    public let processes: [Entry]

    public static func parse(_ data: Data, targetID: String, expectedOutputURL: URL? = nil) throws -> Self {
        let root = try PhysicalInventoryJSON.decode(data, command: "processes", targetID: targetID, expectedOutputURL: expectedOutputURL)
        guard let raw = root["runningProcesses"] else { throw AutomationContractError.terminationUnverified }
        let entries = try JSONDecoder().decode([Entry].self, from: JSONSerialization.data(withJSONObject: raw))
        guard (1...8192).contains(entries.count), Set(entries.map(\.processIdentifier)).count == entries.count,
              entries.allSatisfy({ $0.processIdentifier > 0 && (try? PhysicalInventoryJSON.path($0.executable)) != nil }),
              entries.contains(where: { $0.processIdentifier == 1 && (try? PhysicalInventoryJSON.path($0.executable)) == "/sbin/launchd" }) else {
            throw AutomationContractError.terminationUnverified
        }
        return Self(deviceIdentifier: root["deviceIdentifier"] as! String, processes: entries)
    }

    /// PID presence is uncertainty even if the executable appears different: there is no remote start-time query.
    public func runnerAbsent(bundleID: String, executableName: String, ownedPID: Int32?, apps: AutomationPhysicalAppInventory) throws -> Bool {
        guard deviceIdentifier == apps.deviceIdentifier else { throw AutomationContractError.invalidIdentity }
        try AutomationPhysicalControllerValidation.validate(bundleID: bundleID, executableName: executableName, ownedPID: ownedPID)
        let installed = apps.apps.filter { $0.bundleIdentifier == bundleID }
        guard installed.count <= 1 else { throw AutomationContractError.terminationUnverified }
        let bundlePath = try installed.first.map { try PhysicalInventoryJSON.path($0.url) }
        for entry in processes {
            let path = try PhysicalInventoryJSON.path(entry.executable)
            if entry.processIdentifier == ownedPID || URL(fileURLWithPath: path).lastPathComponent == executableName { return false }
            if let bundlePath, path.hasPrefix(bundlePath + "/") { return false }
        }
        return true
    }
}

public struct AutomationPhysicalAppInventory: Sendable {
    public struct Entry: Codable, Equatable, Sendable { public var bundleIdentifier: String; public var url: String }
    public let targetID: String
    public let deviceIdentifier: String
    public let apps: [Entry]
    public static func parse(_ data: Data, targetID: String, expectedOutputURL: URL? = nil) throws -> Self {
        let root = try PhysicalInventoryJSON.decode(data, command: "apps", targetID: targetID, expectedOutputURL: expectedOutputURL)
        guard ["defaultAppsIncluded", "hiddenAppsIncluded", "internalAppsIncluded", "removableAppsIncluded"].allSatisfy({ root[$0] as? Bool == true }),
              let raw = root["apps"] else { throw AutomationContractError.terminationUnverified }
        let entries = try JSONDecoder().decode([Entry].self, from: JSONSerialization.data(withJSONObject: raw))
        guard entries.count <= 8192, Set(entries.map(\.bundleIdentifier)).count == entries.count,
              entries.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.utf8.count <= 256 && (try? PhysicalInventoryJSON.path($0.url)) != nil }) else {
            throw AutomationContractError.terminationUnverified
        }
        return Self(targetID: targetID, deviceIdentifier: root["deviceIdentifier"] as! String, apps: entries)
    }
}

enum AutomationPhysicalControllerValidation {
    static func matchesExecutablePath(_ path: String, bundleName: String, executableName: String) -> Bool {
        guard path.utf8.count <= 4096, !path.contains("\0"), !bundleName.contains("/"), !executableName.contains("/") else { return false }
        let prefixes = ["/private/var/containers/Bundle/Application/", "/var/containers/Bundle/Application/"]
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { return false }
        let pieces = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return pieces.count == 3 && UUID(uuidString: String(pieces[0])) != nil
            && pieces[1] == Substring(bundleName) && pieces[2] == Substring(executableName)
            && ![bundleName, executableName].contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }
    static func validate(bundleID: String, executableName: String, ownedPID: Int32?) throws {
        guard bundleID.utf8.count <= 256,
              bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              !executableName.isEmpty, executableName.utf8.count <= 256,
              !executableName.contains("/"), !executableName.contains("\0"),
              ownedPID.map({ $0 > 0 }) ?? true else { throw AutomationContractError.invalidIdentity }
    }
}

private enum PhysicalInventoryJSON {
    static func decode(_ data: Data, command: String, targetID: String, expectedOutputURL: URL?) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 2_097_152,
              targetID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success",
              info["jsonVersion"] as? Int == 5,
              info["commandType"] as? String == "devicectl.device.info." + command,
              let arguments = info["arguments"] as? [String],
              completeArguments(arguments, command: command, targetID: targetID, expectedOutputURL: expectedOutputURL),
              let result = root["result"] as? [String: Any],
              let identifier = result["deviceIdentifier"] as? String, UUID(uuidString: identifier) != nil else {
            throw AutomationContractError.terminationUnverified
        }
        return result
    }

    private static func completeArguments(_ arguments: [String], command: String, targetID: String, expectedOutputURL: URL?) -> Bool {
        let prefix = ["devicectl", "device", "info", command, "--device", targetID]
            + (command == "apps" ? ["--include-all-apps"] : [])
        guard arguments.count == prefix.count + 5 else { return false }
        let output = arguments[prefix.count + 1]
        if let expectedOutputURL {
            // Compare the exact requested path. Foundation's standardization can rewrite
            // canonical /private/var paths to /var, unlike our realpath ownership contract.
            guard expectedOutputURL.isFileURL, output == expectedOutputURL.path else { return false }
        }
        guard output.hasPrefix("/"), output.utf8.count <= 4096, !output.contains("\0"),
              !output.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return arguments == prefix + ["--json-output", output, "--timeout", "10", "--quiet"]
    }

    static func path(_ raw: String) throws -> String {
        guard raw.utf8.count <= 4096, !raw.contains("\0"), raw.hasPrefix("file:///"),
              let components = URLComponents(string: raw), components.host?.isEmpty != false,
              components.query == nil, components.fragment == nil,
              let url = components.url, url.isFileURL, url.path.hasPrefix("/"),
              !url.path.contains("\0"), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AutomationContractError.terminationUnverified
        }
        return url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    }
}
