import Foundation
import Network
import Testing
@testable import FoundationEvals

struct EvaluationCompatibleJudgeClientTests {
    @Test(.timeLimit(.minutes(1)))
    func fixtureChecksCapabilitiesAndReturnsValidatedProvenance() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Fixture judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture",
            inputUSDPerMillionTokens: 1, outputUSDPerMillionTokens: 2
        )
        let resolved = EvaluationResolvedJudgeConnection(connection: connection, apiKey: nil)
        let client = EvaluationCompatibleJudgeClient()
        let check = try await client.checkConnection(resolved)
        #expect(check.modelFound)
        #expect(check.structuredOutputsVerified == true)
        #expect(check.multimodalVerified == false)

        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported."
        suite.judgeConfiguration = .init(
            mode: .connection,
            connectionID: connection.id,
            externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false,
            approvedConnectionID: connection.id,
            approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )
        let result = try await client.judge(
            response: "Blue light is scattered.",
            evaluationCase: suite.cases[0],
            effectivePrompt: suite.cases[0].prompt,
            suite: suite,
            images: [],
            toolEvidence: "tool=lookup; outcome=success",
            resolved: resolved
        )
        #expect(result.judgment.score == 4)
        #expect(result.identity.reportedModelID == "judge-fixture-reported")
        #expect(result.identity.provider == "fixture-provider")
        #expect(result.usage?.inputTokens == 10)
        #expect(result.cost.availability == .estimated)
        #expect(result.cost.usd == 0.00002)
    }

    @Test(.timeLimit(.minutes(1)))
    func genericCompatibleRequestUsesPortableJSONModeAndExplicitInstructions() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Generic judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        let suite = approvedSuite(for: connection)

        _ = try await EvaluationCompatibleJudgeClient().judge(
            response: "Response",
            evaluationCase: suite.cases[0],
            effectivePrompt: "Prompt",
            suite: suite,
            images: [],
            toolEvidence: nil,
            resolved: .init(connection: connection, apiKey: nil)
        )

        let request = try #require(fixture.lastCompletionRequest)
        let separator = try #require(request.range(of: "\r\n\r\n"))
        let body = Data(request[separator.upperBound...].utf8)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_object")
        #expect(responseFormat["json_schema"] == nil)
        #expect(json["max_tokens"] as? Int == EvaluationCompatibleJudgeClient.portableJudgeMaxTokens)
        #expect(json["thinking"] == nil)
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.localizedCaseInsensitiveContains("JSON"))
        #expect(system.contains("\"requirements\""))
        #expect(!system.contains("requirementN"))
        #expect(!system.contains("Fill every requirement"))
    }

    @Test(.timeLimit(.minutes(1)))
    func deepseekCompatibleRequestKeepsThinkingAndRaisesGenerationBudget() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .sse)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "DeepSeek judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "deepseek-flash",
            requestTimeoutSeconds: 60
        )
        #expect(EvaluationCompatibleJudgeClient.usesThinkingGeneration(connection))
        #expect(
            EvaluationCompatibleJudgeClient.requestTimeoutSeconds(for: connection)
                == EvaluationCompatibleJudgeClient.thinkingJudgeMinimumTimeoutSeconds
        )
        let suite = approvedSuite(for: connection)

        let result = try await EvaluationCompatibleJudgeClient().judge(
            response: "Response",
            evaluationCase: suite.cases[0],
            effectivePrompt: "Prompt",
            suite: suite,
            images: [],
            toolEvidence: nil,
            resolved: .init(connection: connection, apiKey: nil)
        )
        #expect(result.judgment.score == 4)
        #expect(result.identity.reportedModelID == "judge-fixture-reported")
        #expect(result.identity.provider == "fixture-provider")
        #expect(result.usage?.inputTokens == 10)
        #expect(result.usage?.outputTokens == 5)
        #expect(fixture.completionRequestCount == 1)

        let request = try #require(fixture.lastCompletionRequest)
        let separator = try #require(request.range(of: "\r\n\r\n"))
        let body = Data(request[separator.upperBound...].utf8)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == EvaluationCompatibleJudgeClient.thinkingJudgeMaxTokens)
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_object")
        let streamOptions = try #require(json["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func fencedJSONAndContentPartsStillDecodeAsAVerdict() async throws {
        for mode: CompatibleJudgeFixture.Mode in [.fenced, .contentParts] {
            let fixture = try CompatibleJudgeFixture(mode: mode)
            defer { fixture.stop() }
            let connection = EvaluationJudgeConnection(
                id: UUID(), name: "Wrapped judge", kind: .localCompatible,
                baseURL: fixture.baseURL, modelID: "judge-fixture"
            )
            let suite = approvedSuite(for: connection)
            let result = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: suite.cases[0],
                effectivePrompt: "Prompt",
                suite: suite,
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            #expect(result.judgment.score == 4)
            fixture.stop()
        }
    }

    @Test func jsonPayloadStripsMarkdownFences() {
        let fenced = """
            ```json
            {"requirements":[{"criterionIndex":1,"score":4,"rationale":"Met."}]}
            ```
            """
        #expect(
            EvaluationCompatibleJudgeClient.jsonPayload(from: fenced)
                == #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"Met."}]}"#
        )
        #expect(EvaluationCompatibleJudgeClient.jsonPayload(from: "  {\"score\":1}  ") == "{\"score\":1}")
    }

    @Test func thinkingGenerationIsUsedForDeepSeekHostsAndModelIDsOnly() {
        #expect(
            EvaluationCompatibleJudgeClient.usesThinkingGeneration(
                EvaluationJudgeConnection(
                    id: UUID(), name: "DeepSeek", kind: .customCompatible,
                    baseURL: "https://api.deepseek.com", modelID: "flash"
                )
            )
        )
        #expect(
            !EvaluationCompatibleJudgeClient.usesThinkingGeneration(
                EvaluationJudgeConnection(
                    id: UUID(), name: "Local", kind: .localCompatible,
                    baseURL: "http://127.0.0.1:11434/v1", modelID: "llama3"
                )
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func missingConfiguredModelReportsAvailableEndpointIDs() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Generic judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "missing-model"
        )

        let check = try await EvaluationCompatibleJudgeClient().checkConnection(
            .init(connection: connection, apiKey: nil)
        )

        #expect(!check.modelFound)
        #expect(check.message.contains("missing-model"))
        #expect(check.message.contains("judge-fixture"))
    }

    @Test(.timeLimit(.minutes(1)))
    func HTTPFailureIncludesBoundedProviderMessage() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .status(400))
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Rejected judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        let suite = approvedSuite(for: connection)

        do {
            _ = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: suite.cases[0],
                effectivePrompt: "Prompt",
                suite: suite,
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            Issue.record("Expected the endpoint rejection to propagate.")
        } catch {
            #expect(error.localizedDescription.contains("Model Not Exist"))
            #expect(error.localizedDescription.count < 1_024)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedVerdictRetriesOnceThenFailsClosed() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .malformed)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Broken judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported."
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )
        do {
            _ = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response", evaluationCase: suite.cases[0],
                effectivePrompt: suite.cases[0].prompt, suite: suite,
                images: [], toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            Issue.record("Expected malformed judgment to fail closed.")
        } catch let error as EvaluationCompatibleJudgeError {
            guard case let .exhausted(message, attempts) = error else {
                Issue.record("Expected exhausted error, received \(error).")
                return
            }
            #expect(!message.isEmpty)
            #expect(attempts.count == 2)
            #expect(attempts.allSatisfy { !$0.prompt.isEmpty })
            #expect(attempts.allSatisfy { $0.rawResponse != nil })
            #expect(attempts.allSatisfy { $0.validationError != nil })
            #expect(error.localizedDescription.contains("after one bounded retry"))
        }
        #expect(fixture.completionRequestCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedResponseIsCancelledWhileStreamingAtTheConfiguredCap() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .oversized)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Oversized judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )

        do {
            _ = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: approvedSuite(for: connection).cases[0],
                effectivePrompt: "Prompt",
                suite: approvedSuite(for: connection),
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            Issue.record("Expected the oversized response to fail closed.")
        } catch let error as EvaluationCompatibleJudgeError {
            guard case .responseTooLarge = error else {
                Issue.record("Expected responseTooLarge, received \(error).")
                return
            }
        }

        #expect(fixture.waitForOversizedConnectionClose())
        #expect(fixture.oversizedBodyChunksSent < fixture.oversizedBodyChunkCount)
    }

    @Test(.timeLimit(.minutes(1)))
    func incompleteUsageMetadataIsUnavailableAndCompleteUsageEstimatesCost() async throws {
        let shapes: [CompatibleJudgeFixture.UsageShape] = [
            .empty, .promptOnly, .completionOnly, .costOnly, .negative, .overflow,
            .array, .string, .null, .missing
        ]
        for shape in shapes {
            let fixture = try CompatibleJudgeFixture(mode: .usage(shape))
            let connection = EvaluationJudgeConnection(
                id: UUID(), name: "Usage fixture", kind: .localCompatible,
                baseURL: fixture.baseURL, modelID: "judge-fixture",
                inputUSDPerMillionTokens: 1, outputUSDPerMillionTokens: 2
            )
            let suite = approvedSuite(for: connection)
            defer { fixture.stop() }
            let result = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response", evaluationCase: suite.cases[0],
                effectivePrompt: "Prompt", suite: suite, images: [],
                toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil)
            )
            #expect(result.judgment.score == 4)
            #expect(result.usage == nil)
            #expect(result.cost.availability == .unavailable)
            #expect(result.cost.usd == nil)
            #expect(fixture.completionRequestCount == 1)
            fixture.stop()
        }

        let fixture = try CompatibleJudgeFixture(mode: .usage(.complete))
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Complete usage fixture", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture",
            inputUSDPerMillionTokens: 1, outputUSDPerMillionTokens: 2
        )
        let suite = approvedSuite(for: connection)
        let result = try await EvaluationCompatibleJudgeClient().judge(
            response: "Response", evaluationCase: suite.cases[0],
            effectivePrompt: "Prompt", suite: suite, images: [],
            toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil)
        )
        #expect(result.usage?.inputTokens == 10)
        #expect(result.usage?.outputTokens == 5)
        #expect(result.cost.availability == .estimated)
        #expect(result.cost.usd == 0.00002)
    }

    @Test(.timeLimit(.minutes(1)))
    func HTTPFailuresAreNotRetriedAndPreserveTheirStatus() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .status(401))
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unauthorized judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )

        do {
            _ = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: approvedSuite(for: connection).cases[0],
                effectivePrompt: "Prompt",
                suite: approvedSuite(for: connection),
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            Issue.record("Expected the HTTP failure to propagate.")
        } catch let error as EvaluationCompatibleJudgeError {
            guard case .http(status: 401, detail: _) = error else {
                Issue.record("Expected HTTP 401, received \(error).")
                return
            }
        }
        #expect(fixture.completionRequestCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func judgeTransportDoesNotFollowRedirects() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .redirect)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Redirecting judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )

        do {
            _ = try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: approvedSuite(for: connection).cases[0],
                effectivePrompt: "Prompt",
                suite: approvedSuite(for: connection),
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
            Issue.record("Expected the redirect response to be rejected.")
        } catch let error as EvaluationCompatibleJudgeError {
            guard case .http(status: 302, detail: _) = error else {
                Issue.record("Expected HTTP 302, received \(error).")
                return
            }
        }
        #expect(fixture.completionRequestCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsBeforeStartingARepairRequest() async throws {
        let fixture = try CompatibleJudgeFixture(mode: .stalled)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Stalled judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        let suite = approvedSuite(for: connection)
        let task = Task {
            try await EvaluationCompatibleJudgeClient().judge(
                response: "Response",
                evaluationCase: suite.cases[0],
                effectivePrompt: "Prompt",
                suite: suite,
                images: [],
                toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
        }
        try await waitForCompletionRequests(1, fixture: fixture)

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(fixture.completionRequestCount == 1)
    }

    @Test func connectionValidationRestrictsPlainHTTPToLiteralLoopback() {
        #expect(
            EvaluationJudgeConnection(
                id: UUID(), name: "Local", kind: .localCompatible,
                baseURL: "http://127.0.0.1:11434/v1", modelID: "judge"
            ).validationIssue == nil
        )
        #expect(
            EvaluationJudgeConnection(
                id: UUID(), name: "Not local", kind: .localCompatible,
                baseURL: "http://example.com/v1", modelID: "judge"
            ).validationIssue?.contains("loopback") == true
        )
        #expect(
            EvaluationJudgeConnection(
                id: UUID(), name: "Custom", kind: .customCompatible,
                baseURL: "http://127.0.0.1:11434/v1", modelID: "judge"
            ).validationIssue?.contains("HTTPS") == true
        )
        #expect(
            EvaluationJudgeConnection(
                id: UUID(), name: "Custom", kind: .customCompatible,
                baseURL: "https://judge.example/v1?token=secret", modelID: "judge"
            ).validationIssue?.contains("query") == true
        )

        let session = EvaluationCompatibleJudgeClient.sessionConfiguration(timeout: 12)
        #expect(session.timeoutIntervalForRequest == 12)
        #expect(session.timeoutIntervalForResource == 12)
        #expect(session.httpCookieStorage == nil)
        #expect(!session.httpShouldSetCookies)
        #expect(session.urlCredentialStorage == nil)
        #expect(session.connectionProxyDictionary?.isEmpty == true)

        #expect(EvaluationRunner.externalJudgeErrorCategory(EvaluationCompatibleJudgeError.http(status: 429, detail: nil)) == "rateLimited")
        #expect(EvaluationRunner.externalJudgeErrorCategory(EvaluationCompatibleJudgeError.http(status: 503, detail: nil)) == "serviceUnavailable")
        #expect(EvaluationRunner.externalJudgeErrorCategory(EvaluationCompatibleJudgeError.http(status: 408, detail: nil)) == "timeout")
        #expect(EvaluationRunner.stopsBatch(for: "rateLimited"))
        #expect(EvaluationRunner.stopsBatch(for: "serviceUnavailable"))
        #expect(EvaluationRunner.stopsBatch(for: "timeout"))
    }

    @Test func disclosureAndMultimodalCapabilitiesAreMandatory() async throws {
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Local", kind: .localCompatible,
            baseURL: "http://127.0.0.1:19999/v1", modelID: "judge"
        )
        var suite = EvaluationSuite()
        suite.criteria = "Requirement"
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: nil, includeReferenceAttachments: true
        )
        await #expect(throws: EvaluationCompatibleJudgeError.self) {
            try await EvaluationCompatibleJudgeClient().judge(
                response: "R", evaluationCase: suite.cases[0], effectivePrompt: "P",
                suite: suite, images: [], toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
        }
        suite.judgeConfiguration.externalEvidenceApprovedAt = Date()
        suite.judgeConfiguration.approvedConnectionID = connection.id
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = true
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let image = ImageEvaluationInput(label: "image", url: URL(filePath: "/tmp/not-read.png"))
        await #expect(throws: EvaluationCompatibleJudgeError.self) {
            try await EvaluationCompatibleJudgeClient().judge(
                response: "R", evaluationCase: suite.cases[0], effectivePrompt: "P",
                suite: suite, images: [image], toolEvidence: nil,
                resolved: .init(connection: connection, apiKey: nil)
            )
        }
    }

    @Test func disclosureApprovalIsBoundToConnectionAndAttachmentSharing() {
        let connectionID = UUID()
        var configuration = EvaluationJudgeConfiguration(
            mode: .connection, connectionID: connectionID,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connectionID, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: nil
        )
        var connection = EvaluationJudgeConnection(
            id: connectionID, name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "judge"
        )
        configuration.approvedConnectionDigest = connection.disclosureDigest
        #expect(configuration.hasCurrentExternalEvidenceApproval(for: connection))

        configuration.connectionID = UUID()
        #expect(!configuration.hasCurrentExternalEvidenceApproval(for: connection))

        configuration.connectionID = connectionID
        configuration.includeReferenceAttachments = true
        #expect(!configuration.hasCurrentExternalEvidenceApproval(for: connection))

        configuration.includeReferenceAttachments = false
        connection.modelID = "different-judge"
        #expect(!configuration.hasCurrentExternalEvidenceApproval(for: connection))
    }

    private func approvedSuite(for connection: EvaluationJudgeConnection) -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported."
        suite.judgeConfiguration = .init(
            mode: .connection,
            connectionID: connection.id,
            externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false,
            approvedConnectionID: connection.id,
            approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )
        return suite
    }

    private func waitForCompletionRequests(_ count: Int, fixture: CompatibleJudgeFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.completionRequestCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.completionRequestCount >= count, "Judge fixture did not receive a request.")
    }
}

final class CompatibleJudgeFixture: @unchecked Sendable {
    enum Mode {
        case valid
        case malformed
        case fenced
        case contentParts
        case sse
        case status(Int)
        case redirect
        case stalled
        case oversized
        case usage(UsageShape)
    }

    enum UsageShape {
        case empty
        case promptOnly
        case completionOnly
        case costOnly
        case complete
        case negative
        case overflow
        case array
        case string
        case null
        case missing
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FoundationEvalsTests.CompatibleJudgeFixture")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let mode: Mode
    private var requestCount = 0
    private var completionRequests: [String] = []
    private var stalledConnections: [NWConnection] = []
    private let oversizedConnectionClosed = DispatchSemaphore(value: 0)
    private(set) var oversizedBodyChunksSent = 0
    private(set) var oversizedBodyChunkCount = 0
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var completionRequestCount: Int { lock.withLock { requestCount } }
    var lastCompletionRequest: String? { lock.withLock { completionRequests.last } }

    func waitForOversizedConnectionClose() -> Bool {
        oversizedConnectionClosed.wait(timeout: .now() + 5) == .success
    }

    init(mode: Mode) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener.port?.rawValue ?? 0
                self.ready.signal()
            case .failed:
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw FixtureError.listen
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            stalledConnections.forEach { $0.cancel() }
            stalledConnections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let closed: Bool
            switch state {
            case .cancelled, .failed(_): closed = true
            default: closed = false
            }
            if case .oversized = self.mode, closed {
                self.oversizedConnectionClosed.signal()
            }
        }
        connection.start(queue: queue)
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil else { connection.cancel(); return }
            guard self.isCompleteHTTPRequest(request) else {
                if complete { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            self.respond(to: request, connection: connection)
        }
    }

    private func respond(to request: Data, connection: NWConnection) {
        let first = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        var body = Data()
        if first.contains("/models") {
            body = Data(#"{"data":[{"id":"judge-fixture","supported_parameters":["response_format"],"architecture":{"input_modalities":["text"]}}]}"#.utf8)
        } else {
            lock.withLock {
                requestCount += 1
                completionRequests.append(String(decoding: request, as: UTF8.self))
            }
            switch mode {
            case .status(let status):
                let error = #"{"error":{"message":"Model Not Exist"}}"#
                send(status: status, body: Data(error.utf8), to: connection)
                return
            case .redirect where !first.contains("/redirected"):
                let head = "HTTP/1.1 302 Found\r\nLocation: /v1/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(head.utf8),
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            case .stalled:
                lock.withLock { stalledConnections.append(connection) }
                return
            case .oversized:
                sendOversizedResponse(to: connection)
                return
            case .sse:
                sendSSEVerdict(to: connection)
                return
            case .usage:
                break
            case .valid, .redirect, .malformed, .fenced, .contentParts:
                let verdict = #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"Supported by the saved evidence."}]}"#
                let messageContent: Any = switch mode {
                case .malformed:
                    #"{"requirements":[]}"#
                case .fenced:
                    "```json\n\(verdict)\n```"
                case .contentParts:
                    [["type": "text", "text": verdict]]
                default:
                    verdict
                }
                body = try! JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": messageContent]]],
                    "model": "judge-fixture-reported",
                    "provider": "fixture-provider",
                    "usage": ["prompt_tokens": 10, "completion_tokens": 5]
                ], options: [.sortedKeys])
            }
        }
        if case .usage(let shape) = mode {
            let content = #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"Supported by the saved evidence."}]}"#
            let escapedContent = String(
                data: try! JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed]),
                encoding: .utf8
            )!
            let usage: String? = switch shape {
            case .empty: "{}"
            case .promptOnly: #"{"prompt_tokens":10}"#
            case .completionOnly: #"{"completion_tokens":5}"#
            case .costOnly: #"{"cost":0.25}"#
            case .complete: #"{"prompt_tokens":10,"completion_tokens":5}"#
            case .negative: #"{"prompt_tokens":-1,"completion_tokens":5}"#
            case .overflow: #"{"prompt_tokens":9223372036854775808,"completion_tokens":5}"#
            case .array: "[]"
            case .string: #""bad""#
            case .null, .missing: nil
            }
            let usageField: String
            switch shape {
            case .null:
                usageField = ",\"usage\":null"
            case .missing:
                usageField = ""
            default:
                usageField = ",\"usage\":\(usage!)"
            }
            body = Data(#"{"choices":[{"message":{"content":\#(escapedContent)}}],"model":"judge-fixture-reported","provider":"fixture-provider"\#(usageField)}"#.utf8)
        }
        send(status: 200, body: body, to: connection)
    }

    private func sendOversizedResponse(to connection: NWConnection) {
        let chunkSize = 16 * 1_024
        let bodySize = EvaluationCompatibleJudgeClient.maximumResponseBytes + chunkSize * 256
        let bodyChunk = Data(repeating: 0x61, count: chunkSize)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodySize)\r\nConnection: close\r\n\r\n"
        oversizedBodyChunkCount = bodySize / chunkSize
        connection.send(
            content: Data(head.utf8),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.oversizedConnectionClosed.signal()
                    return
                }
                self.sendOversizedChunk(bodyChunk, remaining: self.oversizedBodyChunkCount, to: connection)
            }
        )
    }

    private func sendOversizedChunk(_ chunk: Data, remaining: Int, to connection: NWConnection) {
        guard remaining > 0 else {
            connection.send(
                content: nil,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
            return
        }
        connection.send(
            content: chunk,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.oversizedConnectionClosed.signal()
                    return
                }
                self.lock.withLock { self.oversizedBodyChunksSent += 1 }
                self.sendOversizedChunk(chunk, remaining: remaining - 1, to: connection)
            }
        )
    }

    private func sendSSEVerdict(to connection: NWConnection) {
        let verdict = #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"Supported by the saved evidence."}]}"#
        let prefix = String(verdict.prefix(20))
        let suffix = String(verdict.dropFirst(20))
        // Each SSE event ends with a blank line. A single newline instead joins
        // these data fields into one invalid JSON payload (including [DONE]).
        let events = [
            #"data: {"choices":[{"delta":{"content":\#(Self.jsonString(prefix))}}],"model":"judge-fixture-reported"}"#,
            #"data: {"choices":[{"delta":{"content":\#(Self.jsonString(suffix))}}],"provider":"fixture-provider","usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
            "data: [DONE]",
        ].joined(separator: "\n\n") + "\n\n"
        let body = Data(events.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func jsonString(_ value: String) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
            encoding: .utf8
        )!
    }

    private func send(status: Int, body: Data, to connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func isCompleteHTTPRequest(_ request: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = request.range(of: separator) else { return false }
        let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let contentLength = header.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
            ?? 0
        return request.count >= headerRange.upperBound + contentLength
    }

    private enum FixtureError: Error { case listen }
}
