import Foundation

/// Planned selected-target settings, not authenticated compiler input or runtime authority.
/// Architecture and Catalyst need stronger invocation facts and remain unresolved.
public struct AutomationSourcePlatformPredicates: Codable, Equatable, Sendable {
    public let version: Int
    public let operatingSystem: String
    public let environment: String

    static func read(_ settings: [String: AutomationJSON], platform: AutomationBuildPlatform) -> Self? {
        let systems = ["macosx": "macOS", "iphoneos": "iOS", "iphonesimulator": "iOS",
                       "appletvos": "tvOS", "appletvsimulator": "tvOS", "watchos": "watchOS",
                       "watchsimulator": "watchOS", "xros": "visionOS", "xrsimulator": "visionOS"]
        let prefixes = ["macOS": "macos", "iOS": "ios", "tvOS": "tvos", "watchOS": "watchos", "visionOS": "xros"]
        guard let system = systems[platform.platformName],
              settings["SWIFT_PLATFORM_TARGET_PREFIX"] == prefixes[system].map(AutomationJSON.string),
              settings["IS_MACCATALYST"] == nil || settings["IS_MACCATALYST"] == .string("NO"),
              safeFlags(settings["OTHER_SWIFT_FLAGS"]) else { return nil }
        let variant = settings["SDK_VARIANT"], effective = settings["EFFECTIVE_PLATFORM_NAME"]
        guard effective == nil || effective == .string("") || effective == .string("-" + platform.platformName) else { return nil }
        if system == "macOS" {
            guard settings["SUPPORTS_MACCATALYST"] == .string("NO"), variant == nil || variant == .string("macos") else { return nil }
        } else {
            guard variant == nil || variant == .string("") else { return nil }
        }
        let simulators: Set<String> = ["iphonesimulator", "appletvsimulator", "watchsimulator", "xrsimulator"]
        return .init(version: 1, operatingSystem: system, environment: simulators.contains(platform.platformName) ? "simulator" : "native")
    }

    func validate() throws {
        guard version == 1, ["macOS", "iOS", "tvOS", "watchOS", "visionOS"].contains(operatingSystem),
              ["native", "simulator"].contains(environment), operatingSystem != "macOS" || environment == "native" else {
            throw AutomationContractError.conflictingOperation
        }
    }

    func resolve(predicate: String, argument: String) -> Bool? {
        guard (try? validate()) != nil else { return nil }
        if predicate == "os", ["macOS", "iOS", "tvOS", "watchOS", "visionOS", "Linux", "Windows"].contains(argument) {
            return argument == operatingSystem
        }
        if predicate == "targetEnvironment", ["simulator", "macCatalyst"].contains(argument) {
            return argument == environment
        }
        return nil
    }

    private static func safeFlags(_ value: AutomationJSON?) -> Bool {
        // Xcode omits unset OTHER_SWIFT_FLAGS; any observed unsupported flag keeps
        // target predicates unknown, especially target/SDK/frontend overrides.
        guard let value else { return true }
        guard case .string(let text) = value, text.utf8.count <= 16384 else { return false }
        let flags = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard flags.count <= 512 else { return false }
        var position = 0
        while position < flags.count {
            let flag = flags[position]; position += 1
            if flag == "-D", position < flags.count, AutomationSourceCompilationConditions.identifier(flags[position]) { position += 1 }
            else if flag.hasPrefix("-D"), AutomationSourceCompilationConditions.identifier(String(flag.dropFirst(2))) {}
            else { return false }
        }
        return true
    }
}
