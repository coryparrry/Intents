import Foundation
import Observation
import PostHog

struct TelemetryConfiguration {
    let projectToken: String
    let host: String

    static var bundled: Self? {
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
    func capture(_ event: TelemetryEvent)
    func stopAndDiscard()
}

@Observable @MainActor
final class TelemetryController {
    static let consentKey = "optionalTelemetryEnabled"
    private(set) var isEnabled: Bool
    var isConfigured: Bool { configuration != nil }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let configuration: TelemetryConfiguration?
    @ObservationIgnored private let makeClient: @MainActor (TelemetryConfiguration) -> any TelemetryClient
    @ObservationIgnored private var client: (any TelemetryClient)?

    init(defaults: UserDefaults = .standard, configuration: TelemetryConfiguration? = .bundled,
         makeClient: @escaping @MainActor (TelemetryConfiguration) -> any TelemetryClient = { PostHogTelemetryClient(configuration: $0) }) {
        self.defaults = defaults
        self.configuration = configuration
        self.makeClient = makeClient
        let preference = defaults.object(forKey: Self.consentKey) as? Bool ?? true
        isEnabled = preference && configuration != nil
        if isEnabled, let configuration { client = makeClient(configuration) }
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || isConfigured else { return }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.consentKey)
        if enabled, let configuration {
            client = makeClient(configuration)
        } else {
            client?.stopAndDiscard()
            client = nil
        }
    }

    func capture(_ event: TelemetryEvent) {
        guard isEnabled else { return }
        client?.capture(event)
    }
}

@MainActor
private final class PostHogTelemetryClient: TelemetryClient {
    private let sdk: PostHogSDK
    private let transport: TelemetryTransport
    private let storageURL: URL

    init(configuration: TelemetryConfiguration) {
        transport = TelemetryTransport(host: configuration.host)
        // This path is the SDK's project-specific store in pinned PostHog 3.71.4.
        storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "")
            .appendingPathComponent(configuration.projectToken)
        // Discard interrupted batches while preserving the anonymous installation ID.
        for name in ["posthog.queueFolder.uuid", "posthog.replayFolder.uuid", "posthog.logsFolder"] {
            try? FileManager.default.removeItem(at: storageURL.appendingPathComponent(name))
        }
        let config = PostHogConfig(projectToken: configuration.projectToken, host: configuration.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.errorTrackingConfig.autoCapture = false
        config.flushAt = 10
        config.maxQueueSize = 50
        config.urlSessionConfiguration = transport.configuration
        config.setBeforeSend { event in
            guard let allowed = TelemetryEvent.allowedProperties(for: event.event) else { return nil }
            event.properties = event.properties.filter { allowed.contains($0.key) }
            event.properties["$process_person_profile"] = false
            event.properties["$geoip_disable"] = true
            return event
        }
        sdk = PostHogSDK.with(config)
    }

    func capture(_ event: TelemetryEvent) {
        var properties: [String: Any] = [:]
        properties["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        properties["os_major"] = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        sdk.capture(event.name, properties: properties)
    }

    func stopAndDiscard() {
        transport.stop()
        sdk.optOut()
        sdk.close()
        try? FileManager.default.removeItem(at: storageURL)
    }
}

/// A per-consent transport: remote config and all non-event endpoints never reach the network.
/// Revocation invalidates its session, including requests already queued by the SDK.
final class TelemetryTransport: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var transports: [String: TelemetryTransport] = [:]
    private let id = UUID().uuidString
    private let host: String?
    private let session: URLSession
    private var stopped = false
    private let lock = NSLock()

    init(host: String, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: sessionConfiguration, delegate: TelemetryRedirectBlocker(), delegateQueue: nil)
        self.host = URL(string: host)?.host
        Self.lock.withLock { Self.transports[id] = self }
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Foundation-Telemetry-Session": id]
        return configuration
    }

    static func lookup(_ request: URLRequest) -> TelemetryTransport? {
        guard let id = request.value(forHTTPHeaderField: "X-Foundation-Telemetry-Session") else { return nil }
        return lock.withLock { transports[id] }
    }

    func send(_ request: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionDataTask? {
        lock.withLock {
            guard !stopped, request.url?.host == host, request.url?.scheme == "https",
                  request.url?.path == "/batch", request.httpMethod == "POST" else { return nil }
            var request = request
            request.setValue(nil, forHTTPHeaderField: "X-Foundation-Telemetry-Session")
            let task = session.dataTask(with: request, completionHandler: completion)
            task.resume()
            return task
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            session.invalidateAndCancel()
        }
        Self.lock.withLock { _ = Self.transports.removeValue(forKey: id) }
    }
}

private final class TelemetryURLProtocol: URLProtocol, @unchecked Sendable {
    private var forwardingTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        forwardingTask = TelemetryTransport.lookup(request)?.send(request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { client?.urlProtocol(self, didFailWithError: error); return }
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if forwardingTask == nil { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }
    override func stopLoading() { forwardingTask?.cancel() }
}

private final class TelemetryRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
