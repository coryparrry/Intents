import Foundation
import FoundationModels

struct NativeProductionContext: Codable, Sendable {
    var kind = "native-suite-v1"
    var suite: EvaluationSuite
    var images: [Image]
    var reportedModel: String {
        suite.modelConfiguration.provider == .onDevice
            ? "On-device · \(suite.modelConfiguration.systemModel.variant.displayName)"
            : suite.modelConfiguration.provider.title
    }
    /// Reports total attempt cost only when subject-model charges are known; custom HTTP subject costs remain unavailable.
    /// An external judge also requires a reported judge cost, while other supported native attempts report zero.
    func reportedCost(judgeCost: EvaluationCost?) -> Double? {
        // Custom subject-model charges are not captured by the native runner.
        // A known judge charge alone cannot establish the total attempt cost.
        guard suite.modelConfiguration.provider != .customHTTP else { return nil }
        return suite.judgeConfiguration.usesExternalConnection ? judgeCost?.usd : 0
    }
    struct Image: Codable, Sendable { var label: String; var bytes: Data }
}

actor NativeProductionExecutor {
    let context: NativeProductionContext
    let executionRevision: String
    let judge: EvaluationResolvedJudgeConnection?
    let runner = EvaluationRunner(batchTokenCounter: EvaluationCachedPromptInputTokenCounter())
    let imageDirectory: URL
    let images: [ImageEvaluationInput]
    /// Freezes one native job context and prepares its image inputs and job-scoped runner.
    init(context: NativeProductionContext, executionRevision: String, judge: EvaluationResolvedJudgeConnection?) throws {
        self.context = context; self.executionRevision = executionRevision; self.judge = judge
        imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("production-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values: [ImageEvaluationInput] = []
        do {
            for (index,image) in context.images.enumerated() {
                let url = imageDirectory.appendingPathComponent("\(index).image")
                try image.bytes.write(to: url); values.append(.init(label: image.label, url: url))
            }
        } catch { try? FileManager.default.removeItem(at: imageDirectory); throw error }
        images = values
    }
    /// Removes this executor's temporary image directory, ignoring cleanup failures.
    deinit { try? FileManager.default.removeItem(at: imageDirectory) }
    /// Executes one frozen native slot and returns its output, verdict, timing, bounded trace and available cost.
    /// Throws on revision mismatch, invalid scored input, absent evidence or oversized trace.
    func execute(_ request: ProductionRequest) async throws -> ProductionResponse {
        guard request.configuration.executionRevision == executionRevision else {
            throw ProductionFailure.integrity("Native worker setup differs from this frozen job.")
        }
        var suite = context.suite
        var example = try request.example.input.map { try ProductionCodec.decode(EvaluationCase.self, $0) }
            ?? EvaluationCase(name: request.example.id, prompt: request.example.prompt, expected: request.example.expected ?? "")
        example.id = request.requestID; example.prompt = request.example.prompt; example.expected = request.example.expected ?? ""
        suite.cases = [example]; suite.repetitions = 1
        guard !suite.scoringMode.needsExpected || !example.expected.isEmpty else {
            throw ProductionFailure.invalid("Scored text examples need an expected answer.")
        }
        let run = await runner.run(id: request.requestID, suiteRevision: request.jobRevision, startedAt: Date(),
                                   suite: suite, images: images, externalJudge: judge, progress: { _,_,_ in })
        guard let result = run.results.first else { throw ProductionFailure.unavailable("Native runner returned no evidence.") }
        let artifact = try ProductionCodec.encode(run)
        guard artifact.count <= 262_144 else { throw ProductionFailure.invalid("Trace exceeds the per-result evidence limit. Use a developer worker with a bounded trace.") }
        let outcome = ProductionOutcome(rawValue: result.status.rawValue) ?? .error
        // Paid/external judge costs remain unknown unless the provider supplies them.
        let cost = context.reportedCost(judgeCost: result.judgeCost)
        return .init(requestID: request.requestID, outcome: outcome, output: result.response,
                     explanation: result.errorMessage ?? result.judgeErrorMessage ?? result.rationale,
                     latencyMilliseconds: result.durationMilliseconds, cost: cost, artifact: artifact)
    }
}
