import Foundation
@testable import PostHog

final class LocalProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        if request.url?.path.hasPrefix("/batch") == true, !data.isEmpty {
            try? data.write(to: URL(fileURLWithPath: "/tmp/intents-native-crash-fixture/sent.json"))
        }
        let responseData = Data("{\"errorTracking\":{\"autocaptureExceptions\":true}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Fixture {
    static let epoch1 = "00000000-0000-4000-8000-000000000001"
    static let epoch2 = "00000000-0000-4000-8000-000000000002"
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.plausiblelabs.crashreporter.data")
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
    }
    static func sdk(epoch: String, build: String) -> PostHogSDK {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = PostHogConfig(projectToken: "phc_isolated_native_crash_fixture_20261010", host: "https://telemetry.invalid")
        config.debug = true
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.disableReachabilityForTesting = true
        config.errorTrackingConfig.autoCapture = true
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.flushAt = 1
        config.flushIntervalSeconds = 1
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [LocalProtocol.self]
        config.urlSessionConfiguration = session
        config.setBeforeSend { event in
            print("FILTER", event.event, "epoch", event.properties["_intents_consent_epoch"] ?? "nil", "level", event.properties["$exception_level"] ?? "nil", "keys", event.properties.keys.sorted())
            guard event.event == "$exception", event.properties["_intents_consent_epoch"] as? String == epoch,
                  let safe = TelemetryCrashPrivacy.properties(event.properties) else { return nil }
            var props = safe
            for key in ["app_build", "app_version", "$session_id"] { props[key] = event.properties[key] }
            return PostHogEvent(event: event.event, distinctId: event.distinctId, properties: props, timestamp: event.timestamp)
        }
        let sdk = PostHogSDK.with(config)
        sdk.optIn()
        sdk.register(["app_build": build, "app_version": "fixture-1", "_intents_consent_epoch": epoch, "_intents_crash_capture": true])
        return sdk
    }
    static func main() {
        let mode = CommandLine.arguments[1]
        var current = sdk(epoch: mode == "upload-reenabled" ? epoch2 : epoch1, build: mode.hasPrefix("upload") ? "current-build" : "crashed-build")
        if mode == "crash-off" || mode == "crash-reenabled" {
            current.optOut(); current.close()
            try! FileManager.default.removeItem(at: directory)
            if mode == "crash-reenabled" { current = sdk(epoch: epoch2, build: "reenabled-build") }
        }
        if mode.hasPrefix("upload") {
            current.flush()
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !FileManager.default.fileExists(atPath: "/tmp/intents-native-crash-fixture/sent.json") {
                current.flush()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            current.close()
            return
        }
        NSException(name: NSExceptionName("PRIVATE_CONTENT"), reason: "PRIVATE_CONTENT", userInfo: ["prompt": "PRIVATE_CONTENT"]).raise()
    }
}
