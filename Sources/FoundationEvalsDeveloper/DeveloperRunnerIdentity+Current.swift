import Foundation
import CryptoKit

#if canImport(UIKit)
import UIKit
#endif

public extension DeveloperRunnerIdentity {
    /// Collects this process's platform, bundle, OS, hardware and locale into a runner identity.
    /// Build provenance hashes the bundle executable when readable; missing bundle metadata
    /// uses `unknown`, and unavailable provenance is omitted.
    /// - Parameters:
    ///   - id: Stable runner identity supplied by the containing app.
    ///   - displayName: Human-readable label supplied by the containing app.
    ///   - bundle: App bundle whose identifier, version and executable are reported.
    ///   - processInfo: Source of the operating-system version string.
    /// - Returns: App-reported identity metadata, rather than device attestation.
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
            localeIdentifier: Locale.current.identifier,
            buildProvenance: buildProvenance(for: bundle)
        )
    }

    /// This is app-supplied provenance from the paired process, not device
    /// attestation. The host still compares it with its checked build product.
    /// Hashes the readable executable and copies optional build metadata from the bundle;
    /// returns `nil` if executable reading fails or the bundle identifier is unavailable.
    private static func buildProvenance(for bundle: Bundle) -> DeveloperRunnerBuildProvenance? {
        guard let executableURL = bundle.executableURL,
              let file = try? FileHandle(forReadingFrom: executableURL) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        do {
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                hash.update(data: chunk)
            }
        } catch { return nil }
        let buildID = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard let appID = bundle.bundleIdentifier, !appID.isEmpty else { return nil }
        return .init(
            logicalAppID: appID,
            buildID: buildID,
            sourceManifestDigest: bundle.object(forInfoDictionaryKey: "DeveloperRunnerSourceManifestDigest") as? String,
            packageRevision: bundle.object(forInfoDictionaryKey: "DeveloperRunnerPackageRevision") as? String,
            compiledProductNonce: bundle.object(forInfoDictionaryKey: "DeveloperRunnerBuildNonce") as? String
        )
    }

#if os(macOS)
    /// Reads the Mac hardware model with `sysctlbyname`, falling back to `Mac` on failure.
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
