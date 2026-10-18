import Foundation
import Observation

/// Release control is independent of optional analytics. No events or user identifiers are sent.
@MainActor @Observable
final class IntentLabFeatureGate {
    nonisolated static let key = "intents-intent-lab"
    nonisolated static let unavailableMessage = "Intent Lab is currently unavailable."
    private var enabledUntil: Date = .distantPast
    var isEnabled: Bool { enabledUntil > now() }
    @ObservationIgnored private let load: @Sendable () async throws -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(load: @escaping @Sendable () async throws -> Bool = { try await fetchBundledFlag() },
         now: @escaping () -> Date = Date.init) {
        self.load = load
        self.now = now
        if Self.isUITestEnabled { enabledUntil = now().addingTimeInterval(90) }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let enabled = try await load()
            enabledUntil = enabled && !Task.isCancelled ? now().addingTimeInterval(90) : .distantPast
        } catch {
            enabledUntil = .distantPast
        }
        expiryTask?.cancel()
        if isEnabled {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.enabledUntil = .distantPast
            }
        }
    }

    deinit { expiryTask?.cancel() }

    nonisolated private static var isUITestEnabled: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--enable-intent-lab-for-testing") && arguments.contains("--evaluation-storage")
        #else
        return false
        #endif
    }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }

    nonisolated static func fetchBundledFlag() async throws -> Bool {
        #if DEBUG
        // Development and hosted tests must explicitly inject their release decision.
        return isUITestEnabled
        #else
        guard !ProcessInfo.processInfo.arguments.contains("--production-worker-store"),
              ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
              let token = Bundle.main.object(forInfoDictionaryKey: "PostHogProjectToken") as? String,
              let host = Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String,
              let url = URL(string: host), url.scheme == "https", url.host != nil else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await fetch(token: token, host: url, session: session)
        #endif
    }

    nonisolated static func fetch(token: String, host: URL, session: URLSession) async throws -> Bool {
        var url = URLComponents(url: host.appendingPathComponent("flags/"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "v", value: "2")]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A single shared release identity deliberately provides no installation/user targeting.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": token, "distinct_id": "intents-macos-release", "flag_keys": [key],
        ])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 262_144 else { return false }
        return permitsIntentLab(data)
    }

    nonisolated static func permitsIntentLab(_ data: Data) -> Bool {
        struct Response: Decodable {
            struct Flag: Decodable { let enabled: Bool; let failed: Bool? }
            let errorsWhileComputingFlags: Bool?
            let flags: [String: Flag]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.errorsWhileComputingFlags != true,
              let flag = response.flags[key], flag.failed != true else { return false }
        return flag.enabled
    }
}
