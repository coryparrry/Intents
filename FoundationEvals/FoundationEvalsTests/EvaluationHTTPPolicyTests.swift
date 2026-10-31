import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationHTTPPolicyTests {
    /// Covers the tool, model, ordinary judge and thinking-judge timeout ranges without changing isolation settings.
    @Test(arguments: [0.1, 12.0, 30.0, 300.0])
    func isolatedConfigurationPreservesTimeoutAndDisablesSharedState(timeout: TimeInterval) {
        let configuration = EvaluationHTTPPolicy.isolatedConfiguration(timeout: timeout)
        #expect(configuration.timeoutIntervalForRequest == timeout)
        #expect(configuration.timeoutIntervalForResource == timeout)
        #expect(configuration.identifier == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
    }

    /// A caller's configuration changes must not become defaults for another request owner.
    @Test func isolatedConfigurationsDoNotShareMutableSettings() {
        let first = EvaluationHTTPPolicy.isolatedConfiguration(timeout: 12)
        first.httpAdditionalHeaders = ["X-Injected-Policy": "first"]
        first.httpShouldSetCookies = true
        first.connectionProxyDictionary = ["HTTPEnable": 1]
        let second = EvaluationHTTPPolicy.isolatedConfiguration(timeout: 30)
        #expect(second.httpAdditionalHeaders?["X-Injected-Policy"] == nil)
        #expect(!second.httpShouldSetCookies)
        #expect(second.connectionProxyDictionary?.isEmpty == true)
        #expect(first.timeoutIntervalForRequest == 12)
        #expect(second.timeoutIntervalForRequest == 30)
    }

    /// Exercises the actual session delegate decision for all redirect statuses, including requests carrying credentials.
    @Test(arguments: [301, 302, 303, 307, 308])
    func isolatedSessionDeclinesRedirects(status: Int) async throws {
        let session = EvaluationHTTPPolicy.isolatedSession(timeout: 12)
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.timeoutIntervalForRequest == 12)
        #expect(session.configuration.urlCache == nil)
        let delegate = try #require(session.delegate as? EvaluationNoRedirectDelegate)
        let source = URL(string: "https://configured.invalid/generate")!
        let task = session.dataTask(with: source)
        let response = try #require(HTTPURLResponse(url: source, statusCode: status,
            httpVersion: nil, headerFields: ["Location": "https://other.invalid/collect"]))
        var redirected = URLRequest(url: URL(string: "https://other.invalid/collect")!)
        redirected.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        await confirmation("The redirect decision refuses the replacement request") { refused in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: redirected) { replacement in
                    #expect(replacement == nil)
                    refused()
                }
        }
    }

    /// The custom tool must use an injected session and preserve its response validation and error propagation.
    @Test func customToolRetainsInjectedSessionBehavior() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvaluationHTTPPolicyProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Injected-Policy": "preserved"]
        let client = EvaluationLocalHTTPToolClient(session: URLSession(configuration: configuration))
        let output = try await client.post(body: Data("{}".utf8),
            to: URL(string: "https://injected.invalid/success")!)
        #expect(output == "POST:application/json:preserved:none")
        do {
            _ = try await client.post(body: Data("{}".utf8),
                to: URL(string: "https://injected.invalid/rejected")!)
            Issue.record("Expected the injected session's HTTP status to remain an error.")
        } catch EvaluationCustomToolError.httpStatus(let status) {
            #expect(status == 418)
        }
    }

    /// The judge's transport seam must keep the request timeout and authorization and propagate transport failures.
    @Test func compatibleJudgeRetainsInjectedTransportFailure() async throws {
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Injected", kind: .customCompatible,
            baseURL: "https://injected.invalid/v1", modelID: "fixture", requestTimeoutSeconds: 12)
        let client = EvaluationCompatibleJudgeClient { request in
            #expect(request.timeoutInterval == 12)
            #expect(request.url?.path == "/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await client.checkConnection(.init(connection: connection, apiKey: "fixture-secret"))
            Issue.record("Expected the injected transport failure to propagate.")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        }
    }

    /// Telemetry must keep the caller's forwarding protocol and headers while removing its private routing header.
    @Test func telemetryRetainsInjectedConfiguration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvaluationHTTPPolicyProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Injected-Policy": "preserved"]
        let transport = TelemetryTransport(host: "https://injected.invalid", sessionConfiguration: configuration)
        defer { transport.stop() }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://injected.invalid/batch")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = Data("{\"batch\":[{\"event\":\"foundation_evals_app_opened\"}]}".utf8)
        let (data, response) = try await session.upload(for: request, from: payload)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "POST:application/json:preserved:none")
    }
}

private final class EvaluationHTTPPolicyProtocol: URLProtocol, @unchecked Sendable {
    /// Handles only the injected fixture host, so these tests never use a real network endpoint.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "injected.invalid" }
    /// Leaves the request intact so the response can expose its injected headers.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// Echoes request metadata or returns a failing status to exercise the caller's own response handling.
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/rejected" ? 418 : 200,
            httpVersion: nil, headerFields: nil)!
        let output = [request.httpMethod ?? "none", request.value(forHTTPHeaderField: "Content-Type") ?? "none",
            request.value(forHTTPHeaderField: "X-Injected-Policy") ?? "none",
            request.value(forHTTPHeaderField: "X-Foundation-Telemetry-Session") ?? "none"].joined(separator: ":")
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(output.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    /// The fixture completes synchronously and has no external work to cancel.
    override func stopLoading() { }
}
