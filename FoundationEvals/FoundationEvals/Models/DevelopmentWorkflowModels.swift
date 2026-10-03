import CryptoKit
import Foundation

// MARK: - Workspace catalog

struct EvaluationWorkspaceCatalog: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    var formatVersion = currentFormatVersion
    var selectedProjectID: UUID
    var projects: [EvaluationProject]
    var migratedLegacyStorageAt: Date?
}

struct EvaluationProject: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var repository: EvaluationRepositoryLink?
    var selectedSuiteID: UUID
    var suites: [EvaluationSuiteRecord]
    var isArchived: Bool { archivedAt != nil }
}

struct EvaluationSuiteRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var repositoryDefinitionPath: String?
    var lastRepositoryRevision: String?
    var isArchived: Bool { archivedAt != nil }
}

struct EvaluationRepositoryLink: Codable, Equatable, Sendable {
    var rootPath: String
    var definitionsDirectory = ".foundation-evals/suites"
}

/// Git-reviewed suite content. Attachments, secrets, responses, traces, approvals,
/// and machine paths deliberately remain in local state.
struct EvaluationSuiteDefinition: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    var formatVersion = currentFormatVersion
    var id: UUID
    var name: String
    var version: String
    var instructions: String
    var criteria: String
    var scoringMode: ScoringMode
    var repetitions: Int
    var modelConfiguration: EvaluationModelConfiguration
    var features: EvaluationFeatureConfiguration
    var cases: [EvaluationCase]
    var judgeConfiguration: EvaluationJudgeConfiguration
    var releasePolicy: EvaluationReleasePolicy

    init(suite: EvaluationSuite) {
        id = suite.id
        name = suite.name
        version = suite.version
        instructions = suite.instructions
        criteria = suite.criteria
        scoringMode = suite.scoringMode
        repetitions = suite.repetitions
        var portableConfiguration = suite.modelConfiguration
        if var coreAI = portableConfiguration.coreAI {
            coreAI.resourcesPath = ""
            coreAI.resourcesBookmark = nil
            portableConfiguration.coreAI = coreAI
        }
        var portableFeatures = suite.features
        portableFeatures.spotlightSearch.fileSource.folderPath = ""
        modelConfiguration = portableConfiguration
        features = portableFeatures
        cases = suite.cases
        var definitionJudge = suite.judgeConfiguration
        definitionJudge.connectionID = nil
        definitionJudge.externalEvidenceApprovedAt = nil
        definitionJudge.approvedConnectionID = nil
        definitionJudge.approvedIncludeReferenceAttachments = nil
        definitionJudge.approvedConnectionDigest = nil
        judgeConfiguration = definitionJudge
        releasePolicy = suite.releasePolicy
    }

    func applyingLocalState(from suite: EvaluationSuite) -> EvaluationSuite {
        var result = suite
        result.id = id
        result.name = name
        result.version = version
        result.instructions = instructions
        result.criteria = criteria
        result.scoringMode = scoringMode
        result.repetitions = repetitions
        result.modelConfiguration = modelConfiguration
        result.modelConfiguration.coreAI = suite.modelConfiguration.coreAI ?? modelConfiguration.coreAI
        result.features = features
        result.features.spotlightSearch.fileSource.folderPath = suite.features.spotlightSearch.fileSource.folderPath
        result.cases = cases
        var appliedJudge = judgeConfiguration
        appliedJudge.connectionID = suite.judgeConfiguration.connectionID
        appliedJudge.externalEvidenceApprovedAt = suite.judgeConfiguration.externalEvidenceApprovedAt
        appliedJudge.approvedConnectionID = suite.judgeConfiguration.approvedConnectionID
        appliedJudge.approvedIncludeReferenceAttachments = suite.judgeConfiguration.approvedIncludeReferenceAttachments
        appliedJudge.approvedConnectionDigest = suite.judgeConfiguration.approvedConnectionDigest
        result.judgeConfiguration = appliedJudge
        result.releasePolicy = releasePolicy
        return result
    }
}

struct EvaluationProjectOverview: Identifiable, Sendable {
    var id: UUID
    var name: String
    var suiteCount: Int
    var suitesNeedingChecks: Int
    var latestRunAt: Date?
    var hasStaleResults: Bool
}

// MARK: - Judge connections and provenance

enum EvaluationJudgeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sameModel
    case connection
    var id: Self { self }
}

struct EvaluationJudgeConfiguration: Codable, Equatable, Sendable {
    var mode: EvaluationJudgeMode = .sameModel
    var connectionID: UUID?
    var externalEvidenceApprovedAt: Date?
    var includeReferenceAttachments = true
    var approvedConnectionID: UUID?
    var approvedIncludeReferenceAttachments: Bool?
    var approvedConnectionDigest: String?
    var usesExternalConnection: Bool { mode == .connection }
    func hasCurrentExternalEvidenceApproval(for connection: EvaluationJudgeConnection) -> Bool {
        externalEvidenceApprovedAt != nil
            && approvedConnectionID == connectionID
            && approvedIncludeReferenceAttachments == includeReferenceAttachments
            && approvedConnectionDigest == connection.disclosureDigest
    }
}

enum EvaluationJudgeConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case localCompatible
    case openRouter
    case customCompatible
    var id: Self { self }
    var title: String {
        switch self {
        case .localCompatible: "Local compatible endpoint"
        case .openRouter: "OpenRouter"
        case .customCompatible: "Custom compatible endpoint"
        }
    }
}

struct EvaluationJudgeCapabilities: Codable, Equatable, Sendable {
    var structuredOutputs = true
    var multimodal = false
}

enum EvaluationJudgeGenerationPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case portable
    case streaming
    case deepSeekThinking
    var id: Self { self }
    var title: String {
        switch self {
        case .portable: "Portable JSON"
        case .streaming: "Streaming JSON"
        case .deepSeekThinking: "DeepSeek thinking"
        }
    }
    /// Only construction/migration uses the legacy heuristic. Runtime requests
    /// never re-infer policy when a host or model name is edited.
    static func legacyDefault(modelID: String, baseURL: String) -> Self {
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? ""
        return modelID.lowercased().contains("deepseek") || host.contains("deepseek") ? .deepSeekThinking : .portable
    }
}

struct EvaluationJudgeConnection: Identifiable, Codable, Equatable, Sendable {
    static let minimumRequestTimeoutSeconds = 1.0
    static let maximumRequestTimeoutSeconds = 900.0
    var id: UUID
    var name: String
    var kind: EvaluationJudgeConnectionKind
    var baseURL: String
    var modelID: String
    var capabilities = EvaluationJudgeCapabilities()
    var requestTimeoutSeconds = 60.0
    var providerOrder: [String] = []
    var inputUSDPerMillionTokens: Double?
    var outputUSDPerMillionTokens: Double?
    var lastCheckedAt: Date?
    var lastCheckMessage: String?
    var generationPolicy: EvaluationJudgeGenerationPolicy

    init(id: UUID, name: String, kind: EvaluationJudgeConnectionKind, baseURL: String, modelID: String,
         capabilities: EvaluationJudgeCapabilities = .init(), requestTimeoutSeconds: Double = 60,
         providerOrder: [String] = [], inputUSDPerMillionTokens: Double? = nil,
         outputUSDPerMillionTokens: Double? = nil, lastCheckedAt: Date? = nil,
         lastCheckMessage: String? = nil, generationPolicy: EvaluationJudgeGenerationPolicy? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = modelID
        self.capabilities = capabilities
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.providerOrder = providerOrder
        self.inputUSDPerMillionTokens = inputUSDPerMillionTokens
        self.outputUSDPerMillionTokens = outputUSDPerMillionTokens
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckMessage = lastCheckMessage
        self.generationPolicy = generationPolicy ?? .legacyDefault(modelID: modelID, baseURL: baseURL)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
            kind: try c.decode(EvaluationJudgeConnectionKind.self, forKey: .kind),
            baseURL: try c.decode(String.self, forKey: .baseURL), modelID: try c.decode(String.self, forKey: .modelID),
            capabilities: try c.decodeIfPresent(EvaluationJudgeCapabilities.self, forKey: .capabilities) ?? .init(),
            requestTimeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds) ?? 60,
            providerOrder: try c.decodeIfPresent([String].self, forKey: .providerOrder) ?? [],
            inputUSDPerMillionTokens: try c.decodeIfPresent(Double.self, forKey: .inputUSDPerMillionTokens),
            outputUSDPerMillionTokens: try c.decodeIfPresent(Double.self, forKey: .outputUSDPerMillionTokens),
            lastCheckedAt: try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt),
            lastCheckMessage: try c.decodeIfPresent(String.self, forKey: .lastCheckMessage),
            generationPolicy: try c.decodeIfPresent(EvaluationJudgeGenerationPolicy.self, forKey: .generationPolicy))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelID, capabilities, requestTimeoutSeconds, providerOrder
        case inputUSDPerMillionTokens, outputUSDPerMillionTokens, lastCheckedAt, lastCheckMessage, generationPolicy
    }

    var requiresAPIKey: Bool { kind != .localCompatible }
    var disclosureDigest: String {
        let fields = [kind.rawValue, baseURL, modelID, providerOrder.joined(separator: "\u{1f}"),
            capabilities.structuredOutputs ? "structured" : "unstructured",
            capabilities.multimodal ? "multimodal" : "text", generationPolicy.rawValue]
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var validationIssue: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Name the judge connection." }
        guard !trimmedModel.isEmpty else { return "Enter the exact judge model ID." }
        guard let components = URLComponents(string: baseURL), let url = components.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return "Enter an absolute HTTP or HTTPS base URL." }
        guard components.user == nil, components.password == nil else {
            return "Judge base URLs cannot contain credentials. Store API keys in Keychain instead."
        }
        guard components.query == nil else { return "Judge base URLs cannot contain a query." }
        guard components.fragment == nil else { return "Judge base URLs cannot contain a fragment." }
        switch kind {
        case .localCompatible:
            guard host == "127.0.0.1" || host == "::1" else { return "Local compatible connections must use a literal loopback host." }
        case .openRouter:
            guard scheme == "https" else { return "OpenRouter connections must use HTTPS." }
        case .customCompatible:
            guard scheme == "https" else { return "Custom compatible connections must use HTTPS." }
        }
        guard (Self.minimumRequestTimeoutSeconds...Self.maximumRequestTimeoutSeconds).contains(requestTimeoutSeconds) else {
            return "Judge timeout must be between \(Int(Self.minimumRequestTimeoutSeconds)) and \(Int(Self.maximumRequestTimeoutSeconds)) seconds."
        }
        if kind == .openRouter, providerOrder.isEmpty {
            return "Choose at least one explicit OpenRouter provider so judge routing cannot silently fall back."
        }
        guard Set(providerOrder).count == providerOrder.count,
              providerOrder.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "Provider routing entries must be non-empty and unique."
        }
        return nil
    }
}

struct EvaluationJudgeIdentity: Codable, Equatable, Sendable {
    var mode: EvaluationJudgeMode
    var connectionID: UUID?
    var connectionName: String
    var endpointKind: EvaluationJudgeConnectionKind?
    var baseURL: String?
    var requestedModelID: String
    var reportedModelID: String?
    var provider: String?
    var providerOrder: [String]
    var displayName: String {
        let actual = reportedModelID ?? requestedModelID
        return "\(connectionName) · \(actual)"
    }
}

enum EvaluationCostAvailability: String, Codable, Sendable { case known, estimated, unavailable }
struct EvaluationCost: Codable, Sendable {
    var availability: EvaluationCostAvailability
    var usd: Double?
    var explanation: String
}

enum EvaluationAssessmentOrigin: String, Codable, Sendable { case initialRun, reassessment, judgeCheck }
struct EvaluationSampleAssessment: Identifiable, Codable, Sendable {
    var id: UUID
    var sampleID: UUID
    var status: EvaluationResultStatus
    var score: Int?
    var rationale: String?
    var trace: EvaluationJudgeTrace?
    var errorCategory: String?
    var errorMessage: String?
    var usage: EvaluationUsage?
    var durationMilliseconds: Double?
}

struct EvaluationAssessment: Identifiable, Codable, Sendable {
    var id: UUID
    var runID: UUID
    var createdAt: Date
    var origin: EvaluationAssessmentOrigin
    var judge: EvaluationJudgeIdentity
    var promptVersion: String
    var rubric: String
    var passingScore: Int
    var samples: [EvaluationSampleAssessment]
    var totalUsage: EvaluationUsage?
    /// Sum of per-sample judge request durations, excluding orchestration time.
    var durationMilliseconds: Double
    var cost: EvaluationCost
    var supersedesAssessmentID: UUID?
    var observedJudgeIdentities: [EvaluationJudgeIdentity]? = nil
    var scoringContract: EvaluationScoringContract? = nil
    var subjectEvidenceDigest: String? = nil
    var errorCount: Int { samples.count { $0.errorCategory != nil || $0.errorMessage != nil } }
    static func summedJudgeDurationMilliseconds(_ samples: [EvaluationSampleAssessment]) -> Double {
        samples.compactMap(\.durationMilliseconds).filter { $0.isFinite && $0 >= 0 }
            .reduce(0) { total, duration in
                let sum = total + duration
                return sum.isFinite ? sum : .greatestFiniteMagnitude
            }
    }
}

struct EvaluationHumanCorrection: Identifiable, Codable, Sendable {
    var id: UUID
    var runID: UUID
    var assessmentID: UUID
    var sampleID: UUID
    var originalStatus: EvaluationResultStatus
    var originalScore: Int?
    var correctedStatus: EvaluationResultStatus
    var correctedScore: Int?
    var reason: String
    var reviewer: String?
    var createdAt: Date
}

struct EvaluationReviewedJudgeExample: Identifiable, Codable, Sendable {
    var id: UUID
    var sourceRunID: UUID
    var sourceAssessmentID: UUID
    var sampleID: UUID
    var expectedStatus: EvaluationResultStatus
    var reason: String
    var createdAt: Date
    var scoringContract: EvaluationScoringContract? = nil
    var subjectEvidenceDigest: String? = nil
}

struct EvaluationBaselineApproval: Identifiable, Codable, Sendable {
    var id: UUID
    var runID: UUID
    var assessmentID: UUID?
    var suiteRevision: String
    var approvedAt: Date
    var note: String?
    var revokedAt: Date?
    var scoringContract: EvaluationScoringContract? = nil
    var isCurrent: Bool { revokedAt == nil }
}

/// Subject instructions and model settings are excluded so prompt/model changes
/// can be measured against an older compatible baseline.
struct EvaluationScoringContract: Codable, Equatable, Sendable {
    var scoringMode: ScoringMode
    var rubricCriteria: [String]
    var judgePromptVersion: String?
    var judgePassingScore: Int?
    var casesDigest: String
    init(scoringMode: ScoringMode, rubricCriteria: [String], judgePromptVersion: String?,
         judgePassingScore: Int?, cases: [EvaluationCase]) throws {
        self.scoringMode = scoringMode
        self.rubricCriteria = rubricCriteria
        self.judgePromptVersion = judgePromptVersion
        self.judgePassingScore = judgePassingScore
        let normalizedCases = cases.map(EvaluationScoringCaseProjection.init(case:)).sorted { $0.id.uuidString < $1.id.uuidString }
        let data = try CanonicalJSON.data(for: normalizedCases, prettyPrinted: false)
        casesDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    init(suite: EvaluationSuite) throws {
        try self.init(scoringMode: suite.scoringMode,
            rubricCriteria: suite.scoringMode == .modelJudge ? suite.rubricCriteria : [],
            judgePromptVersion: suite.scoringMode == .modelJudge ? EvaluationRunner.judgePromptVersion : nil,
            judgePassingScore: suite.scoringMode == .modelJudge ? EvaluationSuite.judgePassingScore : nil, cases: suite.cases)
    }
    init(run: EvaluationRun) throws {
        try self.init(scoringMode: run.scoringMode,
            rubricCriteria: run.scoringMode == .modelJudge
                ? run.criteria.split(whereSeparator: \Character.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : [],
            judgePromptVersion: run.scoringMode == .modelJudge ? run.judgePromptVersion : nil,
            judgePassingScore: run.scoringMode == .modelJudge ? (run.judgePassingScore ?? EvaluationSuite.judgePassingScore) : nil,
            cases: run.plannedCases ?? run.suiteDefinition?.cases ?? [])
    }
}

private struct EvaluationScoringCaseProjection: Codable {
    var id: UUID
    var prompt: String
    var expected: String
    var conversation: EvaluationScoringConversationProjection
    var fieldAssertions: [EvaluationScoringAssertionProjection]
    init(case evaluationCase: EvaluationCase) {
        id = evaluationCase.id
        prompt = evaluationCase.prompt
        expected = evaluationCase.expected
        conversation = .init(configuration: evaluationCase.conversation)
        fieldAssertions = (evaluationCase.fieldAssertions ?? []).map(EvaluationScoringAssertionProjection.init(assertion:))
    }
}

private struct EvaluationScoringConversationProjection: Codable {
    var setupPrompts: [String]
    var restoredTranscriptJSON: String?
    var historyPolicy: EvaluationHistoryPolicy
    var retainedTurnCount: Int?
    var modelHistoryProjection: EvaluationModelHistoryProjection
    init(configuration: EvaluationConversationConfiguration) {
        setupPrompts = configuration.setupTurns.map(\.prompt)
        restoredTranscriptJSON = configuration.restoredTranscriptJSON
        historyPolicy = configuration.historyPolicy
        retainedTurnCount = configuration.historyPolicy == .retainRecentCompleteTurns ? configuration.retainedTurnCount : nil
        modelHistoryProjection = configuration.modelHistoryProjection ?? .init()
    }
}

private struct EvaluationScoringAssertionProjection: Codable {
    var pointer: String
    var operation: EvaluationFieldAssertionOperation
    var expectedValue: String?
    init(assertion: EvaluationFieldAssertion) {
        pointer = assertion.pointer
        operation = assertion.operation
        expectedValue = assertion.operation == .exists ? nil : assertion.expectedValue
    }
}

struct EvaluationSubjectAttachmentSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: EvaluationAttachmentKind
    var byteCount: Int
    var sha256: String
    var storedFilename: String?
    var text: String?
}

/// Immutable subject-side context retained for reassessment and calibration.
/// Image bytes live in the run-owned evidence directory named by the run ID.
struct EvaluationSubjectEvidenceSnapshot: Codable, Equatable, Sendable {
    var instructions: String
    var cases: [EvaluationCase]
    var attachments: [EvaluationSubjectAttachmentSnapshot]
    var digest: String
    static func digest(instructions: String, cases: [EvaluationCase], attachments: [EvaluationSubjectAttachmentSnapshot]) throws -> String {
        struct Payload: Codable {
            var instructions: String
            var cases: [EvaluationCase]
            var attachments: [EvaluationSubjectAttachmentSnapshot]
        }
        let data = try CanonicalJSON.data(for: Payload(instructions: instructions, cases: cases, attachments: attachments), prettyPrinted: false)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var hasValidDigest: Bool {
        (try? Self.digest(instructions: instructions, cases: cases, attachments: attachments)) == digest
    }
}

struct EvaluationSuiteLocalState: Codable, Sendable {
    var baselineApprovals: [EvaluationBaselineApproval] = []
    var humanCorrections: [EvaluationHumanCorrection] = []
    var reviewedJudgeExamples: [EvaluationReviewedJudgeExample] = []
    var experiments: [EvaluationExperiment] = []
}

// MARK: - Repository and experiment evidence
struct EvaluationRepositorySnapshot: Codable, Sendable {
    var rootPath: String
    var commit: String?
    var isDirty: Bool?
    var capturedAt: Date
    var error: String?
    var identitySummary: String {
        guard let commit else { return error ?? "Repository identity unavailable" }
        if isDirty == true { return "\(commit) with uncommitted changes" }
        if isDirty == false { return commit }
        return "\(commit); working-tree state unavailable"
    }
}

enum EvaluationExperimentDecision: String, Codable, CaseIterable, Sendable {
    case keepCurrent, adoptCandidate, collectMoreEvidence, inconclusive
}
struct EvaluationExperimentVariant: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var suiteRevision: String? = nil
}
struct EvaluationExperiment: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var suiteRevision: String
    var casesDigest: String
    var scoringDigest: String
    var judgeDigest: String
    var current: EvaluationExperimentVariant
    var candidate: EvaluationExperimentVariant
    var executionOrder: [UUID]
    var runIDs: [UUID]
    var decision: EvaluationExperimentDecision?
}
struct EvaluationExperimentSummary: Sendable {
    var improvedCaseIDs: [UUID]
    var regressedCaseIDs: [UUID]
    var unchangedCaseIDs: [UUID]
    var currentMedianLatencyMilliseconds: Double?
    var candidateMedianLatencyMilliseconds: Double?
    var distinctCaseCoverage: Int
    var repetitionsPerCase: Int
    var confidenceInterval: ClosedRange<Double>?
    var suggestedDecision: EvaluationExperimentDecision
    var explanation: String
}

// MARK: - Release checks
struct EvaluationReleasePolicy: Codable, Equatable, Sendable {
    var required = false
    var criticalCaseIDs: [UUID] = []
    var maximumErrorCount = 0
    var maximumAverageLatencyMilliseconds: Double?
    var requireApprovedBaseline = false
    var maximumPassRateRegression = 0.0
}
enum EvaluationReleaseCheckExit: Int32, Codable, Sendable {
    case passed = 0
    case regression = 10
    case incompleteOrIncompatibleEvidence = 20
    case executionError = 30
}
struct EvaluationReleaseCheckReport: Codable, Sendable {
    var formatVersion = 1
    var projectID: UUID
    var suiteID: UUID
    var runID: UUID?
    var assessmentID: UUID?
    var outcome: EvaluationReleaseCheckExit
    var summary: String
    var failures: [String]
    var generatedAt: Date
}
struct EvaluationProjectReleaseSuiteReport: Codable, Sendable {
    var suiteID: UUID
    var suiteName: String
    var required: Bool
    var report: EvaluationReleaseCheckReport
}
struct EvaluationProjectReleaseCheckReport: Codable, Sendable {
    var formatVersion = 1
    var projectID: UUID
    var outcome: EvaluationReleaseCheckExit
    var summary: String
    var suites: [EvaluationProjectReleaseSuiteReport]
    var generatedAt: Date
    var scenarios: [ScenarioReleaseCheckReport]? = nil
}
