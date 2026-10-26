import Foundation
import FoundationModels
import Darwin
import Dispatch

struct CapabilityAvailability: Encodable {
    var available: Bool
    var reason: String?
}

struct AvailabilityOutput: Encodable {
    let available: Bool
    let reason: String?
    let model = nativeModelName
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var capabilities: [String: CapabilityAvailability]? = nil
}

@available(macOS 26.0, *)
enum OnDeviceRunner {
    /// Reports default on-device model readiness with a user-facing reason and OS-appropriate standalone capability details.
    static func availability() -> AvailabilityOutput {
        switch SystemLanguageModel.default.availability {
        case .available: return availabilityOutput(available: true, reason: nil)
        case .unavailable(let reason):
            let message: String
            switch reason {
            case .deviceNotEligible: message = "This Mac is not eligible for Apple Intelligence."
            case .appleIntelligenceNotEnabled: message = "Apple Intelligence is not enabled in System Settings."
            case .modelNotReady: message = "The on-device model is not ready. Check Apple Intelligence model downloads."
            @unknown default: message = "The on-device model is unavailable: \(reason)."
            }
            return availabilityOutput(available: false, reason: message)
        }
    }

    /// Builds availability output with full standalone capabilities on macOS 27 or an app-engine OS requirement on earlier supported systems.
    static func availabilityOutput(available: Bool, reason: String?) -> AvailabilityOutput {
        var output = AvailabilityOutput(available: available, reason: reason)
        if #available(macOS 27.0, *) {
            output.capabilities = AppEngineBridge.capabilities(available: available, reason: reason)
        } else {
            output.capabilities = ["appEngine": CapabilityAvailability(available: false,
                reason: "Full app-engine evaluations require macOS 27 or later.")]
        }
        return output
    }

    /// Preserves each SDK transcript entry through its Codable container, retaining unfamiliar wrappers or a text fallback with serialization error details.
    static func transcriptEntries(_ transcript: Transcript) -> [JSONValue] {
        transcript.map { entry in
            do {
                // Entry is not Codable; Transcript is Apple's public Codable container.
                let data = try JSONEncoder().encode(Transcript(entries: [entry]))
                let encoded = try JSONDecoder().decode(JSONValue.self, from: data)
                if case .array(let entries) = encoded, entries.count == 1 { return entries[0] }
                if case .object(let object) = encoded,
                   case .array(let entries) = object["entries"], entries.count == 1 { return entries[0] }
                if case .object(let object) = encoded,
                   case .object(let container) = object["transcript"],
                   case .array(let entries) = container["entries"], entries.count == 1 { return entries[0] }
                // Preserve an unfamiliar SDK container unchanged rather than discard fields.
                return .object(["encoding": .string("foundationModelsCodable"), "value": encoded])
            } catch {
                return .object([
                    "encoding": .string("textFallback"),
                    "text": .string(entry.description),
                    "serializationError": .string(error.localizedDescription)
                ])
            }
        }
    }

    /// Maps macOS 26 generation errors to stable runner categories, falling back to cancellation or a generic generation error for other failures.
    static func generationFailure(_ error: Error) -> RunnerFailure {
        // Keep type references within the macOS 26 SDK surface. Newer SDK error
        // types still produce failed results through the real localized fallback.
        if let failure = error as? LanguageModelSession.GenerationError {
            let kind: String
            switch failure {
            case .refusal: kind = "refusal"
            case .guardrailViolation: kind = "guardrailViolation"
            case .exceededContextWindowSize: kind = "contextSizeExceeded"
            case .assetsUnavailable: kind = "modelUnavailable"
            case .rateLimited: kind = "rateLimited"
            case .unsupportedGuide: kind = "unsupportedGenerationGuide"
            case .unsupportedLanguageOrLocale: kind = "unsupportedLanguageOrLocale"
            case .decodingFailure: kind = "decodingFailure"
            case .concurrentRequests: kind = "concurrentRequests"
            @unknown default: kind = "generationError"
            }
            return RunnerFailure(kind: kind, message: failure.localizedDescription)
        }
        return RunnerFailure.unclassifiedGenerationError(error)
    }

    /// Executes legacy cases serially in fresh on-device sessions and records strict deterministic scores, timing, transcripts, and per-generation failures.
    /// An unavailable model fails before execution; otherwise all requested generations run and the first failure determines the overall failed status.
    static func evaluate(_ request: EvaluationRequest) async -> EvaluationOutput {
        let started = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let available = availability()
        guard available.available else {
            return .failed(RunnerFailure(kind: "modelUnavailable", message: available.reason ?? "The model is unavailable."),
                           started: started, uptime: uptime)
        }
        let options = GenerationOptions(
            samplingMode: request.temperature == 0 ? .greedy : .random(probabilityThreshold: 0.95),
            temperature: request.temperature == 0 ? nil : request.temperature,
            maximumResponseTokens: request.maxTokens
        )
        var results: [EvaluationResult] = []
        var firstFailure: RunnerFailure?
        // Serial work and fresh sessions keep cases independent and limit thermal load.
        for item in request.cases {
            for repetition in 1...request.repetitions {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: request.instructions)
                let caseUptime = ProcessInfo.processInfo.systemUptime
                let response: String
                let failure: RunnerFailure?
                do {
                    response = try await session.respond(to: item.prompt, options: options).content
                    failure = nil
                } catch {
                    response = ""
                    failure = generationFailure(error)
                    if firstFailure == nil { firstFailure = failure }
                }
                let duration = elapsedMilliseconds(since: caseUptime)
                let assessment = failure == nil ? item.scoring.assess(response: response, expected: item.expected) : (passed: false, score: 0.0)
                results.append(EvaluationResult(
                    caseId: item.id, repetition: repetition, prompt: item.prompt, expected: item.expected,
                    response: response, passed: assessment.passed, score: assessment.score, durationMs: duration,
                    trace: EvaluationTrace(transcript: transcriptEntries(session.transcript), error: failure)
                ))
            }
        }
        return EvaluationOutput(status: firstFailure == nil ? "completed" : "failed", startedAt: timestamp(started),
                                finishedAt: timestamp(Date()), durationMs: elapsedMilliseconds(since: uptime),
                                results: results, error: firstFailure)
    }
}

@main
struct FoundationModelsRunner {
    /// Reads one bounded stdin JSON request, dispatches legacy or macOS 27 app-engine operations, and emits newline-delimited JSON results.
    /// Request and execution failures become structured failed output, with a fixed serialization fallback if encoding also fails.
    static func main() async {
        let started = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        do {
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                input.append(chunk)
                guard input.count <= 32 * RunnerLimits.inputBytes else { throw RunnerFailure.validation("Input exceeds 33554432 bytes.") }
            }
            let object = try JSONSerialization.jsonObject(with: input) as? [String: Any]
            if object?["suite"] != nil, object?["operation"] as? String == "evaluate" {
                if #available(macOS 27.0, *) {
                    let output = try await evaluateWithCancellationSignals(input)
                    try emit(output)
                } else {
                    try emit(EvaluationOutput.failed(RunnerFailure(kind: "unsupportedOS", message: "App-engine evaluations require macOS 27 or later."), started: started, uptime: uptime))
                }
                return
            }
            if let operation = object?["operation"] as? String,
               ["suite-defaults", "validate-suite", "analyze-run", "export-suite", "extract-reference", "create-experiment", "run-experiment", "compare-runs", "summarize-experiment", "release-check", "project-release-check", "approve-baseline", "correct-judgment", "select-assessment"].contains(operation) {
                if #available(macOS 27.0, *) {
                    switch operation {
                    case "suite-defaults": try emit(EvaluationSuite())
                    case "create-experiment":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.ExperimentRequest.self, from: input)
                        try emit(AppEngineWorkflows.createExperiment(request))
                    case "run-experiment":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.ExperimentRequest.self, from: input)
                        let output = try await withCancellationSignals { try await AppEngineWorkflows.runExperiment(request) }
                        try emit(output)
                    case "compare-runs":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.ComparisonRequest.self, from: input)
                        try emit(EvaluationRunComparison(current: request.current, baseline: request.baseline))
                    case "summarize-experiment":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.SummaryRequest.self, from: input)
                        try emit(AppEngineWorkflows.summarizeExperiment(request))
                    case "release-check":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.ReleaseRequest.self, from: input)
                        try emit(AppEngineWorkflows.releaseCheck(request))
                    case "project-release-check":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.ProjectReleaseRequest.self, from: input)
                        try emit(AppEngineWorkflows.projectReleaseCheck(request))
                    case "approve-baseline":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.BaselineRequest.self, from: input)
                        try emit(AppEngineWorkflows.approveBaseline(request))
                    case "correct-judgment":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.CorrectionRequest.self, from: input)
                        try emit(AppEngineWorkflows.correctJudgment(request))
                    case "select-assessment":
                        let request = try CanonicalJSON.decode(AppEngineWorkflows.SelectionRequest.self, from: input)
                        try emit(AppEngineWorkflows.selectAssessment(request))
                    case "extract-reference":
                        let request = try CanonicalJSON.decode(AppEngineReferenceImporter.Request.self, from: input)
                        try emit(AppEngineReferenceImporter.extract(request))
                    case "validate-suite":
                        let request = try CanonicalJSON.decode(AppEngineBridge.Request.self, from: input)
                        let issue = AppEngineValidation.validationIssue(for: request.suite, includeModelReadiness: false)
                        try emit(AppEngineBridge.Validation(valid: issue == nil,
                            issue: issue,
                            revision: AppEngineBridge.revision(for: request.suite)))
                    case "export-suite":
                        let request = try CanonicalJSON.decode(AppEngineBridge.Request.self, from: input)
                        try emit(EvaluationSuiteDefinition(suite: request.suite))
                    default:
                        let request = try CanonicalJSON.decode(AppEngineBridge.AnalysisRequest.self, from: input)
                        try emit(EvaluationRunAnalysis(run: request.run))
                    }
                    return
                }
                throw RunnerFailure(kind: "unsupportedOS", message: "App-engine evaluations require macOS 27 or later.")
            }
            let request = try RunnerRequest.parse(input)
            if #available(macOS 26.0, *) {
                switch request {
                case .availability: try emit(OnDeviceRunner.availability())
                case .evaluate(let request): try emit(await OnDeviceRunner.evaluate(request))
                }
            } else {
                let reason = "macOS 26 or later is required for Apple Foundation Models."
                switch request {
                case .availability: try emit(AvailabilityOutput(available: false, reason: reason))
                case .evaluate: try emit(EvaluationOutput.failed(RunnerFailure(kind: "unsupportedOS", message: reason), started: started, uptime: uptime))
                }
            }
        } catch {
            let failure = error as? RunnerFailure ?? RunnerFailure(kind: "runnerError", message: error.localizedDescription)
            FileHandle.standardError.write(Data("\(failure.kind): \(failure.message)\n".utf8))
            let output = EvaluationOutput.failed(failure, started: started, uptime: uptime)
            do { try emit(output) }
            catch {
                // Fixed literal remains a single JSON object if encoding itself fails.
                FileHandle.standardOutput.write(Data("{\"status\":\"failed\",\"model\":\"Apple Foundation Models\",\"results\":[],\"error\":{\"kind\":\"serializationError\",\"message\":\"Could not encode runner output.\"}}\n".utf8))
            }
        }
    }

    /// Evaluates an app-engine request while translating termination and interrupt signals into cooperative task cancellation.
    @available(macOS 27.0, *)
    static func evaluateWithCancellationSignals(_ input: Data) async throws -> AppEngineBridge.Output {
        return try await withCancellationSignals { try await AppEngineBridge.evaluate(input) }
    }

    /// Runs an asynchronous operation with SIGTERM and SIGINT sources that cancel its task, removing the sources when it finishes.
    /// The host owns the cancellation grace period and eventual force-kill fallback; operation errors propagate.
    @available(macOS 27.0, *)
    static func withCancellationSignals<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        // The host bounds the grace period and owns the eventual SIGKILL fallback.
        // Cancellation flows through the actual app actor, preserving its partial samples.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let operation = Task { try await body() }
        let signals = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { operation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        return try await operation.value
    }

    /// Writes sorted-key JSON with ISO 8601 dates and a trailing newline to stdout, propagating encoding failures.
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
