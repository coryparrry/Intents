import Foundation

/// Checks the platform SDK before an owned device or Mac build starts.
public enum AutomationXcodeSDKCompatibility {
    public static func validate(target: TargetIdentity, targetOSVersion: String, sdkVersion: String, developerDirectory: URL) throws {
        guard target.kind != .simulator else { return }
        let platform = target.kind == .nativeMac ? "macOS" : "iOS"
        guard let targetVersion = majorMinor(targetOSVersion), let sdk = majorMinor(sdkVersion) else {
            throw AutomationContractError.missingEvidence("Could not determine the " + platform + " version or the selected Xcode SDK. Check the destination and Xcode selection before preparing.")
        }
        guard targetVersion == sdk else {
            throw AutomationContractError.missingEvidence("Install Xcode matching " + platform + " " + targetVersion + " (current: " + platform + " SDK " + sdk + " at " + developerDirectory.path + ").")
        }
    }

    private static func majorMinor(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", maxSplits: 2)
        guard parts.count >= 2, let major = Int(parts[0]), major > 0 else { return nil }
        let minorDigits = parts[1].prefix { $0.isASCII && $0.isNumber }
        guard !minorDigits.isEmpty, let minor = Int(minorDigits), minor >= 0 else { return nil }
        return String(major) + "." + String(minor)
    }

    #if os(macOS)
    static func check(target: TargetIdentity, developerDirectory: URL, workspace: URL, command: AutomationOwnedCommand,
                      willStart: @escaping @Sendable () async throws -> Void) async throws {
        guard target.kind != .simulator else { return }
        let sdkName = target.kind == .nativeMac ? "macosx" : "iphoneos"
        let result = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", sdkName, "--show-sdk-version"], directory: workspace,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developerDirectory.path,
                          "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()],
            timeout: .seconds(20), willStart: willStart)
        guard result.exitStatus == 0, !result.logsTruncated, let sdkVersion = String(data: result.stdout, encoding: .utf8) else {
            throw AutomationContractError.missingEvidence("Could not read the selected Xcode platform SDK. Choose an installed Xcode before preparing.")
        }
        let targetVersion: String
        if target.kind == .nativeMac {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            targetVersion = String(version.majorVersion) + "." + String(version.minorVersion)
        } else {
            let devices = try await AutomationPhysicalDeviceInventory.read(developerDirectory: developerDirectory, workspace: workspace)
            guard let device = devices.first(where: {
                $0.id.lowercased() == target.id.lowercased() ||
                (target.physicalDeviceIdentifier != nil && $0.coreDeviceIdentifier?.lowercased() == target.physicalDeviceIdentifier?.lowercased())
            }) else {
                throw AutomationContractError.missingEvidence("Could not read the selected iPhone or iPad OS version. Connect the device and refresh devices before preparing.")
            }
            targetVersion = device.operatingSystem
        }
        try validate(target: target, targetOSVersion: targetVersion, sdkVersion: sdkVersion, developerDirectory: developerDirectory)
    }
    #endif
}
