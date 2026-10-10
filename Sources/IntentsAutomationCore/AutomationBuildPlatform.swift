import Foundation

/// Resolved Xcode facts, not a platform inferred from an extension or a source declaration.
public struct AutomationBuildPlatform: Codable, Equatable, Sendable {
    public let targetName: String
    public let configuration: String
    public let projectPath: String
    public let platformName: String
    public let platformFamily: String
    public let sdkRoot: String
    public let supportedPlatforms: [String]
    public var swiftModuleName: String? = nil
    public var supportsIOSSimulator: Bool { platformFamily == "ios" && supportedPlatforms.contains("iphonesimulator") }
    public var supportsPhysicalIOS: Bool {
        platformFamily == "ios" && platformName == "iphoneos" && supportedPlatforms.contains("iphoneos")
    }
    public var supportsMacOS: Bool {
        platformFamily == "macos" && platformName == "macosx" && supportedPlatforms == ["macosx"]
    }

    static func read(_ data: Data, project: URL, targetName: String, configuration: String, developer: URL) throws -> Self {
        guard data.count <= 1_048_576, case .array(let rows) = try JSONDecoder().decode(AutomationJSON.self, from: data),
              rows.count <= 1000 else { throw AutomationContractError.missingEvidence("Xcode platform settings are incomplete") }
        let candidates = rows.compactMap(\.object).filter { $0["target"] == .string(targetName) }
        guard candidates.count == 1, let settings = candidates[0]["buildSettings"]?.object,
              settings["TARGET_NAME"] == .string(targetName), settings["CONFIGURATION"] == .string(configuration),
              case .string(let resolvedProject) = settings["PROJECT_FILE_PATH"],
              resolvedProject.utf16.count <= 4096, !resolvedProject.contains("\0"), Self.sameProject(resolvedProject, project),
              case .string(let platform) = settings["PLATFORM_NAME"], case .string(let sdk) = settings["SDKROOT"],
              case .string(let supported) = settings["SUPPORTED_PLATFORMS"], sdk.utf16.count <= 4096, !sdk.contains("\0"),
              supported.utf16.count <= 512 else { throw AutomationContractError.missingEvidence("Xcode resolved a different or incomplete app target") }
        let platforms = supported.split(whereSeparator: \.isWhitespace).map(String.init)
        let families = ["iphoneos": "ios", "iphonesimulator": "ios", "macosx": "macos",
                        "appletvos": "tvos", "appletvsimulator": "tvos", "watchos": "watchos",
                        "watchsimulator": "watchos", "xros": "visionos", "xrsimulator": "visionos"]
        guard let family = families[platform], (1...16).contains(platforms.count), platforms.contains(platform),
              platforms.allSatisfy({ families[$0] == family }), Set(platforms).count == platforms.count else {
            throw AutomationContractError.missingEvidence("Unsupported or inconsistent Xcode platform family")
        }
        if sdk != platform {
            let sdkURL = URL(fileURLWithPath: sdk)
            guard sdk.hasPrefix(developer.path + "/Platforms/"),
                  sdkURL.lastPathComponent.lowercased().hasPrefix(platform), sdkURL.pathExtension == "sdk",
                  !sdk.split(separator: "/").contains("..") else {
                throw AutomationContractError.missingEvidence("Resolved SDK does not match the selected developer platform")
            }
        }
        let module: String?
        if let override = settings["SWIFT_MODULE_NAME"], override != .string("") {
            if case .string(let value) = override { module = validModule(value) } else { module = nil }
        } else {
            if case .string(let value) = settings["PRODUCT_MODULE_NAME"] { module = validModule(value) } else { module = nil }
        }
        return .init(targetName: targetName, configuration: configuration, projectPath: project.path,
            platformName: platform, platformFamily: family, sdkRoot: sdk, supportedPlatforms: platforms.sorted(), swiftModuleName: module)
    }
    private static func validModule(_ value: String) -> String? {
        value.utf8.count <= 256 && value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? value : nil
    }
    static func sameProject(_ path: String, _ project: URL) -> Bool {
        if path == project.path { return true }
        guard path.hasPrefix("/"), let actual = try? AutomationPath.canonical(URL(fileURLWithPath: path)),
              let expected = try? AutomationPath.canonical(project) else { return false }
        return actual == expected
    }
}
