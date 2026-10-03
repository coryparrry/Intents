import CryptoKit
import Foundation

enum ScenarioLane: String, Codable, CaseIterable, Identifiable, Sendable {
    case appFeature
    case intentIntegration
    case siri

    var id: Self { self }

    var title: String {
        switch self {
        case .appFeature: "App feature"
        case .intentIntegration: "Intent integration"
        case .siri: "Siri outcome"
        }
    }
}

enum ScenarioLaneRequirement: String, Codable, CaseIterable, Sendable {
    case required
    case optional
    case notApplicable
}

struct ScenarioCoverage: Codable, Equatable, Sendable {
    var appFeature: ScenarioLaneRequirement = .optional
    var intentIntegration: ScenarioLaneRequirement = .required
    var siri: ScenarioLaneRequirement = .required
    /// Read-only Siri scenarios retain three independently reset attempts. Mutation
    /// scenarios must stay at one until reset and recovery have been proven.
    var siriAttemptCount: Int? = 3

    subscript(_ lane: ScenarioLane) -> ScenarioLaneRequirement {
        switch lane {
        case .appFeature: appFeature
        case .intentIntegration: intentIntegration
        case .siri: siri
        }
    }
}

enum ScenarioInvocationRoute: String, Codable, CaseIterable, Sendable {
    case appIntentDefinition
    case appShortcut
}

struct ScenarioTarget: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var projectPath: String
    var scheme: String
    var testTarget: String
    var destinationIdentifier: String
    var route: ScenarioInvocationRoute
}

struct ScenarioUserGoal: Codable, Equatable, Sendable {
    var requestText: String
    var languageCode: String
    var expectedBehavior: String
    var approvedFollowUps: [String] = []
}

struct ScenarioFixture: Codable, Equatable, Sendable {
    var id: String
    var version: String
    var digest: String
    var isSynthetic: Bool
    var preparationOperation: String
    var cleanupOperation: String
}

enum ScenarioPrimitiveType: String, Codable, CaseIterable, Sendable {
    case string
    case boolean
    case integer
    case number
    case date
}

indirect enum ScenarioValueType: Codable, Equatable, Sendable {
    case primitive(ScenarioPrimitiveType)
    case enumeration(typeIdentifier: String, allowedCases: [String])
    case entity(typeIdentifier: String)
    case array(element: ScenarioValueType)
}

struct ScenarioDateValue: Codable, Equatable, Sendable {
    var source: String
    var timeZoneIdentifier: String
    var resolvedInstant: Date
}

struct ScenarioEnumValue: Codable, Equatable, Sendable {
    var typeIdentifier: String
    var caseIdentifier: String
}

struct ScenarioEntityReference: Codable, Equatable, Sendable {
    var typeIdentifier: String
    var identifier: String
}

indirect enum ScenarioValue: Codable, Equatable, Sendable {
    case null
    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case date(ScenarioDateValue)
    case enumeration(ScenarioEnumValue)
    case entity(ScenarioEntityReference)
    case array([ScenarioValue])
}

enum ScenarioParameterPresence: Codable, Equatable, Sendable {
    case missing
    case value(ScenarioValue)
}

struct ScenarioParameter: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var type: ScenarioValueType
    var isOptional: Bool
    var presence: ScenarioParameterPresence
}

struct ScenarioOutputField: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var type: ScenarioValueType
}

struct ScenarioDirectControl: Codable, Equatable, Sendable {
    var intentIdentifier: String
    var parameters: [ScenarioParameter]
    var outputFields: [ScenarioOutputField]
    var linkedFeatureRunID: UUID?
    var linkedFeatureID: String = ""
    /// Digest of the linked evaluation run's immutable subject evidence.
    var linkedFeatureSubjectDigest: String = ""

    init(
        intentIdentifier: String,
        parameters: [ScenarioParameter],
        outputFields: [ScenarioOutputField],
        linkedFeatureRunID: UUID?,
        linkedFeatureID: String = "",
        linkedFeatureSubjectDigest: String = ""
    ) {
        self.intentIdentifier = intentIdentifier
        self.parameters = parameters
        self.outputFields = outputFields
        self.linkedFeatureRunID = linkedFeatureRunID
        self.linkedFeatureID = linkedFeatureID
        self.linkedFeatureSubjectDigest = linkedFeatureSubjectDigest
    }

    private enum CodingKeys: String, CodingKey {
        case intentIdentifier, parameters, outputFields, linkedFeatureRunID
        case linkedFeatureID, linkedFeatureSubjectDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intentIdentifier = try container.decode(String.self, forKey: .intentIdentifier)
        parameters = try container.decode([ScenarioParameter].self, forKey: .parameters)
        outputFields = try container.decode([ScenarioOutputField].self, forKey: .outputFields)
        linkedFeatureRunID = try container.decodeIfPresent(UUID.self, forKey: .linkedFeatureRunID)
        linkedFeatureID = try container.decodeIfPresent(String.self, forKey: .linkedFeatureID) ?? ""
        linkedFeatureSubjectDigest = try container.decodeIfPresent(String.self, forKey: .linkedFeatureSubjectDigest) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intentIdentifier, forKey: .intentIdentifier)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(outputFields, forKey: .outputFields)
        try container.encodeIfPresent(linkedFeatureRunID, forKey: .linkedFeatureRunID)
        if !linkedFeatureID.isEmpty {
            try container.encode(linkedFeatureID, forKey: .linkedFeatureID)
        }
        if !linkedFeatureSubjectDigest.isEmpty {
            try container.encode(linkedFeatureSubjectDigest, forKey: .linkedFeatureSubjectDigest)
        }
    }
}

enum ScenarioAssertionKind: String, Codable, CaseIterable, Sendable {
    case entityIdentifier
    case returnedField
    case visibleText
    case stateTransition
    case noMutation
    case semanticRubric
}

enum ScenarioCaseSet: String, Codable, CaseIterable, Sendable {
    case regression
    case holdout
}

struct ScenarioAssertion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var kind: ScenarioAssertionKind
    var observationKey: String
    var expectedValue: ScenarioValue?
    var explanation: String
    var required: Bool
    /// Nil means the assertion applies to every evidence lane. Keeping this optional
    /// preserves scenarios saved before lane-specific assertions were introduced.
    var applicableLanes: Set<ScenarioLane>?

    init(
        id: UUID = UUID(),
        kind: ScenarioAssertionKind,
        observationKey: String,
        expectedValue: ScenarioValue? = nil,
        explanation: String,
        required: Bool = true,
        applicableLanes: Set<ScenarioLane>? = nil
    ) {
        self.id = id
        self.kind = kind
        self.observationKey = observationKey
        self.expectedValue = expectedValue
        self.explanation = explanation
        self.required = required
        self.applicableLanes = applicableLanes
    }

    func applies(to lane: ScenarioLane) -> Bool {
        applicableLanes?.contains(lane) ?? (lane != .appFeature)
    }
}

enum ScenarioMutationPolicy: String, Codable, CaseIterable, Sendable {
    case readOnly
    case syntheticMutation
}

struct ScenarioSafety: Codable, Equatable, Sendable {
    var mutationPolicy: ScenarioMutationPolicy
    var allowedActions: [String]
    var permittedConfirmationSteps: [String]
    var deadlineSeconds: Double
}

struct ScenarioDefinition: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var id: UUID
    var version: Int
    var projectID: UUID?
    var name: String
    var definitionDigest: String
    var target: ScenarioTarget
    var goal: ScenarioUserGoal
    var fixture: ScenarioFixture
    var directControl: ScenarioDirectControl
    var assertions: [ScenarioAssertion]
    var coverage: ScenarioCoverage
    var safety: ScenarioSafety
    var caseSet: ScenarioCaseSet? = .regression

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        version: Int = 1,
        projectID: UUID? = nil,
        name: String,
        definitionDigest: String = "",
        target: ScenarioTarget,
        goal: ScenarioUserGoal,
        fixture: ScenarioFixture,
        directControl: ScenarioDirectControl,
        assertions: [ScenarioAssertion],
        coverage: ScenarioCoverage = .init(),
        safety: ScenarioSafety,
        caseSet: ScenarioCaseSet? = .regression
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.projectID = projectID
        self.name = name
        self.definitionDigest = definitionDigest
        self.target = target
        self.goal = goal
        self.fixture = fixture
        self.directControl = directControl
        self.assertions = assertions
        self.coverage = coverage
        self.safety = safety
        self.caseSet = caseSet
    }

    func calculatedDigest() throws -> String {
        var copy = self
        copy.definitionDigest = ""
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(copy)).map { String(format: "%02x", $0) }.joined()
    }

    func frozen() throws -> Self {
        var copy = self
        copy.definitionDigest = try calculatedDigest()
        return copy
    }

    var hasValidDigest: Bool {
        guard !definitionDigest.isEmpty else { return false }
        return (try? calculatedDigest()) == definitionDigest
    }
}

extension ScenarioDefinition {
    static func latestVersions(in definitions: [Self]) -> [Self] {
        Dictionary(grouping: definitions, by: \.id).values
            .compactMap { $0.max(by: { $0.version < $1.version }) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum ScenarioExecutionStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case blockedByEnvironment
    case timedOut
    case cancelled
    case crashed
    case failedToBuild
    case invalidEvidence
}

enum ScenarioOutcome: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case needsReview
    case notObserved
    case notApplicable
}

struct ScenarioAssertionResult: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var assertionID: UUID
    var passed: Bool
    var observedValue: ScenarioValue?
    var message: String

    init(
        id: UUID = UUID(),
        assertionID: UUID,
        passed: Bool,
        observedValue: ScenarioValue? = nil,
        message: String
    ) {
        self.id = id
        self.assertionID = assertionID
        self.passed = passed
        self.observedValue = observedValue
        self.message = message
    }
}

enum ScenarioArtifactKind: String, Codable, CaseIterable, Sendable {
    case evidenceJSON
    case screenshot
    case buildLog
    case testLog
    case resultBundle
}

struct ScenarioArtifactReference: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: ScenarioArtifactKind
    var filename: String
    var relativePath: String
    var contentType: String
    var byteCount: Int
    var sha256: String
    var manuallySupplied: Bool

    init(
        id: UUID = UUID(),
        kind: ScenarioArtifactKind,
        filename: String,
        relativePath: String,
        contentType: String,
        byteCount: Int,
        sha256: String,
        manuallySupplied: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.relativePath = relativePath
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.manuallySupplied = manuallySupplied
    }
}

struct ScenarioLaneResult: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var caseID: UUID
    var attempt: Int
    var lane: ScenarioLane
    var executionStatus: ScenarioExecutionStatus
    var outcome: ScenarioOutcome
    var startedAt: Date
    var completedAt: Date
    var observations: [String: ScenarioValue]
    var assertionResults: [ScenarioAssertionResult]
    var diagnostic: String?
    var proposedCause: String?
    var artifacts: [ScenarioArtifactReference]
    var observationSources: [String: ScenarioObservationSource]? = nil

    init(
        id: UUID = UUID(),
        caseID: UUID,
        attempt: Int,
        lane: ScenarioLane,
        executionStatus: ScenarioExecutionStatus,
        outcome: ScenarioOutcome,
        startedAt: Date,
        completedAt: Date,
        observations: [String: ScenarioValue] = [:],
        assertionResults: [ScenarioAssertionResult] = [],
        diagnostic: String? = nil,
        proposedCause: String? = nil,
        artifacts: [ScenarioArtifactReference] = [],
        observationSources: [String: ScenarioObservationSource]? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.attempt = attempt
        self.lane = lane
        self.executionStatus = executionStatus
        self.outcome = outcome
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observations = observations
        self.assertionResults = assertionResults
        self.diagnostic = diagnostic
        self.proposedCause = proposedCause
        self.artifacts = artifacts
        self.observationSources = observationSources
    }
}

struct ScenarioProductIdentity: Codable, Equatable, Sendable {
    /// Provenance of the host-built bundle supplied to Xcode. This is not device attestation.
    var bundleIdentifier: String
    var executableName: String
    var sha256: String
}

struct ScenarioTestIdentity: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var className: String
    var methodName: String
}

struct ScenarioInvocationIdentity: Codable, Equatable, Identifiable, Sendable {
    static let currentHarnessVersion = "intent-lab-v1"

    var id: UUID
    var nonce: String
    var issuedAt: Date
    var testIdentity: ScenarioTestIdentity
    var harnessVersion: String
    var destinationIdentifier: String
    var scenarioDigest: String
    var resultBundleIdentity: String
    var appProduct: ScenarioProductIdentity?
    var testProduct: ScenarioProductIdentity?
}

enum ScenarioObservationSource: String, Codable, CaseIterable, Sendable {
    case appIntentsTesting
    case siriRecognizedText
    case applicationInstrumentation
    case accessibleUI
    case manuallySupplied
}

struct ScenarioEnvironment: Codable, Equatable, Sendable {
    var xcodeVersion: String
    var sdkVersion: String
    var deviceModel: String
    var operatingSystem: String
    var operatingSystemBuild: String?
    var languageCode: String
    var regionCode: String
    var timeZoneIdentifier: String
    var siriConfiguration: String?
    var siriConfigurationSource: ScenarioObservationSource?
    var executedAt: Date
}

struct ScenarioEvidenceEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var invocation: ScenarioInvocationIdentity
    var sourceBundleIdentifier: String
    var observedAppProduct: ScenarioProductIdentity
    var observedTestProduct: ScenarioProductIdentity
    var environment: ScenarioEnvironment
    var testCount: Int
    var results: [ScenarioLaneResult]
}

struct ScenarioRun: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var scenarioID: UUID
    var scenarioVersion: Int
    var scenarioDigest: String
    var invocation: ScenarioInvocationIdentity
    var startedAt: Date
    var completedAt: Date
    var environment: ScenarioEnvironment
    var executionStatus: ScenarioExecutionStatus
    var outcome: ScenarioOutcome
    var laneResults: [ScenarioLaneResult]
    var linkedFeatureRunID: UUID?
    var importedAt: Date
    /// Exit status of the host XCTest process. A nonzero exit cannot support a release pass.
    var xctestExitCode: Int32? = nil
    var fixture: ScenarioFixture? = nil
    var responseAssessments: [ScenarioResponseAssessment]? = nil
    /// Environment dimensions the developer explicitly expected to differ from
    /// the preceding run. This is run metadata, not part of the frozen scenario.
    var statedChangedDimensions: Set<String>? = nil
}

struct ScenarioResponseAssessment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var assertionID: UUID
    var lane: ScenarioLane
    var attempt: Int
    var passed: Bool
    var explanation: String
    var assessorIdentity: String
    var rubric: String
    var createdAt: Date = Date()
}

extension ScenarioDefinition {
    static func starter(projectID: UUID? = nil) -> Self {
        let entityAssertion = ScenarioAssertion(
            kind: .entityIdentifier,
            observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            explanation: "The requested packing note is the note the app selected."
        )
        let noMutation = ScenarioAssertion(
            kind: .noMutation,
            observationKey: "noteStoreMutationCount",
            expectedValue: .integer(0),
            explanation: "Opening the note must not modify the note store."
        )
        return ScenarioDefinition(
            projectID: projectID,
            name: "Open the packing note",
            target: .init(
                bundleIdentifier: "com.coryparry.IntentLabFixture",
                projectPath: "examples/IntentLabFixture/IntentLabFixture.xcodeproj",
                scheme: "IntentLabFixture",
                testTarget: "IntentLabFixtureUITests",
                destinationIdentifier: "",
                route: .appShortcut
            ),
            goal: .init(
                requestText: "Open the packing note in Intent Lab Fixture",
                languageCode: "en-GB",
                expectedBehavior: "Open note packing-001 and show its heading without changing the note store."
            ),
            fixture: .init(
                id: "packing-notes",
                version: "1",
                digest: "fixture-packing-notes-v1",
                isSynthetic: true,
                preparationOperation: "resetPackingNotes",
                cleanupOperation: "resetPackingNotes"
            ),
            directControl: .init(
                intentIdentifier: "OpenNoteIntent",
                parameters: [
                    .init(
                        name: "note",
                        type: .entity(typeIdentifier: "NoteEntity"),
                        isOptional: false,
                        presence: .value(.entity(.init(
                            typeIdentifier: "NoteEntity",
                            identifier: "packing-001"
                        )))
                    )
                ],
                outputFields: [
                    .init(name: "selectedNoteID", type: .primitive(.string))
                ],
                linkedFeatureRunID: nil
            ),
            assertions: [entityAssertion, noMutation],
            safety: .init(
                mutationPolicy: .readOnly,
                allowedActions: ["openNote"],
                permittedConfirmationSteps: [],
                deadlineSeconds: 60
            )
        )
    }
}
