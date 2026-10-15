import Foundation
import CryptoKit

/// The standalone boundary delegates every sample to the app's evaluation actor.
/// The compatibility envelope is only a projection; appRun is authoritative evidence.
@available(macOS 27.0, *)
enum AppEngineBridge {
    struct ImageInput: Decodable, Sendable { var label: String; var url: URL }
    struct Request: Decodable, Sendable {
        var suite: EvaluationSuite
        var runID: UUID? = nil
        var suiteRevision: String? = nil
        var images: [ImageInput]? = nil
        var emitEvents: Bool? = nil
    }
    struct SampleEvent: Encodable {
        let event = "sample"
        var result: EvaluationSampleResult
        var completed: Int
        var total: Int
        var runID: UUID? = nil
    }
    struct LiveEvent: Encodable {
        let event = "liveResponse"
        var value: EvaluationLiveResponse
        var runID: UUID? = nil
    }
    static func event<T: Encodable>(_ value: T) {
        guard var data = try? CanonicalJSON.data(for: value, prettyPrinted: false) else { return }
        data.append(10)
        FileHandle.standardError.write(data)
    }

    struct Validation: Encodable { var valid: Bool; var issue: String?; var revision: String }
    struct AnalysisRequest: Decodable { var run: EvaluationRun }

    static func capabilities(available: Bool, reason: String?) -> [String: CapabilityAvailability] {
        let supported = EvaluationModelConfiguration().systemModel.capabilities
        var values: [String: CapabilityAvailability] = [:]
        for name in ["appEngine", "onDeviceModel", "conversations", "transcripts", "workflowTraces"] {
            values[name] = CapabilityAvailability(available: available, reason: reason)
        }
        for (name, feature) in [("reasoning", supported.contains(.reasoning)),
                                ("structuredOutput", supported.contains(.guidedGeneration)),
                                ("sameModelJudge", supported.contains(.guidedGeneration)),
                                ("tools", supported.contains(.toolCalling)),
                                ("spotlight", supported.contains(.toolCalling)),
                                ("vision", supported.contains(.vision))] {
            values[name] = CapabilityAvailability(available: available && feature,
                reason: available ? feature ? nil : "The on-device model does not declare this capability." : reason)
        }
        return values
    }

    struct Output: Encodable, Sendable {
        var status: String
        var model = nativeModelName
        var startedAt: String
        var finishedAt: String
        var durationMs: Double
        var results: [EvaluationResult]
        var error: RunnerFailure?
        var appRun: EvaluationRun
        var analysis: EvaluationRunAnalysis
    }

    static func evaluate(_ data: Data) async throws -> Output {
        let request = try CanonicalJSON.decode(Request.self, from: data)
        if let issue = AppEngineValidation.validationIssue(for: request.suite, includeModelReadiness: false) {
            throw RunnerFailure.validation(issue)
        }
        let images = try resolveImages(suite: request.suite, inputs: request.images ?? [])
        let started = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let revision = try revision(for: request.suite)
        if let expected = request.suiteRevision, expected != revision {
            throw RunnerFailure.validation("The suite revision changed before execution.")
        }
        var run = await EvaluationRunner().run(id: request.runID ?? UUID(), suiteRevision: revision,
            startedAt: started, suite: request.suite,
            images: images,
            liveResponse: { value in
                if request.emitEvents == true { event(LiveEvent(value: value)) }
            },
            progress: { result, completed, total in
                if request.emitEvents == true { event(SampleEvent(result: result, completed: completed, total: total)) }
            })
        run.suiteDefinition = EvaluationSuiteDefinition(suite: request.suite)
        let results = try run.results.map { sample in
            let failure = sample.errorCategory.map {
                RunnerFailure(kind: $0, message: sample.errorMessage ?? $0)
            } ?? sample.judgeErrorCategory.map {
                RunnerFailure(kind: $0, message: sample.judgeErrorMessage ?? $0)
            }
            let transcript = sample.featureTrace?.transcript?.transcriptJSON.flatMap {
                try? JSONDecoder().decode(JSONValue.self, from: $0)
            }
            let entries: [JSONValue]
            if case .array(let value) = transcript { entries = value }
            else if case .object(let value) = transcript, case .array(let array) = value["entries"] { entries = array }
            else { entries = transcript.map { [$0] } ?? [] }
            return EvaluationResult(caseId: sample.caseID.uuidString, repetition: sample.repetition,
                prompt: sample.prompt, expected: sample.expected, response: sample.response,
                passed: sample.status == .passed ? true : sample.status == .failed || sample.status == .error ? false : nil,
                score: sample.score.map(Double.init), durationMs: sample.durationMilliseconds,
                trace: EvaluationTrace(transcript: entries, error: failure,
                    appSample: try JSONDecoder().decode(JSONValue.self, from: CanonicalJSON.data(for: sample))))
        }
        let failure = results.compactMap(\.trace.error).first
        return Output(status: run.cancelled ? "cancelled" : failure == nil ? "completed" : "failed",
            startedAt: timestamp(run.startedAt), finishedAt: timestamp(run.completedAt),
            durationMs: elapsedMilliseconds(since: uptime), results: results, error: failure,
            appRun: run, analysis: EvaluationRunAnalysis(run: run))
    }

    static func resolveImages(suite: EvaluationSuite, inputs: [ImageInput]) throws -> [ImageEvaluationInput] {
        let images = inputs
        guard images.count == suite.attachments.filter({ $0.kind == .image }).count else {
            throw RunnerFailure.validation("Every image attachment needs a corresponding image input URL.")
        }
        for (attachment, image) in zip(suite.attachments.filter({ $0.kind == .image }), images) {
            guard image.label == attachment.name, image.url.isFileURL, FileManager.default.isReadableFile(atPath: image.url.path) else {
                throw RunnerFailure.validation("Image inputs must be readable local file URLs.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: image.url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == attachment.byteCount,
                  attachment.byteCount <= AppEngineValidation.maximumImageBytes else {
                throw RunnerFailure.validation("The image reference changed or exceeds the app size limit.")
            }
            let handle = try FileHandle(forReadingFrom: image.url)
            defer { try? handle.close() }
            var bytes = Data()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= AppEngineValidation.maximumImageBytes else { throw RunnerFailure.validation("Image reference exceeds the app size limit.") }
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == attachment.byteCount, digest == attachment.sha256 else {
                throw RunnerFailure.validation("The image reference failed its saved size or SHA-256 check.")
            }
        }
        return images.map { ImageEvaluationInput(label: $0.label, url: $0.url) }
    }

    static func revision(for suite: EvaluationSuite) throws -> String {
        let payload = SuiteRevisionPayload(
            id: suite.id,
            name: suite.name,
            version: suite.version,
            instructions: suite.instructions,
            rubricCriteria: suite.rubricCriteria,
            scoringMode: suite.scoringMode,
            repetitions: suite.repetitions,
            modelConfiguration: suite.modelConfiguration,
            features: suite.features,
            cases: suite.cases,
            attachments: suite.attachments.map {
                RevisionAttachment(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.kind,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256,
                    textSHA256: $0.kind == .text ? $0.text.map {
                        SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
                    } : nil
                )
            },
            judgeConfiguration: suite.judgeConfiguration,
            releasePolicy: suite.releasePolicy
        )
        return SHA256.hash(data: try CanonicalJSON.data(for: payload, prettyPrinted: false)).map { String(format: "%02x", $0) }.joined()
    }
}

@available(macOS 27.0, *)
private struct SuiteRevisionPayload: Codable {
    var id: UUID
    var name: String
    var version: String
    var instructions: String
    var rubricCriteria: [String]
    var scoringMode: ScoringMode
    var repetitions: Int
    var modelConfiguration: EvaluationModelConfiguration
    var features: EvaluationFeatureConfiguration
    var cases: [EvaluationCase]
    var attachments: [RevisionAttachment]
    var judgeConfiguration: EvaluationJudgeConfiguration
    var releasePolicy: EvaluationReleasePolicy
}

@available(macOS 27.0, *)
private struct RevisionAttachment: Codable {
    var id: UUID
    var name: String
    var kind: EvaluationAttachmentKind
    var byteCount: Int
    var sha256: String
    // The file digest describes original bytes; PDF extraction and truncation
    // produce different executed text that must independently bind the revision.
    var textSHA256: String?
}
