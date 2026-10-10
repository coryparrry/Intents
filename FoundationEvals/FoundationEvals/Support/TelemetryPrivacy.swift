import Foundation
import CoreFoundation
import PostHog

/// Host-local policy is independent of the app's consent and installation identity.
enum TelemetryLocalPolicy {
    nonisolated static var isDisabled: Bool {
        CFPreferencesCopyValue("disabled" as CFString, "com.coryparry.Intents.LocalTelemetry" as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool == true
    }
}

/// Production collection is independent of saved consent and launch overrides.
struct TelemetryCaptureEligibility {
    let isDebug: Bool
    let isSimulator: Bool
    let environment: [String: String]
    let arguments: [String]
    var isLocallyDisabled = false

    var allowsProductionCapture: Bool {
        guard !isDebug, !isSimulator, !isLocallyDisabled else { return false }
        let excluded = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCODE_RUNNING_FOR_PREVIEWS", "INTENTS_DEMO", "INTENTS_TELEMETRY_VERIFICATION"]
        guard !excluded.contains(where: { environment[$0] != nil }) else { return false }
        return !arguments.contains { argument in
            guard argument.hasPrefix("-") else { return false }
            let value = argument.lowercased()
            return value.contains("acceptance") || value.contains("uitest") || value.contains("preview")
                || value.contains("demo") || value.contains("telemetry-verification") || value.contains("evaluation-storage")
        }
    }

    static var current: Self {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return Self(isDebug: debug, isSimulator: simulator,
            environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments,
            isLocallyDisabled: TelemetryLocalPolicy.isDisabled)
    }
}

/// Pure, nonisolated filtering is safe when the SDK invokes it off the main actor.
enum TelemetryPayloadFilter {
    nonisolated static func properties(_ properties: [String: Any], event name: String) -> [String: Any]? {
        guard let allowed = TelemetryEvent.allowedProperties(for: name) else { return nil }
        var safe = properties.filter { allowed.contains($0.key) && TelemetryEvent.isSafeProperty($0.key, value: $0.value) }
        if name == "$exception" {
            guard properties["_intents_crash_capture"] as? Bool == true,
                  (properties["_intents_consent_epoch"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                  safe["app"] as? String == "intents", safe["environment"] as? String == "production",
                  safe["platform"] as? String == "macOS", safe["schema_version"] as? Int == 2,
                  safe["app_build"] != nil, safe["app_version"] != nil,
                  let crash = TelemetryCrashPrivacy.properties(properties) else { return nil }
            safe.merge(crash) { _, new in new }
        }
        safe["$process_person_profile"] = false
        safe["$geoip_disable"] = true
        return safe
    }

    nonisolated static func beforeSend(usage: Bool, diagnostics: Bool, consentEpoch: UUID? = nil) -> @Sendable (PostHogEvent) -> PostHogEvent? {
        return { @Sendable event in
            if event.event == "$exception", let consentEpoch,
               event.properties["_intents_consent_epoch"] as? String != consentEpoch.uuidString { return nil }
            guard TelemetryEvent.isDiagnostic(name: event.event) ? diagnostics : usage,
                  var safe = properties(event.properties, event: event.event) else { return nil }
            if let epoch = event.properties["_intents_consent_epoch"] as? String, UUID(uuidString: epoch) != nil {
                safe["_intents_consent_epoch"] = epoch
            }
            if event.event == "$exception" { safe["_intents_crash_capture"] = true }
            event.properties = safe
            return event
        }
    }
}
