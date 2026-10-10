import Foundation

/// Narrow selected-target membership facts. Neither compiler coverage nor an
/// execution capability; raw observed settings are retained and replayed.
public struct AutomationSourcePlatformContext: Codable, Equatable, Sendable {
    public let settingsSHA256: String
    public let developerDirectory: String
    public let selected: AutomationBuildPlatform
    public let filterFamily: String?

    static func read(_ data: Data, project: URL, targetName: String, configuration: String, developer: URL) throws -> Self {
        let selected = try AutomationBuildPlatform.read(data, project: project, targetName: targetName,
            configuration: configuration, developer: developer)
        guard case .array(let rows) = try JSONDecoder().decode(AutomationJSON.self, from: data),
              let row = rows.compactMap(\.object).first(where: { $0["target"] == .string(targetName) }),
              let settings = row["buildSettings"]?.object else { throw AutomationContractError.invalidIdentity }
        let family: String?
        if selected.platformFamily == "macos" {
            // A macosx SDK alone cannot distinguish Catalyst from native Mac.
            // Resolve only the observed native profile; leave other variants open.
            let variant = settings["SDK_VARIANT"]
            let effective = settings["EFFECTIVE_PLATFORM_NAME"]
            family = settings["SUPPORTS_MACCATALYST"] == .string("NO") &&
                (variant == nil || variant == .string("macos")) &&
                (effective == nil || effective == .string("") || effective == .string("-macosx")) ? "macos" : nil
        } else {
            // Unknown or contradictory variants cannot establish membership.
            // Catalyst support alone on a device/simulator build is harmless.
            let variant = settings["SDK_VARIANT"]
            let effective = settings["EFFECTIVE_PLATFORM_NAME"]
            family = (variant == nil || variant == .string("")) &&
                (effective == nil || effective == .string("") || effective == .string("-" + selected.platformName)) ? selected.platformFamily : nil
        }
        return .init(settingsSHA256: AutomationArtifactRegistry.digest(data), developerDirectory: developer.path,
                     selected: selected, filterFamily: family)
    }

    /// nil preserves unresolved membership, false retains an inactive input.
    func includes(_ build: [String: Any]) -> Bool? {
        let single = build["platformFilter"], multiple = build["platformFilters"]
        if single == nil && multiple == nil { return true }
        guard single == nil || multiple == nil, let filterFamily else { return nil }
        let filters: [String]
        if let single { guard let value = single as? String else { return nil }; filters = [value] }
        else { guard let values = multiple as? [String] else { return nil }; filters = values }
        let known: Set<String> = ["ios", "macos", "maccatalyst", "tvos", "watchos", "visionos"]
        guard (1...16).contains(filters.count), Set(filters).count == filters.count,
              filters.allSatisfy(known.contains) else { return nil }
        return filters.contains(filterFamily)
    }
}
