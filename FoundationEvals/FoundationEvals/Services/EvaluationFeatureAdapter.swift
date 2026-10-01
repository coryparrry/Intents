import Foundation

/// A narrow bridge for exercising real application code with the same suite,
/// result, analysis, and release-report types used by the native model runner.
protocol EvaluationFeatureAdapter: Sendable {
    var displayName: String { get }
    var environment: EvaluationEnvironment { get }
    var developerExecution: EvaluationDeveloperExecution? { get }
    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput
}

extension EvaluationFeatureAdapter {
    var environment: EvaluationEnvironment {
        .init(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier,
            model: "Feature adapter · \(displayName)",
            modelContextSize: 0
        )
    }

    var developerExecution: EvaluationDeveloperExecution? { nil }
}

struct EvaluationFeatureInput: Sendable {
    var caseID: UUID
    var instructions: String
    var prompt: String
    var expected: String
    var repetition: Int
}

struct EvaluationFeatureOutput: Sendable {
    var response: String
    var usage = EvaluationUsage()
}

struct EvaluationFeatureAdapterTermination: Sendable {
    var reason: String
    var cancelled: Bool
}

protocol EvaluationFeatureAdapterTerminalError: Error {
    var evaluationTermination: EvaluationFeatureAdapterTermination? { get }
}

actor EvaluationFeatureAdapterRunner {
    func run(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        repository: EvaluationRepositorySnapshot? = nil,
        suiteRevision: String,
        suite: EvaluationSuite,
        adapter: any EvaluationFeatureAdapter,
        progress: @Sendable (EvaluationSampleResult, Int, Int) async -> Void = { _, _, _ in }
    ) async -> EvaluationRun {
        let startedAt = Date()
        let total = suite.cases.count * suite.repetitions
        var results: [EvaluationSampleResult] = []
        var cancelled = false
        var terminationReason: String?

        outer: for repetition in 1...suite.repetitions {
            for evaluationCase in suite.cases {
                if Task.isCancelled {
                    cancelled = true
                    terminationReason = "cancelled"
                    break outer
                }
                let clock = ContinuousClock.now
                let result: EvaluationSampleResult
                do {
                    let output = try await adapter.evaluate(.init(
                        caseID: evaluationCase.id,
                        instructions: suite.instructions,
                        prompt: evaluationCase.prompt,
                        expected: evaluationCase.expected,
                        repetition: repetition
                    ))
                    let score = MetricScorer.evaluate(
                        mode: suite.scoringMode,
                        expected: evaluationCase.expected,
                        response: output.response
                    )
                    let assertionResults = EvaluationFieldAssertions.evaluate(
                        response: output.response,
                        assertions: evaluationCase.fieldAssertions ?? []
                    )
                    result = sample(
                        evaluationCase: evaluationCase,
                        repetition: repetition,
                        response: output.response,
                        status: EvaluationFieldAssertions.gatedStatus(
                            baseStatus: score.status,
                            results: assertionResults,
                            allowAssertionsToScore: suite.scoringMode == .review
                        ),
                        rationale: score.rationale,
                        usage: output.usage,
                        duration: milliseconds(since: clock),
                        fieldAssertionResults: assertionResults
                    )
                } catch is CancellationError {
                    cancelled = true
                    terminationReason = "cancelled"
                    break outer
                } catch let error as any EvaluationFeatureAdapterTerminalError {
                    if let termination = error.evaluationTermination {
                        result = sample(
                            evaluationCase: evaluationCase,
                            repetition: repetition,
                            response: "",
                            status: .error,
                            rationale: nil,
                            usage: .init(),
                            duration: milliseconds(since: clock),
                            errorCategory: "featureAdapterFailure",
                            errorMessage: error.localizedDescription
                        )
                        results.append(result)
                        await progress(result, results.count, total)
                        cancelled = termination.cancelled
                        terminationReason = termination.reason
                        break outer
                    }
                    result = sample(
                        evaluationCase: evaluationCase,
                        repetition: repetition,
                        response: "",
                        status: .error,
                        rationale: nil,
                        usage: .init(),
                        duration: milliseconds(since: clock),
                        errorCategory: "featureAdapterFailure",
                        errorMessage: error.localizedDescription
                    )
                } catch {
                    result = sample(
                        evaluationCase: evaluationCase,
                        repetition: repetition,
                        response: "",
                        status: .error,
                        rationale: nil,
                        usage: .init(),
                        duration: milliseconds(since: clock),
                        errorCategory: "featureAdapterFailure",
                        errorMessage: error.localizedDescription
                    )
                }
                results.append(result)
                await progress(result, results.count, total)
            }
        }

        return EvaluationRun(
            id: id,
            suiteID: suite.id,
            suiteName: suite.name,
            suiteVersion: suite.version,
            instructions: suite.instructions,
            criteria: suite.criteria,
            scoringMode: suite.scoringMode,
            repetitions: suite.repetitions,
            judgePromptVersion: suite.scoringMode == .modelJudge ? EvaluationRunner.judgePromptVersion : nil,
            judgePassingScore: suite.scoringMode == .modelJudge ? EvaluationSuite.judgePassingScore : nil,
            plannedSampleCount: total,
            suiteRevision: suiteRevision,
            plannedCases: suite.cases,
            startedAt: startedAt,
            completedAt: Date(),
            cancelled: cancelled,
            terminationReason: terminationReason,
            environment: adapter.environment,
            attachments: suite.attachments.map {
                .init(name: $0.name, kind: $0.kind, byteCount: $0.byteCount, sha256: $0.sha256)
            },
            results: results,
            projectID: projectID,
            suiteDefinition: EvaluationSuiteDefinition(suite: suite),
            repository: repository,
            developerExecution: adapter.developerExecution
        )
    }

    private func sample(
        evaluationCase: EvaluationCase,
        repetition: Int,
        response: String,
        status: EvaluationResultStatus,
        rationale: String?,
        usage: EvaluationUsage,
        duration: Double,
        errorCategory: String? = nil,
        errorMessage: String? = nil,
        fieldAssertionResults: [EvaluationFieldAssertionResult] = []
    ) -> EvaluationSampleResult {
        EvaluationSampleResult(
            caseID: evaluationCase.id,
            caseName: evaluationCase.name,
            repetition: repetition,
            prompt: evaluationCase.prompt,
            effectivePrompt: evaluationCase.prompt,
            expected: evaluationCase.expected,
            response: response,
            status: status,
            score: nil,
            rationale: rationale,
            durationMilliseconds: duration,
            usage: usage,
            judgeDurationMilliseconds: nil,
            judgeUsage: nil,
            errorCategory: errorCategory,
            errorMessage: errorMessage,
            judgeErrorCategory: nil,
            judgeErrorMessage: nil,
            fieldAssertionResults: fieldAssertionResults.isEmpty ? nil : fieldAssertionResults
        )
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

/// Compilable shared-code example used by tests and documentation. Replace the
/// closure with the application's actual feature entry point.
struct ClosureFeatureAdapter: EvaluationFeatureAdapter {
    var displayName: String
    var operation: @Sendable (EvaluationFeatureInput) async throws -> String

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        EvaluationFeatureOutput(response: try await operation(input))
    }
}
