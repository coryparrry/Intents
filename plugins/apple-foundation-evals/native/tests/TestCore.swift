import Foundation

@main
struct CoreTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func payload(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "operation": "evaluate", "instructions": "", "cases": [
                ["id": "one", "prompt": "Reply READY", "expected": "READY", "scoring": "exact"]
            ], "repetitions": 1, "temperature": 0, "maxTokens": 16
        ]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func rejects(_ data: Data, _ message: String) {
        do { _ = try RunnerRequest.parse(data); check(false, message) }
        catch let failure as RunnerFailure { check(failure.kind == "invalidInput", message) }
        catch { check(false, "Unstructured validation error") }
    }

    static func main() throws {
        _ = try RunnerRequest.parse(payload())
        _ = try RunnerRequest.parse(payload(["temperature": 2, "repetitions": 10, "maxTokens": 4096]))
        _ = try RunnerRequest.parse(Data("{\"operation\":\"availability\"}".utf8))
        for malformed in ["", "[]", "null", "{}", "{", "{\"operation\":\"availability\"} {}"] {
            rejects(Data(malformed.utf8), "Reject malformed JSON: \(malformed)")
        }
        rejects(Data(repeating: 32, count: RunnerLimits.inputBytes + 1), "Input byte limit")
        rejects(Data("{\"operation\":\"availability\",\"cases\":[]}".utf8), "Availability extra fields")
        for changes: [String: Any] in [
            ["operation": "unknown"], ["repetitions": 0], ["repetitions": 11], ["repetitions": 1.5],
            ["repetitions": true], ["temperature": -0.1], ["temperature": 2.1], ["maxTokens": 0],
            ["maxTokens": 4097], ["maxTokens": 1.2], ["cases": []], ["instructions": true],
            ["instructions": String(repeating: "é", count: 8193)], ["tools": []],
            ["cases": [["id": "one", "prompt": "x", "scoring": "exact"]]],
            ["cases": [["id": "one", "prompt": "x", "expected": "", "scoring": "contains"]]],
            ["cases": [["id": "one", "prompt": "x", "scoring": "bad"]]],
            ["cases": [["id": " ", "prompt": "x", "scoring": "none"]]],
            ["cases": [["id": "one", "prompt": " \n", "scoring": "none"]]],
            ["cases": [["id": "one", "prompt": String(repeating: "é", count: 16385), "scoring": "none"]]],
            ["cases": [["id": "one", "prompt": "x", "scoring": "none", "tool": "x"]]],
            ["cases": [["id": "one", "prompt": "x", "scoring": "none"], ["id": "one", "prompt": "y", "scoring": "none"]]],
            ["cases": (1...101).map { ["id": "\($0)", "prompt": "x", "scoring": "none"] }],
            ["cases": (1...11).map { ["id": "\($0)", "prompt": "x", "scoring": "none"] }, "repetitions": 10],
            ["cases": (1...20).map { ["id": "\($0)", "prompt": "x", "scoring": "none"] }, "maxTokens": 4096],
            ["cases": (1...20).map { ["id": "\($0)", "prompt": String(repeating: "x", count: 30_000), "scoring": "none"] }]
        ] { rejects(try payload(changes), "Invalid request must be rejected") }
        check(Scoring.exact.assess(response: "READY", expected: "READY").passed == true, "Exact success")
        for response in ["ready", "READY\n", " READY", "READY!"] {
            check(Scoring.exact.assess(response: response, expected: "READY").passed == false, "Exact preserves content")
        }
        check(Scoring.contains.assess(response: "Result: READY.", expected: "READY").score == 1, "Contains success")
        check(Scoring.contains.assess(response: "ready", expected: "READY").score == 0, "Contains case sensitivity")
        check(Scoring.none.assess(response: "anything", expected: "anything").passed == nil, "None is unscored")
        check(Scoring.none.assess(response: "anything", expected: nil).score == nil, "None score is null")
        let unscored = EvaluationResult(caseId: "none", repetition: 1, prompt: "x", expected: nil, response: "y",
                                        passed: nil, score: nil, durationMs: 1, trace: EvaluationTrace(transcript: [], error: nil))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unscored)) as! [String: Any]
        check(encoded["passed"] is NSNull && encoded["score"] is NSNull, "Unscored fields explicitly null")
        let unavailable = EvaluationOutput.failed(RunnerFailure(kind: "modelUnavailable", message: "Apple Intelligence is disabled."),
                                                  started: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        check(unavailable.status == "failed" && unavailable.results.isEmpty, "Unavailable model does not invent results")
        check(unavailable.error?.kind == "modelUnavailable", "Unavailable model structured error")
        check(unavailable.durationMs >= 0, "Duration uses monotonic clock")
        for literal in ["9007199254740993", "18446744073709551615", "-9223372036854775808"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
            let roundTrip = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            check(roundTrip == literal, "Transcript integers preserve precision")
        }
        let genericError = NSError(domain: "TestModelService", code: 17, userInfo: [NSLocalizedDescriptionKey: "Real service failure."])
        let genericFailure = RunnerFailure.unclassifiedGenerationError(genericError)
        check(genericFailure.kind == "generationError", "Unknown SDK errors keep generic classification")
        check(genericFailure.message == "Real service failure.", "Unknown SDK errors preserve real localized description")
        check(RunnerFailure.unclassifiedGenerationError(CancellationError()).kind == "cancelled", "Cancellation classification")
        print("Native core tests: \(assertions) assertions passed")
    }
}
