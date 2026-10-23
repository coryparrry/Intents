import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationExperimentRunnerFatalStopTests {
    @Test(arguments: ["emptyCases", "negativeRepetitions", "overflow", "duplicateCase", "sameVariant", "unknownVariant", "duplicateVariant", "missingPosition"])
    func invalidPlansFailBeforeRunningAnyPart(mutation: String) async throws {
        var (suite, experiment) = makeExperiment()
        switch mutation {
        case "emptyCases": suite.cases = []
        case "negativeRepetitions": suite.repetitions = -1
        case "overflow": suite.repetitions = Int.max
        case "duplicateCase": suite.cases.append(suite.cases[0])
        case "sameVariant": experiment.candidate.id = experiment.current.id
        case "unknownVariant": experiment.executionOrder[0] = UUID()
        case "duplicateVariant": experiment.executionOrder[1] = experiment.executionOrder[0]
        default: experiment.executionOrder.removeLast()
        }
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            await recorder.record(partSuite.instructions)
            return makeRun(suite: partSuite)
        }
        do {
            _ = try await runner.run(suite: suite, experiment: experiment, images: [], externalJudge: nil,
                                     progress: { _, _, _ in })
            Issue.record("Expected an invalid experiment plan to be rejected.")
        } catch {
            #expect(error is EvaluationStoreError)
        }
        #expect(await recorder.count == 0)
    }

    @Test func cancellationDuringLastPartCannotPublishCompletedVariants() async throws {
        let (suite, experiment) = makeExperiment()
        let recorder = PartCallRecorder()
        let task = Task {
            let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
                let call = await recorder.nextCall()
                if call == experiment.executionOrder.count { withUnsafeCurrentTask { $0?.cancel() } }
                return makeRun(suite: partSuite)
            }
            return try await runner.run(suite: suite, experiment: experiment, images: [], externalJudge: nil,
                                        progress: { _, _, _ in })
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation after the last part.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await recorder.count == experiment.executionOrder.count)
    }

    @Test
    func fatalFirstPartStopsEveryLaterPositionAndKeepsFailureEvidence() async throws {
        let (suite, experiment) = makeExperiment()
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            await recorder.record(partSuite.instructions)
            return makeRun(suite: partSuite, terminationReason: "serviceUnavailable")
        }

        let outcome = try await runner.run(
            suite: suite,
            experiment: experiment,
            images: [],
            externalJudge: nil,
            progress: { _, _, _ in }
        )

        #expect(await recorder.count == 1)
        #expect(outcome.current.results.count == 1)
        #expect(outcome.current.results[0].judgeErrorCategory == "serviceUnavailable")
        #expect(outcome.current.terminationReason == "serviceUnavailable")
        #expect(outcome.candidate.results.isEmpty)
        #expect(outcome.candidate.terminationReason == "serviceUnavailable")
        #expect(outcome.candidate.stoppedEarly)
    }

    @Test(arguments: [2, 3, 4], [false, true])
    func fatalLaterPartMarksEveryIncompleteVariantStopped(
        failurePosition: Int, candidateFirst: Bool
    ) async throws {
        let (suite, frozen) = makeExperiment()
        var experiment = frozen
        let first = candidateFirst ? experiment.candidate.id : experiment.current.id
        let second = candidateFirst ? experiment.current.id : experiment.candidate.id
        experiment.executionOrder = [first, second, second, first]
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            let call = await recorder.nextCall()
            return makeRun(
                suite: partSuite,
                response: "part-\(call)",
                status: call == failurePosition ? .error : .passed,
                terminationReason: call == failurePosition ? "serviceUnavailable" : nil
            )
        }

        let outcome = try await runner.run(
            suite: suite, experiment: experiment, images: [], externalJudge: nil,
            progress: { _, _, _ in }
        )

        #expect(await recorder.count == failurePosition)
        for (variantID, run) in [(experiment.current.id, outcome.current),
                                 (experiment.candidate.id, outcome.candidate)] {
            let positions = experiment.executionOrder.prefix(failurePosition).enumerated()
                .filter { $0.element == variantID }.map { $0.offset + 1 }
            #expect(run.results.map(\.response) == positions.map { "part-\($0)" })
            #expect(run.plannedResultCount == 2)
            if run.results.count < run.plannedResultCount {
                #expect(run.terminationReason == "serviceUnavailable")
                #expect(run.stoppedEarly)
            } else if positions.contains(failurePosition) {
                #expect(run.terminationReason == "serviceUnavailable")
                #expect(!run.stoppedEarly)
            } else {
                // A fully successful variant stays complete when its peer fails.
                #expect(run.terminationReason == nil)
                #expect(!run.stoppedEarly)
                #expect(run.results.allSatisfy { $0.status == .passed })
            }
        }
    }

    @Test
    func laterFatalPartMarksIncompleteCounterpartAsStoppedEarly() async throws {
        let (suite, experiment) = makeExperiment()
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            let call = await recorder.nextCall()
            return makeRun(
                suite: partSuite,
                response: "part-\(call)",
                terminationReason: call == 3 ? "serviceUnavailable" : nil
            )
        }

        let outcome = try await runner.run(
            suite: suite, experiment: experiment, images: [], externalJudge: nil,
            progress: { _, _, _ in }
        )

        #expect(await recorder.count == 3)
        #expect(outcome.current.results.map(\.response) == ["part-1", "part-3"])
        #expect(outcome.candidate.results.map(\.response) == ["part-2"])
        #expect(outcome.current.terminationReason == "serviceUnavailable")
        #expect(outcome.candidate.terminationReason == "serviceUnavailable")
        #expect(outcome.candidate.stoppedEarly)
    }

    @Test
    func nonfatalSampleFailureContinuesLaterPositionsAndPreservesOrder() async throws {
        let (suite, experiment) = makeExperiment()
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            let call = await recorder.nextCall()
            return makeRun(
                suite: partSuite,
                response: "part-\(call)",
                status: .failed
            )
        }

        let outcome = try await runner.run(
            suite: suite,
            experiment: experiment,
            images: [],
            externalJudge: nil,
            progress: { _, _, _ in }
        )

        #expect(await recorder.count == 4)
        #expect(outcome.current.results.map(\.response) == ["part-1", "part-3"])
        #expect(outcome.candidate.results.map(\.response) == ["part-2", "part-4"])
        #expect(outcome.current.results.allSatisfy { $0.status == .failed })
        #expect(outcome.current.terminationReason == nil)
        #expect(outcome.candidate.terminationReason == nil)
    }

    @Test
    func cancelledPartStillThrowsCancellationError() async throws {
        let (suite, experiment) = makeExperiment()
        let recorder = PartCallRecorder()
        let runner = EvaluationExperimentRunner { _, _, _, partSuite, _, _, _ in
            await recorder.record(partSuite.instructions)
            return makeRun(suite: partSuite, cancelled: true)
        }

        do {
            _ = try await runner.run(
                suite: suite,
                experiment: experiment,
                images: [],
                externalJudge: nil,
                progress: { _, _, _ in }
            )
            Issue.record("Expected a cancelled part to throw CancellationError.")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(await recorder.count == 1)
    }
}

private actor PartCallRecorder {
    private(set) var count = 0

    func record(_ instructions: String) {
        _ = instructions
        count += 1
    }

    func nextCall() -> Int {
        count += 1
        return count
    }
}

private func makeExperiment() -> (EvaluationSuite, EvaluationExperiment) {
    var suite = EvaluationSuite()
    suite.cases = [EvaluationCase(
        name: "Case",
        prompt: "Prompt",
        expected: "Expected"
    )]
    suite.repetitions = 2

    let current = EvaluationExperimentVariant(
        id: UUID(), name: "Current", instructions: "Current instructions", suiteRevision: "current"
    )
    let candidate = EvaluationExperimentVariant(
        id: UUID(), name: "Candidate", instructions: "Candidate instructions", suiteRevision: "candidate"
    )
    let experiment = EvaluationExperiment(
        id: UUID(),
        name: "Experiment",
        createdAt: Date(timeIntervalSince1970: 0),
        suiteRevision: "suite",
        casesDigest: "cases",
        scoringDigest: "scoring",
        judgeDigest: "judge",
        current: current,
        candidate: candidate,
        executionOrder: [current.id, candidate.id, current.id, candidate.id],
        runIDs: [],
        decision: nil
    )
    return (suite, experiment)
}

private func makeRun(
    suite: EvaluationSuite,
    response: String = "Response",
    status: EvaluationResultStatus = .error,
    terminationReason: String? = nil,
    cancelled: Bool = false
) -> EvaluationRun {
    let evaluationCase = suite.cases[0]
    let result = EvaluationSampleResult(
        caseID: evaluationCase.id,
        caseName: evaluationCase.name,
        repetition: 1,
        prompt: evaluationCase.prompt,
        effectivePrompt: nil,
        expected: evaluationCase.expected,
        response: response,
        reasoningText: nil,
        status: status,
        score: status == .failed ? 1 : nil,
        rationale: nil,
        durationMilliseconds: 1,
        usage: EvaluationUsage(),
        judgeDurationMilliseconds: nil,
        judgeUsage: nil,
        judgeReasoningText: nil,
        errorCategory: nil,
        errorMessage: nil,
        judgeErrorCategory: terminationReason,
        judgeErrorMessage: terminationReason.map { "Stubbed \($0)" }
    )
    return EvaluationRun(
        id: UUID(),
        suiteID: suite.id,
        suiteName: suite.name,
        suiteVersion: suite.version,
        instructions: suite.instructions,
        criteria: suite.criteria,
        scoringMode: suite.scoringMode,
        repetitions: suite.repetitions,
        judgePromptVersion: nil,
        judgePassingScore: nil,
        plannedSampleCount: 1,
        suiteRevision: "revision",
        plannedCases: suite.cases,
        startedAt: Date(timeIntervalSince1970: 0),
        completedAt: Date(timeIntervalSince1970: 1),
        cancelled: cancelled,
        terminationReason: cancelled ? "cancelled" : terminationReason,
        environment: EvaluationEnvironment(
            operatingSystem: "Test OS",
            locale: "en_GB",
            model: "Test model",
            modelContextSize: 1
        ),
        attachments: [],
        results: cancelled ? [] : [result]
    )
}
