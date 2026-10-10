import Foundation

/// Pinned PHPLCrashReporter uses only this app-specific cache directory.
struct TelemetryPendingCrashReports: Sendable {
    let directory: URL

    nonisolated init(cacheDirectory: URL, bundleIdentifier: String) {
        directory = cacheDirectory.appendingPathComponent("com.plausiblelabs.crashreporter.data", isDirectory: true)
            .appendingPathComponent(bundleIdentifier.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    static var eligible: Self? {
        guard TelemetryCaptureEligibility.current.allowsProductionCapture else { return nil }
        return current
    }

    static var current: Self? {
        guard let identifier = Bundle.main.bundleIdentifier,
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return Self(cacheDirectory: cache, bundleIdentifier: identifier)
    }

    nonisolated func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    nonisolated func discard() {
        // Removing the parent also prevents the process-lifetime native hook from
        // writing another report while consent is off (the handler never mkdirs).
        try? FileManager.default.removeItem(at: directory)
    }
}
