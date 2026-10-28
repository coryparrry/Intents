import Foundation
import Observation
import PostHog
import OSLog

struct TelemetryConfiguration {
    let projectToken: String
    let host: String
    var usageEnabled = true
    var diagnosticsEnabled = false
    var diagnosticSessionID: UUID? = nil
    var consentEpoch = UUID()

    static var bundled: Self? {
        guard TelemetryCaptureEligibility.current.allowsProductionCapture else { return nil }
        guard let token = Bundle.main.object(forInfoDictionaryKey: "PostHogProjectToken") as? String,
              token.hasPrefix("phc_"), token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let host = Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String,
              let url = URL(string: host), url.scheme == "https", url.host != nil
        else { return nil }
        return Self(projectToken: token, host: host)
    }
}

@MainActor
protocol TelemetryClient: AnyObject {
    /// Accepts an app-defined event for the client's capture and delivery path.
    func capture(_ event: TelemetryEvent)
    var analyticsSessionID: String? { get }
    /// Requests delivery of queued events without implying that a server has accepted them.
    func flush()
    /// Stops delivery and discards pending client events when consent changes.
    func stopAndDiscard()
    /// Installs a callback for changes in the client's delivery state.
    func setDeliveryHandler(_ handler: @escaping @Sendable (TelemetryDelivery) -> Void)
}

extension TelemetryClient {
    var analyticsSessionID: String? { nil }
    /// Provides a no-op flush for clients that do not maintain a delivery queue.
    func flush() { }
    /// Provides a no-op delivery callback registration for clients without delivery reporting.
    func setDeliveryHandler(_ handler: @escaping @Sendable (TelemetryDelivery) -> Void) { }
}

enum TelemetryDelivery: String, Codable, Sendable {
    case idle, queued, accepted, failed, stopped
    var label: String {
        switch self {
        case .idle: "No events queued this session"
        case .queued: "Events queued; delivery not yet confirmed"
        case .accepted: "Last upload accepted by PostHog"
        case .failed: "Last upload failed; delivery is unconfirmed"
        case .stopped: "Sharing is off"
        }
    }
}

struct TelemetryDiagnosticRecord: Codable {
    let timestamp: Date
    let event: String
    let properties: [String: String]
}

@Observable @MainActor
final class TelemetryController {
    static let consentKey = "optionalTelemetryEnabled"
    static let diagnosticsConsentKey = "optionalDiagnosticsEnabled"
    static let consentEpochKey = "telemetryConsentEpoch"
    static let firstUseKey = "telemetryObservedFirstUse"
    @ObservationIgnored private var lastOpenSession: String?
    @ObservationIgnored private var lastUsageRecordedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastScreen: TelemetryScreen?
    @ObservationIgnored private var lastScreenSession: String?
    @ObservationIgnored private var lastScreenRecordedAt: ContinuousClock.Instant?
    @ObservationIgnored private var consentEpoch: UUID
    private(set) var diagnosticsEnabled: Bool
    private(set) var delivery: TelemetryDelivery = .idle
    private(set) var recentDiagnostics: [TelemetryDiagnosticRecord] = []
    @ObservationIgnored private var consentGeneration = UUID()
    @ObservationIgnored private var activeSpans: Set<UUID> = []
    @ObservationIgnored private let sessionID = UUID()
    @ObservationIgnored private let logger = Logger(subsystem: "com.coryparry.FoundationEvals", category: "Diagnostics")
    private(set) var isEnabled: Bool
    var isConfigured: Bool { configuration != nil }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let configuration: TelemetryConfiguration?
    @ObservationIgnored private let makeClient: @MainActor @Sendable (TelemetryConfiguration) -> any TelemetryClient
    @ObservationIgnored private var client: (any TelemetryClient)?
    @ObservationIgnored private let discardPendingCrashes: @MainActor @Sendable () -> Void

    /// Loads persisted usage and diagnostics consent, creates a consent-bound client when configured and discards unapproved crash reports.
    /// Injected defaults, client creation and crash cleanup support isolated storage and controlled delivery.
    init(defaults: UserDefaults = .standard, configuration: TelemetryConfiguration? = .bundled,
         makeClient: @escaping @MainActor @Sendable (TelemetryConfiguration) -> any TelemetryClient = { PostHogTelemetryClient(configuration: $0) },
         discardPendingCrashes: @escaping @MainActor @Sendable () -> Void = { TelemetryPendingCrashReports.current?.discard() }) {
        self.defaults = defaults
        self.configuration = configuration
        self.makeClient = makeClient
        self.discardPendingCrashes = discardPendingCrashes
        consentEpoch = defaults.string(forKey: Self.consentEpochKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        if configuration != nil { defaults.set(consentEpoch.uuidString, forKey: Self.consentEpochKey) }
        let preference = defaults.object(forKey: Self.consentKey) as? Bool ?? true
        isEnabled = preference && configuration != nil
        diagnosticsEnabled = defaults.bool(forKey: Self.diagnosticsConsentKey) && configuration != nil
        if !diagnosticsEnabled { discardPendingCrashes() }
        refreshClient()
    }

    /// Persists usage consent after rotating its epoch and recreates the client to revoke previously queued events.
    /// Enabling without valid configuration and unchanged preferences are ignored.
    func setEnabled(_ enabled: Bool) {
        guard !enabled || isConfigured, enabled != isEnabled else { return }
        rotateConsentEpoch()
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.consentKey)
        resetClientForConsentChange()
    }

    /// Persists diagnostics consent and recreates the consent-bound client, preserving recent usage-session deduplication when possible.
    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard !enabled || isConfigured, enabled != diagnosticsEnabled else { return }
        rotateConsentEpoch()
        diagnosticsEnabled = enabled
        defaults.set(enabled, forKey: Self.diagnosticsConsentKey)
        resetClientForConsentChange(preservingUsageSession: true)
    }

    /// Persists a fresh consent epoch before preferences change so stale queues cannot become authorized again.
    private func rotateConsentEpoch() {
        // Write the new epoch before the preference. A retained queue from before
        // revocation cannot become authorized again if deleting it fails.
        consentEpoch = UUID()
        defaults.set(consentEpoch.uuidString, forKey: Self.consentEpochKey)
    }

    /// Stops and discards the old client and crash reports, invalidates callback and span generations, then rebuilds delivery.
    /// Optional usage preservation rebinds recent open and screen deduplication across a diagnostics-only restart.
    private func resetClientForConsentChange(preservingUsageSession: Bool = false) {
        let preserveUsage = preservingUsageSession && isEnabled && lastOpenSession != nil
            && lastOpenSession == (client?.analyticsSessionID ?? sessionID.uuidString)
            && lastUsageRecordedAt.map { $0.duration(to: .now) < .seconds(1_800) } == true
        let preserveScreen = preserveUsage && lastScreenSession == lastOpenSession
        consentGeneration = UUID()
        lastOpenSession = nil
        if !preserveScreen { lastScreen = nil }
        lastScreenSession = nil
        client?.stopAndDiscard()
        discardPendingCrashes()
        client = nil
        delivery = .stopped
        refreshClient()
        // A diagnostics-only SDK restart is not another app open. Rebind the
        // deduplication state while retaining queue revocation and span epochs.
        if preserveUsage {
            let session = client?.analyticsSessionID ?? sessionID.uuidString
            lastOpenSession = session
            if preserveScreen { lastScreenSession = session }
        }
    }

    /// Creates a client only for enabled sharing with valid configuration and binds delivery callbacks to the current consent generation.
    private func refreshClient() {
        guard isEnabled || diagnosticsEnabled, let configuration else { return }
        let generation = consentGeneration
        var clientConfiguration = configuration
        clientConfiguration.consentEpoch = consentEpoch
        clientConfiguration.diagnosticSessionID = sessionID
        clientConfiguration.usageEnabled = isEnabled
        clientConfiguration.diagnosticsEnabled = diagnosticsEnabled
        client = makeClient(clientConfiguration)
        client?.setDeliveryHandler { [weak self] status in
            Task { @MainActor in
                guard let self, self.consentGeneration == generation else { return }
                self.delivery = status
            }
        }
        delivery = .idle
    }

    /// Keeps diagnostic events locally and forwards events only under their corresponding consent setting.
    /// Feature and screen capture update app-session bookkeeping; queued status does not imply confirmed upload.
    func capture(_ event: TelemetryEvent) {
        recordLocally(event)
        guard event.isDiagnostic ? diagnosticsEnabled : isEnabled else { return }
        if case .featureUsed = event { appBecameActive() }
        delivery = .queued
        client?.capture(event)
        if !event.isDiagnostic { lastUsageRecordedAt = .now }
        // Capture advances the SDK session clock; a read-only lookup cannot.
        if case .screen = event { appBecameActive() }
        if case .featureUsed = event { appBecameActive() }
    }

    /// One open per SDK session; first observed use is not a download/install count.
    func appBecameActive() {
        guard isEnabled else { return }
        let session = client?.analyticsSessionID ?? sessionID.uuidString
        guard lastOpenSession != session else { return }
        capture(.appOpened)
        lastOpenSession = client?.analyticsSessionID ?? sessionID.uuidString
        if !defaults.bool(forKey: Self.firstUseKey) {
            defaults.set(true, forKey: Self.firstUseKey)
            capture(.firstUse)
        }
    }

    /// Records a screen once per active SDK session unless the screen changes or thirty minutes have elapsed.
    func screen(_ screen: TelemetryScreen) {
        guard isEnabled else { return }
        appBecameActive()
        let session = client?.analyticsSessionID ?? sessionID.uuidString
        let expired = lastScreenRecordedAt.map { $0.duration(to: .now) >= .seconds(1_800) } ?? true
        guard lastScreen != screen || lastScreenSession != session || expired else { return }
        capture(.screen(screen))
        lastScreen = screen
        lastScreenSession = client?.analyticsSessionID ?? sessionID.uuidString
        lastScreenRecordedAt = .now
    }



    /// Creates an operation span and records its start when fewer than 100 spans are active.
    /// The returned span carries the current consent generation even when the active-span bound prevents recording.
    func begin(_ operation: TelemetryOperation) -> TelemetrySpan {
        let span = TelemetrySpan(id: UUID(), operation: operation, started: .now, consentGeneration: consentGeneration)
        // A fixed bound also prevents abandoned operations retaining unbounded memory.
        if activeSpans.count < 100 {
            activeSpans.insert(span.id)
            capture(.operationStarted(operation, span.id))
        }
        return span
    }

    /// Finishes a tracked span once with bounded elapsed time, recording adoption only for completed useful work.
    /// Callers suppress feature use for no-op or partial completions; earlier consent generations remain local only.
    func end(_ span: TelemetrySpan?, failure: TelemetryFailure? = nil, recordsFeature: Bool = true) {
        guard let span, activeSpans.remove(span.id) != nil else { return }
        let elapsed = span.started.duration(to: .now).components
        guard (0..<86_400).contains(elapsed.seconds), elapsed.attoseconds >= 0 else { return }
        let milliseconds = Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        let outcome: TelemetryOutcome = failure == .cancelled ? .cancelled : (failure == nil ? .succeeded : .failed)
        let event = TelemetryEvent.operationFinished(span.operation, span.id, outcome, milliseconds, failure)
        if span.consentGeneration == consentGeneration {
            capture(event)
            if recordsFeature, outcome == .succeeded, let feature = TelemetryFeature(operation: span.operation) {
                capture(.featureUsed(feature))
            }
        } else {
            recordLocally(event)
        }
    }

    /// Records an operation issue, retaining it locally when its related span belongs to an earlier consent generation.
    func issue(_ operation: TelemetryOperation, _ failure: TelemetryFailure, relatedTo span: TelemetrySpan? = nil) {
        let event = TelemetryEvent.issue(operation, failure, span?.id)
        if let span, span.consentGeneration != consentGeneration {
            recordLocally(event)
        } else {
            capture(event)
        }
    }

    /// Keeps at most 100 diagnostic records and logs bounded operation and error identifiers independently of remote sharing.
    private func recordLocally(_ event: TelemetryEvent) {
        guard event.isDiagnostic else { return }
        var properties = diagnosticContext
        properties.merge(event.properties) { _, new in new }
        recentDiagnostics.append(.init(timestamp: Date(), event: event.name,
            properties: properties.mapValues { String(describing: $0) }))
        if recentDiagnostics.count > 100 { recentDiagnostics.removeFirst(recentDiagnostics.count - 100) }
        let operation = event.properties["operation"] as? String ?? "unknown"
        let code = event.properties["error_code"] as? String ?? "none"
        if code != "none", code != "cancelled" {
            logger.error("\(event.name, privacy: .public) operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
        } else {
            logger.info("\(event.name, privacy: .public) operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
        }
    }

    private var diagnosticContext: [String: Any] {
        Self.diagnosticContext(sessionID: sessionID)
    }

    /// Builds app, OS, architecture and diagnostic-session metadata without user content.
    static func diagnosticContext(sessionID: UUID) -> [String: Any] {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ["schema_version": 2, "app": "intents", "platform": "macOS", "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os_major": version.majorVersion, "os_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "architecture": architecture, "diagnostic_session_id": sessionID.uuidString]
    }

    /// Asks the current client to flush pending events without treating the request as delivery confirmation.
    func flushPendingEvents() { client?.flush() }

    /// Exports sharing preferences, delivery status and recent local diagnostics as JSON; returns an empty object on encoding failure.
    func diagnosticReport() -> String {
        struct Report: Encodable {
            let schemaVersion = 1
            let usageSharing: Bool
            let diagnosticSharing: Bool
            let delivery: TelemetryDelivery
            let events: [TelemetryDiagnosticRecord]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(Report(usageSharing: isEnabled,
            diagnosticSharing: diagnosticsEnabled, delivery: delivery, events: recentDiagnostics)), encoding: .utf8)) ?? "{}"
    }

}

@MainActor
final class PostHogTelemetryClient: TelemetryClient {
    private let sdk: PostHogSDK
    private let transport: TelemetryTransport
    private let storageURL: URL
    private let sessionID: UUID
    private let consentEpoch: UUID
    private let pendingCrashes: TelemetryPendingCrashReports?

    /// Configures a bounded PostHog queue and consent-filtered transport with automatic lifecycle and screen capture disabled.
    /// Native crash capture starts only when approved diagnostic storage prepares successfully; the consent epoch also governs replayed events.
    init(configuration: TelemetryConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         makeSDK: (PostHogConfig) -> PostHogSDK = { PostHogSDK.with($0) }) {
        consentEpoch = configuration.consentEpoch
        pendingCrashes = TelemetryPendingCrashReports.eligible
        sessionID = configuration.diagnosticSessionID ?? UUID()
        transport = TelemetryTransport(host: configuration.host, sessionConfiguration: sessionConfiguration,
            allowsUsage: configuration.usageEnabled, allowsDiagnostics: configuration.diagnosticsEnabled,
            consentEpoch: configuration.consentEpoch)
        // This path is the SDK's project-specific store in pinned PostHog 3.71.4.
        storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "")
            .appendingPathComponent(configuration.projectToken)
        // Preserve the bounded SDK queue so offline/short sessions can retry after relaunch.
        let config = PostHogConfig(projectToken: configuration.projectToken, host: configuration.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        // Production eligibility is checked before any native handler is installed.
        var preparedCrashStore = false
        if configuration.diagnosticsEnabled, let pendingCrashes {
            do { try pendingCrashes.prepare(); preparedCrashStore = true } catch { }
        }
        config.errorTrackingConfig.autoCapture = preparedCrashStore
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.errorTrackingConfig.inAppByDefault = false
        config.errorTrackingConfig.inAppIncludes = ["FoundationEvals", "Intents", "com.coryparry.FoundationEvals"]
        config.flushAt = 1
        // Several offline native stacks can exceed the final transport's 256 KiB
        // bound when replayed together. Keep diagnostic batches independently bounded.
        if configuration.diagnosticsEnabled { config.maxBatchSize = 1 }
        config.flushIntervalSeconds = 10
        config.maxQueueSize = 50
        config.urlSessionConfiguration = transport.configuration
        let sessionRecovery = TelemetryUsageSessionRecovery()
        let filter = TelemetryPayloadFilter.beforeSend(usage: configuration.usageEnabled,
            diagnostics: configuration.diagnosticsEnabled, consentEpoch: configuration.consentEpoch)
        config.setBeforeSend { @Sendable event in
            guard let event = filter(event) else { return nil }
            return sessionRecovery.recoverSession(for: event)
        }
        sdk = makeSDK(config)
        sessionRecovery.attach(sdk)
        // App consent is authoritative. A failed queue-directory deletion after
        // revocation can leave the SDK's persisted opt-out flag behind.
        // The transport still rejects every record from an earlier consent epoch.
        sdk.optIn()
        if configuration.diagnosticsEnabled {
            // The SDK persists this context in the native report. Pending reports
            // bypass buildProperties, preserving the crashed build and session.
            var context = TelemetryController.diagnosticContext(sessionID: sessionID)
            context["environment"] = "production"
            context["_intents_consent_epoch"] = consentEpoch.uuidString
            context["_intents_crash_capture"] = true
            sdk.register(context)
        }
    }

    /// Adds bounded app context and the current consent epoch before passing an event to PostHog.
    /// Usage events omit the diagnostic-session identifier.
    func capture(_ event: TelemetryEvent) {
        var properties = TelemetryController.diagnosticContext(sessionID: sessionID)
        if !event.isDiagnostic { properties.removeValue(forKey: "diagnostic_session_id") }
        properties["environment"] = "production"
        properties.merge(event.properties) { _, new in new }
        properties["_intents_consent_epoch"] = consentEpoch.uuidString
        sdk.capture(event.name, properties: properties)
    }

    var analyticsSessionID: String? { sdk.getSessionId() }

    /// Requests a PostHog flush without asserting upload success.
    func flush() { sdk.flush() }

    /// Forwards delivery-state callback registration to the consent-bound transport.
    func setDeliveryHandler(_ handler: @escaping @Sendable (TelemetryDelivery) -> Void) {
        transport.setDeliveryHandler(handler)
    }

    /// Stops transport and SDK delivery, discards pending crashes and removes project queue files.
    /// Retains anonymous identity; consent epochs revoke stale queued events even when best-effort deletion fails.
    func stopAndDiscard() {
        transport.stop()
        sdk.optOut()
        sdk.close()
        pendingCrashes?.discard()
        // Purge only this project's queues; retain the persisted anonymous identity.
        // Consent epochs still revoke every stale event if deletion fails.
        for name in ["posthog.queueFolder.uuid", "posthog.queueFolder", "posthog.queue.plist",
                     "posthog.replayFolder.uuid", "posthog.replayFolder", "posthog.replayBufferFolder", "posthog.logsFolder"] {
            try? FileManager.default.removeItem(at: storageURL.appendingPathComponent(name))
        }
    }
}

/// Recovers attribution for explicit usage after the SDK expires a background session.
/// The SDK owns expiry and valid sessions; diagnostic capture never creates one here.
private final class TelemetryUsageSessionRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sdk: PostHogSDK?

    /// Binds the configured SDK without creating a retention cycle through its callback.
    func attach(_ sdk: PostHogSDK) {
        lock.withLock { self.sdk = sdk }
    }

    /// Adds a valid SDK session only to an already consent-filtered usage event missing one.
    /// PostHog 3.71.4 releases its session and before-send locks before this callback;
    /// starting a session updates crash context but does not capture another event.
    func recoverSession(for event: PostHogEvent) -> PostHogEvent {
        guard !TelemetryEvent.isDiagnostic(name: event.event),
              (event.properties["$session_id"] as? String).flatMap(UUID.init(uuidString:)) == nil else { return event }
        lock.withLock {
            guard let sdk else { return }
            if sdk.getSessionId().flatMap(UUID.init(uuidString:)) == nil { sdk.startSession() }
            if let session = sdk.getSessionId(), UUID(uuidString: session) != nil {
                event.properties["$session_id"] = session
            }
        }
        return event
    }
}
