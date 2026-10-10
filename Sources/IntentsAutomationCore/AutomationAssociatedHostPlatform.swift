import Foundation

/// Layout and build facts for an associated host; grants no execution permission.
enum AutomationAssociatedHostPlatform: Equatable, Sendable {
    case iosSimulator, physicalIOS, macOS

    init(target: TargetIdentity) throws {
        switch target.kind {
        case .simulator:
            guard target.id.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
                throw AutomationContractError.invalidIdentity
            }
            self = .iosSimulator
        case .nativeMac:
            guard target.id == "host-macos-local", let login = target.loginSession, !login.isEmpty,
                  login.utf8.count <= 256, !login.contains("\0"), !login.contains("\n") else {
                throw AutomationContractError.invalidIdentity
            }
            self = .macOS
        case .physical:
            try AutomationPhysicalExecutable.validateTarget(target)
            self = .physicalIOS
        }
    }
    var destination: String {
        switch self {
        case .macOS: "platform=macOS"
        case .iosSimulator: "generic/platform=iOS Simulator"
        case .physicalIOS: "generic/platform=iOS"
        }
    }
    var sdkName: String {
        switch self {
        case .macOS: "macosx"
        case .iosSimulator: "iphonesimulator"
        case .physicalIOS: "iphoneos"
        }
    }
    var infoPath: String { self == .macOS ? "Contents/Info.plist" : "Info.plist" }
    var plugInsPath: String { self == .macOS ? "Contents/PlugIns/" : "PlugIns/" }
    var digestVersion: Int? { self == .macOS ? 2 : nil }
    var appPlatform: String { self == .macOS ? "macos" : "ios" }
    func accepts(_ platform: AutomationBuildPlatform) -> Bool {
        switch self {
        case .macOS: platform.supportsMacOS
        case .iosSimulator: platform.supportsIOSSimulator
        case .physicalIOS: platform.supportsPhysicalIOS
        }
    }

    static func subjectProduct(_ data: Data, platform: AutomationBuildPlatform, products: URL) throws -> (path: String, bundleID: String) {
        guard data.count <= 1_048_576, case .array(let rows) = try JSONDecoder().decode(AutomationJSON.self, from: data), rows.count <= 1000 else {
            throw AutomationContractError.invalidIdentity
        }
        let candidates = rows.compactMap(\.object).filter { $0["target"] == .string(platform.targetName) }
        guard candidates.count == 1, let settings = candidates[0]["buildSettings"]?.object,
              settings["TARGET_NAME"] == .string(platform.targetName), settings["CONFIGURATION"] == .string(platform.configuration),
              case .string(let resolvedProject) = settings["PROJECT_FILE_PATH"], resolvedProject.utf8.count <= 4096,
              !resolvedProject.contains("\0"), AutomationBuildPlatform.sameProject(resolvedProject, URL(fileURLWithPath: platform.projectPath)),
              case .string(let directory) = settings["TARGET_BUILD_DIR"],
              case .string(let name) = settings["FULL_PRODUCT_NAME"],
              case .string(let bundleID) = settings["PRODUCT_BUNDLE_IDENTIFIER"],
              directory.utf8.count <= 4096, !directory.contains("\0"),
              directory.hasPrefix(products.path + "/"), URL(fileURLWithPath: directory).standardizedFileURL.path == directory,
              name.utf8.count <= 1024, name.hasSuffix(".app"), !name.contains("/"), !name.contains("\0"),
              bundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.missingEvidence("Selected target product identity was not resolved inside owned Products")
        }
        return (directory + "/" + name, bundleID)
    }
}
