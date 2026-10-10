import Foundation
import Testing
@testable import PostHog
@testable import FoundationEvals

@MainActor struct TelemetryCrashTests {
    nonisolated static func report(epoch: UUID, imageID: UUID = UUID()) -> [String: Any] {
        ["app": "intents", "environment": "production", "platform": "macOS", "schema_version": 2,
         "app_version": "1.0", "app_build": "8", "_intents_consent_epoch": epoch.uuidString,
         "_intents_crash_capture": true, "$session_id": UUID().uuidString,
         "private": "PRIVATE_CONTENT", "$exception_steps": [["message": "PRIVATE_CONTENT"]],
         "$exception_level": "fatal", "$exception_list": [[
            "type": "PRIVATE_CONTENT", "value": "PRIVATE_CONTENT", "userInfo": ["prompt": "PRIVATE_CONTENT"],
            "mechanism": ["type": "nsexception", "handled": false, "meta": ["reason": "PRIVATE_CONTENT"]],
            "stacktrace": ["type": "raw", "registers": ["data": "PRIVATE_CONTENT"], "frames": [[
                "instruction_addr": "0x0000000100000100", "image_addr": "0x0000000100000000",
                "symbol_addr": "0x0000000100000080", "in_app": true, "function": "PRIVATE_CONTENT",
                "module": "PRIVATE_CONTENT", "filename": "/Users/PRIVATE_CONTENT", "vars": ["text": "PRIVATE_CONTENT"]]]]]],
         "$debug_images": [["type": "macho", "code_file": "/Users/PRIVATE_CONTENT/Intents",
            "debug_id": imageID.uuidString, "image_addr": "0x0000000100000000", "image_size": 1_024,
            "image_vmaddr": "0x0000000100000000", "arch": "arm64", "private": "PRIVATE_CONTENT"]]]
    }

    @Test func exactBackgroundFilterPreservesSymbolicationAndRemovesContent() async throws {
        let epoch = UUID(), imageID = UUID(), id = UUID().uuidString
        let passed = await Task.detached {
            let filter = TelemetryPayloadFilter.beforeSend(usage: false, diagnostics: true, consentEpoch: epoch)
            let event = PostHogEvent(event: "$exception", distinctId: id, properties: Self.report(epoch: epoch, imageID: imageID))
            guard let safe = filter(event), let final = TelemetryPayloadFilter.properties(safe.properties, event: safe.event),
                  let data = try? JSONSerialization.data(withJSONObject: final) else { return false }
            let exceptions = final["$exception_list"] as? [[String: Any]]
            let frames = (exceptions?.first?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]]
            let images = final["$debug_images"] as? [[String: Any]]
            return !String(decoding: data, as: UTF8.self).contains("PRIVATE_CONTENT")
                && exceptions?.first?["type"] as? String == "NSException"
                && frames?.first?["instruction_addr"] as? String == "0x100000100"
                && frames?.first?["symbol_addr"] as? String == "0x100000080"
                && images?.first?["debug_id"] as? String == imageID.uuidString
                && images?.first?["image_addr"] as? String == "0x100000000"
                && images?.first?["code_file"] as? String == "native-image"
                && final["app_build"] as? String == "8"
                && final["_intents_crash_capture"] == nil && final["_intents_consent_epoch"] == nil
        }.value
        #expect(passed)
    }

    @Test func consentAndCrashTimeContextFailClosed() {
        let epoch = UUID(), raw = Self.report(epoch: epoch)
        func event(_ properties: [String: Any]) -> PostHogEvent { .init(event: "$exception", distinctId: UUID().uuidString, properties: properties) }
        #expect(TelemetryEvent.isDiagnostic(name: "$exception"))
        #expect(TelemetryPayloadFilter.beforeSend(usage: true, diagnostics: false, consentEpoch: epoch)(event(raw)) == nil)
        #expect(TelemetryPayloadFilter.beforeSend(usage: false, diagnostics: true, consentEpoch: UUID())(event(raw)) == nil)
        for key in ["_intents_crash_capture", "_intents_consent_epoch", "app", "environment", "platform", "schema_version", "app_build", "app_version"] {
            var missing = raw; missing.removeValue(forKey: key)
            #expect(TelemetryPayloadFilter.properties(missing, event: "$exception") == nil)
        }
        var handled = raw; handled["$exception_level"] = "error"
        #expect(TelemetryPayloadFilter.properties(handled, event: "$exception") == nil)
        var mixed = raw; mixed["environment"] = "development"
        #expect(TelemetryPayloadFilter.properties(mixed, event: "$exception") == nil)
    }

    @Test func malformedAddressesImagesAndOversizedStacksAreBounded() throws {
        let epoch = UUID()
        var raw = Self.report(epoch: epoch)
        var exceptions = try #require(raw["$exception_list"] as? [[String: Any]])
        var frames = (0..<300).map { ["instruction_addr": "0x" + String($0 + 1, radix: 16), "image_addr": "0x100000000"] }
        frames.append(["instruction_addr": "PRIVATE_CONTENT"])
        exceptions[0]["stacktrace"] = ["frames": frames]
        raw["$exception_list"] = exceptions
        var images = try #require(raw["$debug_images"] as? [[String: Any]])
        images[0]["image_size"] = true
        raw["$debug_images"] = images
        let safe = try #require(TelemetryCrashPrivacy.properties(raw))
        let safeExceptions = try #require(safe["$exception_list"] as? [[String: Any]])
        let safeFrames = try #require((safeExceptions[0]["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        #expect(safeFrames.count == 255)
        #expect(safeFrames.last?["instruction_addr"] as? String == "0x12c")
        #expect(safe["$debug_images"] == nil)
        for address in ["0xFFFFFFFFFFFFFFFFF", "PRIVATE_CONTENT", "0x", "0x-1", "0x１２"] {
            exceptions[0]["stacktrace"] = ["frames": [["instruction_addr": address]]]
            raw["$exception_list"] = exceptions
            let sanitized = try #require(TelemetryCrashPrivacy.properties(raw))
            let entries = try #require(sanitized["$exception_list"] as? [[String: Any]])
            #expect(entries[0]["stacktrace"] == nil)
        }
    }

    @Test func optOutClearsOnlyThisAppsPendingStoreAndPreventsNewFileWrites() throws {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let owned = TelemetryPendingCrashReports(cacheDirectory: cache, bundleIdentifier: "example.Intents")
        let other = TelemetryPendingCrashReports(cacheDirectory: cache, bundleIdentifier: "example.Other")
        try owned.prepare(); try other.prepare()
        let live = owned.directory.appendingPathComponent("live_report.plcrash")
        let neighbor = other.directory.appendingPathComponent("live_report.plcrash")
        try Data("crash".utf8).write(to: live); try Data("other".utf8).write(to: neighbor)
        owned.discard()
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(throws: (any Error).self) { try Data("off-consent".utf8).write(to: live) }
        #expect(try Data(contentsOf: neighbor) == Data("other".utf8))
        try owned.prepare()
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(TelemetryPendingCrashReports.eligible == nil) // Hosted Debug tests never touch the production crash cache.
    }

    @Test func controllerPurgesAtDisabledStartupAndEveryConsentGeneration() throws {
        let name = "CrashConsent.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var purges = 0
        let controller = TelemetryController(defaults: defaults, configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in DiagnosticRecordingClient() }, discardPendingCrashes: { purges += 1 })
        #expect(purges == 1)
        controller.setDiagnosticsEnabled(true)
        #expect(purges == 2)
        controller.setDiagnosticsEnabled(false)
        #expect(purges == 3)
        controller.setDiagnosticsEnabled(true)
        #expect(purges == 4)
        controller.setEnabled(false)
        #expect(controller.diagnosticsEnabled)
        #expect(purges == 5)
    }
}

@Suite(.serialized) @MainActor struct TelemetryCrashSDKTests {
    @Test func actualSDKPendingReportPathPreservesCrashedBuildAndFiltersAtTransport() async throws {
        let token = "phc_crash_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "").appendingPathComponent(token)
        defer { try? FileManager.default.removeItem(at: storage) }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CrashRecordingProtocol.self]
        CrashRecordingProtocol.clear()
        let epoch = UUID(), imageID = UUID(), crashedID = UUID().uuidString
        var sdk: PostHogSDK?
        let client = PostHogTelemetryClient(configuration: .init(projectToken: token, host: "https://telemetry.invalid", diagnosticsEnabled: true, consentEpoch: epoch),
            sessionConfiguration: session, makeSDK: { config in
                #expect(!config.errorTrackingConfig.autoCapture)
                #expect(!config.errorTrackingConfig.exceptionSteps.enabled)
                #expect(config.maxBatchSize == 1)
                config.disableReachabilityForTesting = true
                let created = PostHogSDK.with(config); sdk = created; return created
            })
        defer { client.stopAndDiscard() }
        let actualSDK = try #require(sdk)
        // This is the exact SDK call used by automatic pending-report processing.
        actualSDK.captureInternal("$exception", distinctId: crashedID,
            properties: TelemetryCrashTests.report(epoch: epoch, imageID: imageID), timestamp: Date(), skipBuildProperties: true)
        client.flush()
        let deadline = Date().addingTimeInterval(10)
        while CrashRecordingProtocol.bodies().isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            client.flush()
        }
        let data = try #require(CrashRecordingProtocol.bodies().first)
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_CONTENT"))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(body["batch"] as? [[String: Any]])
        let crash = try #require(events.first)
        #expect(crash["event"] as? String == "$exception")
        #expect(crash["distinct_id"] as? String == crashedID)
        let properties = try #require(crash["properties"] as? [String: Any])
        #expect(properties["app_build"] as? String == "8")
        #expect(properties["app_version"] as? String == "1.0")
        #expect(properties["$debug_images"] != nil)
        #expect(properties["_intents_consent_epoch"] == nil)
        #expect(properties["_intents_crash_capture"] == nil)
        // A report from before opt-out must not be recaptured by the new generation.
        actualSDK.captureInternal("$exception", distinctId: crashedID,
            properties: TelemetryCrashTests.report(epoch: UUID()), timestamp: Date(), skipBuildProperties: true)
        client.flush()
        try await Task.sleep(for: .milliseconds(50))
        #expect(CrashRecordingProtocol.bodies().count == 1)
        // A retained backlog of deep native stacks must not become one oversized,
        // permanently rejected batch. Each bounded crash can be delivered alone.
        var deep = TelemetryCrashTests.report(epoch: epoch, imageID: imageID)
        var entry = try #require((deep["$exception_list"] as? [[String: Any]])?.first)
        entry["stacktrace"] = ["frames": (0..<256).map { i in
            ["instruction_addr": "0x" + String(0x100000100 + i, radix: 16), "image_addr": "0x100000000",
             "symbol_addr": "0x100000080", "function": "PRIVATE_CONTENT"]
        }]
        deep["$exception_list"] = Array(repeating: entry, count: 4)
        for _ in 0..<3 {
            actualSDK.captureInternal("$exception", distinctId: crashedID, properties: deep,
                timestamp: Date(), skipBuildProperties: true)
        }
        let backlogDeadline = Date().addingTimeInterval(10)
        while CrashRecordingProtocol.bodies().count < 4 && Date() < backlogDeadline {
            try await Task.sleep(for: .milliseconds(100)); client.flush()
        }
        #expect(CrashRecordingProtocol.bodies().count == 4)
        #expect(CrashRecordingProtocol.bodies().dropFirst().reduce(0) { $0 + $1.count } > 262_144)
        for body in CrashRecordingProtocol.bodies() {
            #expect(body.count <= 262_144)
            #expect(!String(decoding: body, as: UTF8.self).contains("PRIVATE_CONTENT"))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect((payload["batch"] as? [Any])?.count == 1)
        }
    }
}

private final class CrashRecordingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []
    static func clear() { lock.withLock { captured = [] } }
    static func bodies() -> [Data] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        if !body.isEmpty { Self.lock.withLock { Self.captured.append(body) } }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
