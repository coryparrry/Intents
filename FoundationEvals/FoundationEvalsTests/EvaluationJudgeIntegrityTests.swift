import Foundation
import Testing
@testable import FoundationEvals

private actor JudgeIntegrityTransport {
    private var responses: [Data]
    private var requests: [Data] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request.httpBody ?? Data())
        guard !responses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (responses.removeFirst(), response)
    }
    func bodies() -> [Data] { requests }
}

// Keep these in the existing curated CI suite so selecting that suite also
// exercises its new cross-boundary regressions.
extension EvaluationCompatibleJudgeClientTests {
    @MainActor
    @Test(arguments: ["\n", "\r\n", "\r"])
    func providerFailureAfterCompleteVerdictCannotScoreOrRetry(newline: String) async throws {
        let text = Self.integrityVerdict
        let start = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": text]]]])
        let error = try Self.integrityEvent(["error": ["code": 503, "message": "provider unavailable"]])
        let stream = (start + error + "data: [DONE]\n\n").replacingOccurrences(of: "\n", with: newline)
        let fixture = JudgeIntegrityTransport([Data(stream.utf8)])
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        let (suite, connection) = Self.integritySuite(policy: .streaming)
        do {
            _ = try await Self.integrityJudge(client, suite: suite, connection: connection)
            Issue.record("A failed provider stream returned a scored verdict")
        } catch let failure as EvaluationCompatibleJudgeAttemptFailure {
            #expect(failure.attempts.count == 1)
            #expect(failure.attempts[0].rawResponse == text)
            #expect(EvaluationRunner.externalJudgeErrorCategory(failure) == "serviceUnavailable")
            let trace = try #require(EvaluationRunner.externalJudgeFailureTrace(
                failure, completedChecks: [], judgedCriterionIndexes: [1]))
            #expect(trace.rawResponse == text)
            #expect(trace.instructions == failure.attempts[0].requestConfiguration?.instructions)
            #expect(trace.validationError != nil)
        }
        #expect(await fixture.bodies().count == 1)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func streamedCompletionPreservesContentAndUsageAcrossLineEndings(newline: String) throws {
        let first = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": "first\n"]]]])
        let second = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": "second"], "finish_reason": "stop"]]])
        let usage = try Self.integrityEvent(["choices": [], "usage": ["prompt_tokens": 10, "completion_tokens": 5]])
        let stream = (first + second + usage + "data: [DONE]\n\n")
            .replacingOccurrences(of: "\n", with: newline)
        let completion = try EvaluationCompatibleJudgeResponseDecoder.decode(Data(stream.utf8))
        #expect(completion.choices.first?.message.content == "first\nsecond")
        #expect(completion.usage?.promptTokens == 10)
        #expect(completion.usage?.completionTokens == 5)
    }

    @MainActor
    @Test(arguments: ["error", "length", "content_filter"])
    func unsuccessfulFinishReasonCannotProduceAScore(reason: String) async throws {
        let start = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": Self.integrityVerdict]]]])
        let end = try Self.integrityEvent(["choices": [["delta": [:], "finish_reason": reason]]])
        let fixture = JudgeIntegrityTransport([Data((start + end).utf8)])
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        let (suite, connection) = Self.integritySuite(policy: .streaming)
        do {
            _ = try await Self.integrityJudge(client, suite: suite, connection: connection)
            Issue.record("Accepted finish_reason \(reason)")
        } catch let failure as EvaluationCompatibleJudgeAttemptFailure {
            #expect(failure.attempts.count == 1)
            #expect(failure.attempts[0].rawResponse == Self.integrityVerdict)
        }
        #expect(await fixture.bodies().count == 1)
    }

    @MainActor
    @Test func malformedVerdictsRetainBothRawAttemptsAndActualInstructionsAfterReload() async throws {
        let raw = ["{broken first verdict", "{broken repaired verdict"]
        let fixture = JudgeIntegrityTransport(try raw.map { try Self.integrityJSON(content: $0) })
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        let (suite, connection) = Self.integritySuite(policy: .portable)
        do {
            _ = try await Self.integrityJudge(client, suite: suite, connection: connection)
            Issue.record("Malformed verdicts were accepted")
        } catch let error as EvaluationCompatibleJudgeError {
            guard case .exhausted(_, let attempts) = error else { throw error }
            #expect(attempts.compactMap(\.rawResponse) == raw)
            #expect(attempts.allSatisfy { $0.validationError != nil })
            let trace = try #require(EvaluationRunner.externalJudgeFailureTrace(
                error, completedChecks: [], judgedCriterionIndexes: [1]))
            let data = try CanonicalJSON.data(for: trace)
            let restored = try CanonicalJSON.decode(EvaluationJudgeTrace.self, from: data)
            #expect(restored.attempts?.compactMap(\.rawResponse) == raw)
            #expect(restored.rawResponse == raw[1])
            let bodies = await fixture.bodies()
            #expect(bodies.count == 2)
            for (index, body) in bodies.enumerated() {
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try #require(object["messages"] as? [[String: Any]])
                #expect(attempts[index].requestConfiguration?.instructions == messages[0]["content"] as? String)
                #expect(attempts[index].prompt == messages[1]["content"] as? String)
                #expect(attempts[index].requestConfiguration?.promptVersion == EvaluationRunner.judgePromptVersion)
            }
            #expect(restored.instructions == attempts[1].requestConfiguration?.instructions)
            #expect(!String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func malformedOptionalUsageDoesNotRepairOrInvalidateVerdict(streaming: Bool) async throws {
        let shapes: [Any] = ["unknown", 17, true, [], ["prompt_tokens": "bad", "completion_tokens": 8],
                             ["prompt_tokens": -1, "completion_tokens": 8]]
        for shape in shapes {
            let data: Data
            if streaming {
                let first = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": Self.integrityVerdict]]]])
                let metadata = try Self.integrityEvent(["choices": [], "usage": shape])
                data = Data((first + metadata + "data: [DONE]\n\n").utf8)
            } else {
                data = try Self.integrityJSON(content: Self.integrityVerdict, usage: shape)
            }
            let fixture = JudgeIntegrityTransport([data])
            let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
            let (suite, connection) = Self.integritySuite(policy: streaming ? .streaming : .portable)
            let result = try await Self.integrityJudge(client, suite: suite, connection: connection)
            #expect(result.judgment.score == 4)
            #expect(result.usage == nil)
            #expect(result.cost.availability == .unavailable)
            #expect(result.trace.attempts?.count == 1)
            #expect(await fixture.bodies().count == 1)
        }
    }

    @MainActor
    @Test func successfulRequestAndSavedTraceUseTheSameEffectivePolicy() async throws {
        let first = try Self.integrityEvent(["choices": [["index": 0, "delta": ["content": Self.integrityVerdict]]]])
        // A normally closed compatible stream need not contain [DONE].
        let fixture = JudgeIntegrityTransport([Data(first.utf8)])
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        let (suite, connection) = Self.integritySuite(policy: .deepSeekThinking)
        let result = try await Self.integrityJudge(client, suite: suite, connection: connection)
        let data = try CanonicalJSON.data(for: result.trace)
        let trace = try CanonicalJSON.decode(EvaluationJudgeTrace.self, from: data)
        let policy = try #require(trace.attempts?.first?.requestConfiguration)
        let bodies = await fixture.bodies()
        let body = try #require(bodies.first)
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        #expect(result.judgment.score == 4)
        #expect(trace.instructions == messages[0]["content"] as? String)
        #expect(trace.instructions == policy.instructions)
        #expect(policy.maximumResponseTokens == request["max_tokens"] as? Int)
        #expect(policy.stream == request["stream"] as? Bool)
        #expect(policy.modelID == request["model"] as? String)
        #expect(policy.thinking)
        #expect(policy.timeoutSeconds == 300)
        #expect(policy.promptVersion == EvaluationRunner.judgePromptVersion)
    }

    @MainActor
    @Test func explicitGenerationPolicySurvivesRenamesAndRoundTrip() throws {
        var connection = Self.integritySuite(policy: .portable).1
        let originalDigest = connection.disclosureDigest
        connection.modelID = "deepseek/renamed-model"
        connection.baseURL = "https://deepseek.example/v1"
        #expect(!EvaluationCompatibleJudgeClient.usesThinkingGeneration(connection))
        #expect(EvaluationCompatibleJudgeClient.requestTimeoutSeconds(for: connection) == 60)
        connection.generationPolicy = .deepSeekThinking
        connection.modelID = "some-other-model"
        connection.baseURL = "https://other.example/v1"
        let restored = try CanonicalJSON.decode(EvaluationJudgeConnection.self, from: CanonicalJSON.data(for: connection))
        #expect(restored.generationPolicy == .deepSeekThinking)
        #expect(EvaluationCompatibleJudgeClient.usesThinkingGeneration(restored))
        #expect(restored.disclosureDigest != originalDigest)
    }

    @MainActor
    @Test func legacyConnectionResolvesPolicyOnceAndOldScoringContractIsNotCurrent() throws {
        let (suite, connection) = Self.integritySuite(policy: .portable)
        var object = try #require(JSONSerialization.jsonObject(with: CanonicalJSON.data(for: connection)) as? [String: Any])
        object.removeValue(forKey: "generationPolicy")
        object["modelID"] = "deepseek/legacy"
        var migrated = try CanonicalJSON.decode(EvaluationJudgeConnection.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(migrated.generationPolicy == .deepSeekThinking)
        migrated.modelID = "renamed"
        let restored = try CanonicalJSON.decode(EvaluationJudgeConnection.self, from: CanonicalJSON.data(for: migrated))
        #expect(restored.generationPolicy == .deepSeekThinking)
        let old = try EvaluationScoringContract(scoringMode: .modelJudge, rubricCriteria: suite.rubricCriteria,
            judgePromptVersion: "rubric-v7-required-assessments", judgePassingScore: EvaluationSuite.judgePassingScore,
            cases: suite.cases)
        #expect(old != (try EvaluationScoringContract(suite: suite)))
        let legacyTrace = try JSONDecoder().decode(EvaluationJudgeAttemptTrace.self, from: Data("{\"prompt\":\"old prompt\"}".utf8))
        #expect(legacyTrace.requestConfiguration == nil)
    }

    private static var integrityVerdict: String {
        "{\"requirements\":[{\"criterionIndex\":1,\"score\":4,\"rationale\":\"The response states the correct fact.\"}]}"
    }
    private static func integrityEvent(_ object: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }
    private static func integrityJSON(content: String, usage: Any? = nil) throws -> Data {
        var object: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]], "model": "fixture-model"]
        if let usage { object["usage"] = usage }
        return try JSONSerialization.data(withJSONObject: object)
    }
    @MainActor
    private static func integritySuite(policy: EvaluationJudgeGenerationPolicy) -> (EvaluationSuite, EvaluationJudgeConnection) {
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "fixture-model", generationPolicy: policy)
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = "The response is factually correct."
        suite.judgeConfiguration.mode = .connection
        suite.judgeConfiguration.connectionID = connection.id
        suite.judgeConfiguration.approvedConnectionID = connection.id
        suite.judgeConfiguration.externalEvidenceApprovedAt = Date()
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = suite.judgeConfiguration.includeReferenceAttachments
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        suite.judgeConfiguration.approvedEvidencePolicyVersion = EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        return (suite, connection)
    }
    @MainActor
    private static func integrityJudge(_ client: EvaluationCompatibleJudgeClient, suite: EvaluationSuite,
                                       connection: EvaluationJudgeConnection) async throws -> EvaluationCompatibleJudgeResult {
        let item = try #require(suite.cases.first)
        return try await client.judge(response: "Correct fact", evaluationCase: item, effectivePrompt: item.prompt,
            suite: suite, images: [], toolEvidence: nil, resolved: .init(connection: connection, apiKey: "fixture-secret"))
    }
}


extension EvaluationCompatibleJudgeClientTests {
    @MainActor
    @Test(arguments: [0, 1, 2])
    func successfulRepairAccountsForEveryReceivedAttempt(unknown: Int) async throws {
        var firstUsage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 5]
        if unknown == 0 { firstUsage["cost"] = 0.1 }
        let first = try Self.integrityJSON(content: "{broken verdict", usage: unknown == 2 ? nil : firstUsage)
        let second = try Self.integrityJSON(content: Self.integrityVerdict,
            usage: ["prompt_tokens": 20, "completion_tokens": 7, "cost": 0.2])
        let fixture = JudgeIntegrityTransport([first, second])
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        let (suite, connection) = Self.integritySuite(policy: .portable)
        let result = try await Self.integrityJudge(client, suite: suite, connection: connection)
        #expect(await fixture.bodies().count == 2)
        #expect(result.trace.attempts?.count == 2)
        #expect(result.trace.attempts?[0].validationError != nil)
        #expect(result.trace.attempts?[1].cost?.usd == 0.2)
        if unknown == 0 {
            #expect(result.cost.availability == .known)
            #expect(abs((result.cost.usd ?? 0) - 0.3) < 1e-12)
        } else {
            #expect(result.cost.availability == .unavailable)
            #expect(result.cost.usd == nil)
        }
        if unknown == 2 { #expect(result.usage == nil) }
        else {
            #expect(result.usage?.inputTokens == 30)
            #expect(result.usage?.outputTokens == 12)
        }
        let restored = try CanonicalJSON.decode(EvaluationJudgeTrace.self, from: CanonicalJSON.data(for: result.trace))
        #expect(restored.attempts?[1].usage?.inputTokens == 20)
        #expect(restored.attempts?[1].cost?.usd == 0.2)
    }

    @MainActor
    @Test func successfulRepairSumsConfiguredPriceEstimates() async throws {
        let fixture = JudgeIntegrityTransport([
            try Self.integrityJSON(content: "{broken", usage: ["prompt_tokens": 10, "completion_tokens": 5]),
            try Self.integrityJSON(content: Self.integrityVerdict, usage: ["prompt_tokens": 20, "completion_tokens": 7])
        ])
        let client = EvaluationCompatibleJudgeClient(transport: { try await fixture.send($0) })
        var (suite, connection) = Self.integritySuite(policy: .portable)
        connection.inputUSDPerMillionTokens = 1
        connection.outputUSDPerMillionTokens = 2
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let result = try await Self.integrityJudge(client, suite: suite, connection: connection)
        #expect(result.cost.availability == .estimated)
        #expect(abs((result.cost.usd ?? 0) - 0.000054) < 1e-12)
        #expect(result.usage?.inputTokens == 30)
        #expect(result.usage?.outputTokens == 12)
    }
}
