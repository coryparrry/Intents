import Foundation

struct EvaluationTokenSummary: Codable, Equatable, Sendable {
    var requestCount: Int
    var usageUnavailableSampleCount: Int
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }

    fileprivate init(usages: [EvaluationUsage], usageUnavailableSampleCount: Int = 0) {
        requestCount = usages.count
        self.usageUnavailableSampleCount = usageUnavailableSampleCount
        inputTokens = usages.reduce(0) { $0 + $1.inputTokens }
        cachedInputTokens = usages.reduce(0) { $0 + $1.cachedInputTokens }
        outputTokens = usages.reduce(0) { $0 + $1.outputTokens }
        reasoningTokens = usages.reduce(0) { $0 + $1.reasoningTokens }
    }
}

struct EvaluationLatencySummary: Codable, Equatable, Sendable {
    var sampleCount: Int
    var p50Milliseconds: Double?
    var p95Milliseconds: Double?

    fileprivate init(milliseconds: [Double]) {
        let sorted = milliseconds.filter { $0.isFinite && $0 >= 0 }.sorted()
        sampleCount = sorted.count
        p50Milliseconds = Self.percentile(0.50, in: sorted)
        p95Milliseconds = Self.percentile(0.95, in: sorted)
    }

    private static func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double? {
        guard let first = sortedValues.first else { return nil }
        guard sortedValues.count > 1 else { return first }

        let position = percentile * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }

        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction
    }
}

enum EvaluationRepetitionVariation: String, Codable, Equatable, Sendable {
    case noScoredSamples
    case insufficientScoredSamples
    case consistentlyPassed
    case consistentlyFailed
    case mixedPassAndFail
}

struct EvaluationCaseAnalysis: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { caseID }

    var caseID: UUID
    var caseName: String
    var prompt: String
    var expected: String
    var plannedSampleCount: Int
    var completedSampleCount: Int
    var missingSampleCount: Int
    var scoredSampleCount: Int
    var passedSampleCount: Int
    var failedSampleCount: Int
    var unscoredSampleCount: Int
    var errorSampleCount: Int
    var scoredPassRate: Double?
    var repetitionVariation: EvaluationRepetitionVariation
    var conversation: EvaluationConversationConfiguration? = nil
    var fieldAssertions: [EvaluationFieldAssertion]? = nil
}

struct EvaluationRunAnalysis: Codable, Equatable, Sendable {
    var runID: UUID
    var plannedSampleCount: Int
    var completedSampleCount: Int
    var missingSampleCount: Int
    var scoredSampleCount: Int
    var passedSampleCount: Int
    var failedSampleCount: Int
    var unscoredSampleCount: Int
    var errorSampleCount: Int
    var scoredPassRate: Double?
    var subjectLatency: EvaluationLatencySummary
    var subjectUsage: EvaluationTokenSummary
    var judgeUsage: EvaluationTokenSummary
    var cases: [EvaluationCaseAnalysis]

    init(run: EvaluationRun) {
        let buckets = run.results.map(SampleBucket.init(result:))
        let passed = buckets.count(where: { $0 == .passed })
        let failed = buckets.count(where: { $0 == .failed })
        let scored = passed + failed

        runID = run.id
        plannedSampleCount = run.plannedResultCount
        completedSampleCount = run.results.count
        missingSampleCount = max(0, run.plannedResultCount - run.results.count)
        scoredSampleCount = scored
        passedSampleCount = passed
        failedSampleCount = failed
        unscoredSampleCount = buckets.count(where: { $0 == .unscored })
        errorSampleCount = buckets.count(where: { $0 == .error })
        scoredPassRate = scored == 0 ? nil : Double(passed) / Double(scored)
        subjectLatency = EvaluationLatencySummary(
            milliseconds: run.results.compactMap { result in
                result.hasSubjectError ? nil : result.durationMilliseconds
            }
        )
        let subjectUsageUnavailable = run.results.count(where: {
            $0.hasSubjectError && $0.usage.isEmpty
        })
        subjectUsage = EvaluationTokenSummary(
            usages: run.results.compactMap { result in
                result.hasSubjectError && result.usage.isEmpty ? nil : result.usage
            },
            usageUnavailableSampleCount: subjectUsageUnavailable
        )
        judgeUsage = EvaluationTokenSummary(
            usages: run.results.compactMap(\.judgeUsage),
            usageUnavailableSampleCount: run.results.count(where: {
                $0.hasJudgeError && $0.judgeUsage == nil
            })
        )
        cases = Self.caseAnalyses(for: run)
    }

    private static func caseAnalyses(for run: EvaluationRun) -> [EvaluationCaseAnalysis] {
        var definitions: [UUID: CaseDefinition] = [:]
        var orderedIDs: [UUID] = []

        for evaluationCase in run.plannedCases ?? [] {
            guard definitions[evaluationCase.id] == nil else { continue }
            definitions[evaluationCase.id] = CaseDefinition(evaluationCase)
            orderedIDs.append(evaluationCase.id)
        }
        for result in run.results where definitions[result.caseID] == nil {
            definitions[result.caseID] = CaseDefinition(result)
            orderedIDs.append(result.caseID)
        }

        let resultsByCase = Dictionary(grouping: run.results, by: \.caseID)
        return orderedIDs.compactMap { caseID in
            guard let definition = definitions[caseID] else { return nil }
            let results = resultsByCase[caseID, default: []]
            let buckets = results.map(SampleBucket.init(result:))
            let passed = buckets.count(where: { $0 == .passed })
            let failed = buckets.count(where: { $0 == .failed })
            let scored = passed + failed
            let variation: EvaluationRepetitionVariation
            if scored == 0 {
                variation = .noScoredSamples
            } else if scored == 1 || run.repetitions <= 1 {
                variation = .insufficientScoredSamples
            } else if passed == scored {
                variation = .consistentlyPassed
            } else if failed == scored {
                variation = .consistentlyFailed
            } else {
                variation = .mixedPassAndFail
            }

            return EvaluationCaseAnalysis(
                caseID: caseID,
                caseName: definition.name,
                prompt: definition.prompt,
                expected: definition.expected,
                plannedSampleCount: run.repetitions,
                completedSampleCount: results.count,
                missingSampleCount: max(0, run.repetitions - results.count),
                scoredSampleCount: scored,
                passedSampleCount: passed,
                failedSampleCount: failed,
                unscoredSampleCount: buckets.count(where: { $0 == .unscored }),
                errorSampleCount: buckets.count(where: { $0 == .error }),
                scoredPassRate: scored == 0 ? nil : Double(passed) / Double(scored),
                repetitionVariation: variation,
                conversation: definition.conversation,
                fieldAssertions: definition.fieldAssertions
            )
        }
    }
}

enum EvaluationRunComparisonCompatibility: String, Codable, Equatable, Sendable {
    case compatible
    case partialCoverage
    case incompatible
}

enum EvaluationRunComparisonWarning: String, Codable, Equatable, Sendable {
    case suiteVersionChanged
    case instructionsChanged
    case subjectModelChanged
    case modelConfigurationChanged
    case executionContractUnavailable
    case executionContractChanged
    case environmentChanged
    case referencesChanged
}

enum EvaluationCaseComparisonChange: String, Codable, Equatable, Sendable {
    case improved
    case regressed
    case unchanged
    case notComparable
}

enum EvaluationCaseComparisonIssue: String, Codable, Equatable, Sendable {
    case missingFromCurrentRun
    case missingFromBaselineRun
    case caseDefinitionChanged
    case incompleteScoredCoverage
}

struct EvaluationScoredRate: Codable, Equatable, Sendable {
    var passedSampleCount: Int
    var scoredSampleCount: Int
    var plannedSampleCount: Int
    var passRate: Double?

    fileprivate init(caseAnalysis: EvaluationCaseAnalysis) {
        passedSampleCount = caseAnalysis.passedSampleCount
        scoredSampleCount = caseAnalysis.scoredSampleCount
        plannedSampleCount = caseAnalysis.plannedSampleCount
        passRate = caseAnalysis.scoredPassRate
    }
}

struct EvaluationCaseComparison: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { caseID }

    var caseID: UUID
    var caseName: String
    var current: EvaluationScoredRate?
    var baseline: EvaluationScoredRate?
    var passRateDelta: Double?
    var change: EvaluationCaseComparisonChange
    var issue: EvaluationCaseComparisonIssue?
}

struct EvaluationRunComparisonCoverage: Codable, Equatable, Sendable {
    var currentCaseCount: Int
    var baselineCaseCount: Int
    var unchangedCaseCount: Int
    var changedCaseCount: Int
    var currentOnlyCaseCount: Int
    var baselineOnlyCaseCount: Int
    var comparableRateCaseCount: Int
}

struct EvaluationRunComparison: Codable, Equatable, Sendable {
    var currentRunID: UUID
    var baselineRunID: UUID
    var compatibility: EvaluationRunComparisonCompatibility
    var incompatibilityReasons: [String]
    var warnings: [EvaluationRunComparisonWarning]
    var coverage: EvaluationRunComparisonCoverage
    var caseComparisons: [EvaluationCaseComparison]
    var improvedCaseCount: Int
    var regressedCaseCount: Int
    var unchangedCaseCount: Int
    var meanComparableCasePassRateDelta: Double?

    init(current: EvaluationRun, baseline: EvaluationRun) {
        currentRunID = current.id
        baselineRunID = baseline.id

        let incompatibilities = Self.incompatibilities(current: current, baseline: baseline)
        incompatibilityReasons = incompatibilities
        warnings = Self.warnings(current: current, baseline: baseline)

        let currentAnalysis = EvaluationRunAnalysis(run: current)
        let baselineAnalysis = EvaluationRunAnalysis(run: baseline)
        let comparisons = incompatibilities.isEmpty
            ? Self.compareCases(current: currentAnalysis.cases, baseline: baselineAnalysis.cases)
            : []
        caseComparisons = comparisons

        let currentIDs = Set(currentAnalysis.cases.map(\.caseID))
        let baselineIDs = Set(baselineAnalysis.cases.map(\.caseID))
        let changedCount = comparisons.count(where: { $0.issue == .caseDefinitionChanged })
        let unchangedCount = comparisons.count(where: {
            $0.issue != .caseDefinitionChanged
                && $0.issue != .missingFromCurrentRun
                && $0.issue != .missingFromBaselineRun
        })
        let comparable = comparisons.filter { $0.change != .notComparable }
        coverage = EvaluationRunComparisonCoverage(
            currentCaseCount: currentAnalysis.cases.count,
            baselineCaseCount: baselineAnalysis.cases.count,
            unchangedCaseCount: unchangedCount,
            changedCaseCount: changedCount,
            currentOnlyCaseCount: currentIDs.subtracting(baselineIDs).count,
            baselineOnlyCaseCount: baselineIDs.subtracting(currentIDs).count,
            comparableRateCaseCount: comparable.count
        )

        if !incompatibilities.isEmpty {
            compatibility = .incompatible
        } else if comparisons.contains(where: { $0.change == .notComparable }) {
            compatibility = .partialCoverage
        } else {
            compatibility = .compatible
        }

        improvedCaseCount = comparable.count(where: { $0.change == .improved })
        regressedCaseCount = comparable.count(where: { $0.change == .regressed })
        self.unchangedCaseCount = comparable.count(where: { $0.change == .unchanged })
        let deltas = comparable.compactMap(\.passRateDelta)
        meanComparableCasePassRateDelta = deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count)
    }

    private static func sameConversation(
        _ lhs: EvaluationConversationConfiguration?, _ rhs: EvaluationConversationConfiguration?
    ) -> Bool {
        let lhs = lhs ?? EvaluationConversationConfiguration()
        let rhs = rhs ?? EvaluationConversationConfiguration()
        return lhs.setupTurns.map(\.prompt) == rhs.setupTurns.map(\.prompt)
            && lhs.restoredTranscriptJSON == rhs.restoredTranscriptJSON
            && lhs.historyPolicy == rhs.historyPolicy
            && (lhs.historyPolicy != .retainRecentCompleteTurns || lhs.retainedTurnCount == rhs.retainedTurnCount)
            && (lhs.modelHistoryProjection ?? .init()) == (rhs.modelHistoryProjection ?? .init())
    }

    private static func sameAssertions(_ lhs: [EvaluationFieldAssertion]?, _ rhs: [EvaluationFieldAssertion]?) -> Bool {
        let lhs = lhs ?? []
        let rhs = rhs ?? []
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.pointer == $1.pointer && $0.operation == $1.operation
                && ($0.operation == .exists || $0.expectedValue == $1.expectedValue)
        }
    }

    private static func incompatibilities(current: EvaluationRun, baseline: EvaluationRun) -> [String] {
        var reasons: [String] = []
        if current.suiteID != baseline.suiteID { reasons.append("The runs belong to different suites.") }
        if current.scoringMode != baseline.scoringMode { reasons.append("The scoring mode changed.") }
        if current.scoringMode == .modelJudge, baseline.scoringMode == .modelJudge {
            if current.criteria != baseline.criteria { reasons.append("The scoring rubric changed.") }
            if current.judgePromptVersion != baseline.judgePromptVersion {
                reasons.append("The judge prompt policy changed.")
            }
            let currentPassingScore = current.judgePassingScore ?? EvaluationSuite.judgePassingScore
            let baselinePassingScore = baseline.judgePassingScore ?? EvaluationSuite.judgePassingScore
            if currentPassingScore != baselinePassingScore {
                reasons.append("The judge passing score changed.")
            }
        }
        return reasons
    }

    private static func warnings(
        current: EvaluationRun,
        baseline: EvaluationRun
    ) -> [EvaluationRunComparisonWarning] {
        var warnings: [EvaluationRunComparisonWarning] = []
        if current.suiteVersion != baseline.suiteVersion { warnings.append(.suiteVersionChanged) }
        if current.instructions != baseline.instructions { warnings.append(.instructionsChanged) }
        if current.environment.model != baseline.environment.model { warnings.append(.subjectModelChanged) }
        if current.execution?.configuration != baseline.execution?.configuration
            || (current.execution?.features ?? .init()) != (baseline.execution?.features ?? .init()) {
            warnings.append(.modelConfigurationChanged)
        }
        if current.execution == nil || baseline.execution == nil {
            warnings.append(.executionContractUnavailable)
        } else if current.execution?.behaviorVersion != baseline.execution?.behaviorVersion
            || current.execution?.capabilities != baseline.execution?.capabilities
            || current.execution?.toolNames != baseline.execution?.toolNames {
            warnings.append(.executionContractChanged)
        }
        if current.environment.operatingSystem != baseline.environment.operatingSystem
            || current.environment.locale != baseline.environment.locale
            || current.environment.modelContextSize != baseline.environment.modelContextSize {
            warnings.append(.environmentChanged)
        }
        if attachmentSignatures(current.attachments) != attachmentSignatures(baseline.attachments) {
            warnings.append(.referencesChanged)
        }
        return warnings
    }

    private static func attachmentSignatures(_ attachments: [EvaluationAttachmentTrace]) -> [String] {
        attachments.map {
            "\($0.name)|\($0.kind.rawValue)|\($0.byteCount)|\($0.sha256)"
        }.sorted()
    }

    private static func compareCases(
        current: [EvaluationCaseAnalysis],
        baseline: [EvaluationCaseAnalysis]
    ) -> [EvaluationCaseComparison] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.caseID, $0) })
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.caseID, $0) })
        var orderedIDs = current.map(\.caseID)
        orderedIDs.append(contentsOf: baseline.map(\.caseID).filter { currentByID[$0] == nil })

        return orderedIDs.map { caseID in
            let currentCase = currentByID[caseID]
            let baselineCase = baselineByID[caseID]
            let name = currentCase?.caseName ?? baselineCase?.caseName ?? "Untitled case"
            let currentRate = currentCase.map(EvaluationScoredRate.init(caseAnalysis:))
            let baselineRate = baselineCase.map(EvaluationScoredRate.init(caseAnalysis:))

            guard let currentCase else {
                return EvaluationCaseComparison(
                    caseID: caseID,
                    caseName: name,
                    current: nil,
                    baseline: baselineRate,
                    passRateDelta: nil,
                    change: .notComparable,
                    issue: .missingFromCurrentRun
                )
            }
            guard let baselineCase else {
                return EvaluationCaseComparison(
                    caseID: caseID,
                    caseName: name,
                    current: currentRate,
                    baseline: nil,
                    passRateDelta: nil,
                    change: .notComparable,
                    issue: .missingFromBaselineRun
                )
            }
            guard currentCase.prompt == baselineCase.prompt,
                  currentCase.expected == baselineCase.expected,
                  Self.sameConversation(currentCase.conversation, baselineCase.conversation),
                  Self.sameAssertions(currentCase.fieldAssertions, baselineCase.fieldAssertions) else {
                return EvaluationCaseComparison(
                    caseID: caseID,
                    caseName: name,
                    current: currentRate,
                    baseline: baselineRate,
                    passRateDelta: nil,
                    change: .notComparable,
                    issue: .caseDefinitionChanged
                )
            }
            guard currentCase.scoredSampleCount == currentCase.plannedSampleCount,
                  baselineCase.scoredSampleCount == baselineCase.plannedSampleCount else {
                return EvaluationCaseComparison(
                    caseID: caseID,
                    caseName: name,
                    current: currentRate,
                    baseline: baselineRate,
                    passRateDelta: nil,
                    change: .notComparable,
                    issue: .incompleteScoredCoverage
                )
            }

            let currentPassRate = currentCase.scoredPassRate ?? 0
            let baselinePassRate = baselineCase.scoredPassRate ?? 0
            let delta = currentPassRate - baselinePassRate
            let change: EvaluationCaseComparisonChange
            if delta > 0 {
                change = .improved
            } else if delta < 0 {
                change = .regressed
            } else {
                change = .unchanged
            }
            return EvaluationCaseComparison(
                caseID: caseID,
                caseName: name,
                current: currentRate,
                baseline: baselineRate,
                passRateDelta: delta,
                change: change,
                issue: nil
            )
        }
    }
}

private enum SampleBucket {
    case passed
    case failed
    case unscored
    case error

    init(result: EvaluationSampleResult) {
        if result.hasSubjectError || result.hasJudgeError {
            self = .error
        } else {
            switch result.status {
            case .passed: self = .passed
            case .failed: self = .failed
            case .unscored: self = .unscored
            case .error: self = .error
            }
        }
    }
}

private struct CaseDefinition {
    var name: String
    var prompt: String
    var expected: String
    var conversation: EvaluationConversationConfiguration?
    var fieldAssertions: [EvaluationFieldAssertion]?

    init(_ evaluationCase: EvaluationCase) {
        name = evaluationCase.name
        prompt = evaluationCase.prompt
        expected = evaluationCase.expected
        conversation = evaluationCase.conversation
        fieldAssertions = evaluationCase.fieldAssertions
    }

    init(_ result: EvaluationSampleResult) {
        name = result.caseName
        prompt = result.prompt
        expected = result.expected
        conversation = nil
        fieldAssertions = result.fieldAssertionResults?.map(\.assertion)
    }
}

private extension EvaluationSampleResult {
    var hasSubjectError: Bool {
        status == .error || errorCategory != nil || errorMessage != nil
    }

    var hasJudgeError: Bool {
        judgeErrorCategory != nil || judgeErrorMessage != nil
    }
}

private extension EvaluationUsage {
    var isEmpty: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && outputTokens == 0
            && reasoningTokens == 0
    }
}
