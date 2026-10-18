import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct IntentLabFeatureGateTests {
    @Test func startsDisabledAndRequiresFreshExplicitEnable() async {
        var date = Date()
        let gate = IntentLabFeatureGate(load: { true }, now: { date })
        #expect(!gate.isEnabled)
        await gate.refresh()
        #expect(gate.isEnabled)
        date = date.addingTimeInterval(91)
        #expect(!gate.isEnabled)
        await gate.refresh()
        #expect(gate.isEnabled)
        #expect(!IntentLabFeatureGate(load: { true }).isEnabled)
    }

    @Test func refreshFailureRevokesPriorEnable() async {
        actor Decisions {
            var first = true
            func next() throws -> Bool {
                if first { first = false; return true }
                throw URLError(.notConnectedToInternet)
            }
        }
        let decisions = Decisions()
        let gate = IntentLabFeatureGate(load: { try await decisions.next() })
        await gate.refresh()
        #expect(gate.isEnabled)
        await gate.refresh()
        #expect(!gate.isEnabled)
    }

    @Test func remoteFalseRevokesPriorEnable() async {
        actor Decisions {
            var first = true
            func next() -> Bool { defer { first = false }; return first }
        }
        let decisions = Decisions()
        let gate = IntentLabFeatureGate(load: { await decisions.next() })
        await gate.refresh()
        #expect(gate.isEnabled)
        await gate.refresh()
        #expect(!gate.isEnabled)
    }

    @Test func cancelledRefreshCannotEnableFeature() async {
        let gate = IntentLabFeatureGate(load: { true })
        let task = Task { await gate.refresh() }
        task.cancel()
        await task.value
        #expect(!gate.isEnabled)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"flags":{}}"#,
        #"{"flags":{"intents-intent-lab":{"enabled":false}}}"#,
        #"{"flags":{"intents-intent-lab":{"enabled":"true"}}}"#,
        #"{"flags":{"intents-intent-lab":{"enabled":true,"failed":true}}}"#,
        #"{"errorsWhileComputingFlags":true,"flags":{"intents-intent-lab":{"enabled":true}}}"#,
        #"{"featureFlags":{"intents-intent-lab":true}}"#,
        "invalid JSON",
    ]) func invalidOrDisabledDecisionsFailClosed(_ json: String) {
        #expect(!IntentLabFeatureGate.permitsIntentLab(Data(json.utf8)))
    }

    @Test func explicitBooleanEnableIsAccepted() {
        #expect(IntentLabFeatureGate.permitsIntentLab(Data(
            #"{"errorsWhileComputingFlags":false,"flags":{"intents-intent-lab":{"enabled":true}}}"#.utf8)))
    }

    @Test(arguments: ["enabled.test", "disabled.test", "server-error.test", "network-error.test"])
    func evaluatesFlagWithoutAnalyticsOrInstallationIdentity(_ host: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntentLabFlagProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let enabled = try await IntentLabFeatureGate.fetch(token: "public-test-token",
                host: URL(string: "https://\(host)")!, session: session)
            #expect(enabled == (host == "enabled.test"))
        } catch {
            #expect(host == "network-error.test")
        }
    }
}

private final class IntentLabFlagProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://\(request.url!.host!)/flags/?v=2")
        #expect(request.url?.query == "v=2")
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = stream.read(&bytes, maxLength: bytes.count)
            body = Data(bytes.prefix(max(0, count)))
        } else { body = Data() }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        #expect(Set(payload?.keys.map { $0 } ?? []) == ["api_key", "distinct_id", "flag_keys"])
        #expect(payload?["distinct_id"] as? String == "intents-macos-release")
        #expect(payload?["flag_keys"] as? [String] == ["intents-intent-lab"])
        let host = request.url!.host!
        if host == "network-error.test" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = host == "server-error.test" ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let enabled = host != "disabled.test"
        client?.urlProtocol(self, didLoad: Data("{\"flags\":{\"intents-intent-lab\":{\"enabled\":\(enabled)}}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
