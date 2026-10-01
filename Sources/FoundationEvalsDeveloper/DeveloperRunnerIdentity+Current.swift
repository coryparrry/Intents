import Foundation

#if canImport(UIKit)
import UIKit
#endif

public extension DeveloperRunnerIdentity {
    @MainActor
    static func current(
        id: UUID,
        displayName: String,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Self {
        let platform: DeveloperRunnerPlatform
        let hardwareModel: String
#if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: platform = .iPhone
        case .pad: platform = .iPad
        case .vision: platform = .vision
        default: platform = .unknown
        }
        hardwareModel = UIDevice.current.model
#elseif os(macOS)
        platform = .mac
        hardwareModel = Self.hardwareMachineName()
#else
        platform = .unknown
        hardwareModel = "Unknown"
#endif
        return Self(
            id: id,
            displayName: displayName,
            platform: platform,
            operatingSystem: processInfo.operatingSystemVersionString,
            hardwareModel: hardwareModel,
            appBundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            localeIdentifier: Locale.current.identifier
        )
    }

#if os(macOS)
    private static func hardwareMachineName() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "Mac"
        }
        let content = bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: content, as: UTF8.self)
    }
#endif
}
