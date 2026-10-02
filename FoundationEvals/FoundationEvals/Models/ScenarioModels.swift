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

struct ScenarioIntegrationIdentity: Codable, Equatable, Sendable {
    var id: String
    var version: String
    /// SHA-256 of the exact developer-owned declaration file bytes, not a package version.
    var digest: String
}

/// A v3 check binds a logical feature interface. A feature run belongs to
/// ScenarioRun, so a fresh execution cannot silently rewrite requirements.
struct ScenarioFeatureBinding: Codable, Equatable, Sendable {
    var featureID: String
    var interfaceDigest: String
    var inputMapping: [ScenarioFeatureInputMapping]
    var outputProjections: [ScenarioOutputField]
}

struct ScenarioFeatureInputMapping: Codable, Equatable, Sendable {
    var featureInputName: String
    var value: ScenarioValue
}

/// Exact observer/evaluator code identity, independent of a test bundle's hash.
struct ScenarioMeasurementImplementation: Codable, Equatable, Sendable {
    var observerID: String
    var observerDigest: String
    var evaluatorID: String
    var evaluatorDigest: String

    var hasCompleteProvenance: Bool {
        [observerID, observerDigest, evaluatorID, evaluatorDigest].allSatisfy {
            !$0.isEmpty && $0.lowercased() != "unknown"
        }
    }
}

struct ScenarioEnvironmentIdentity: Codable, Equatable, Sendable {
    var profileID: String
    var profileDigest: String

    var hasCompleteProvenance: Bool {
        [profileID, profileDigest].allSatisfy { !$0.isEmpty && $0.lowercased() != "unknown" }
    }
}

/// Local execution resolution. A changed checkout or destination is recorded
/// here and in each execution, never in the stable v3 test contract.
struct ScenarioExecutionProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var projectPath: String
    var scheme: String
    var testTarget: String
    var destinationIdentifier: String
    var signingSelection: String?
    var trustedConnectionID: UUID?
    var buildConfiguration: String?
}

struct ScenarioSubjectImplementation: Codable, Equatable, Sendable {
    var sourceRevision: String?
    var promptDigest: String?
    var modelRevision: String?
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
    private(set) var persistedInstant: Date? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier && lhs.resolvedInstant == rhs.resolvedInstant
    }
    enum CodingKeys: String, CodingKey { case source, timeZoneIdentifier, resolvedInstant, resolvedInstantBits }
    init(source: String, timeZoneIdentifier: String, resolvedInstant: Date) {
        self.source = source; self.timeZoneIdentifier = timeZoneIdentifier; self.resolvedInstant = resolvedInstant
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        resolvedInstant = try values.decode(Date.self, forKey: .resolvedInstant)
        persistedInstant = resolvedInstant
        if let text = try values.decodeIfPresent(String.self, forKey: .resolvedInstantBits) {
            guard let bits = UInt64(text, radix: 16), Double(bitPattern: bits).isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .resolvedInstantBits, in: values, debugDescription: "Invalid exact date instant.")
            }
            resolvedInstant = Date(timeIntervalSince1970: Double(bitPattern: bits))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try values.encode(resolvedInstant, forKey: .resolvedInstant)
        if encoder.userInfo[.omitPreciseScenarioDates] as? Bool != true {
            try values.encode(String(resolvedInstant.timeIntervalSince1970.bitPattern, radix: 16), forKey: .resolvedInstantBits)
        }
    }
}

private extension CodingUserInfoKey {
    static let omitPreciseScenarioDates = CodingUserInfoKey(rawValue: "omitPreciseScenarioDates")!
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

    var hasBoundLegacyDatePrecision: Bool {
        switch self {
        case .date(let date): return date.persistedInstant == nil || date.persistedInstant == date.resolvedInstant
        case .array(let values): return values.allSatisfy(\.hasBoundLegacyDatePrecision)
        default: return true
        }
    }

    /// Legacy digests bind ISO8601 seconds. Freeze values at that precision so
    /// exact-date metadata cannot invalidate an otherwise unchanged saved test.
    var withLegacyDatePrecision: Self {
        switch self {
        case .date(let date):
            return .date(.init(
                source: date.source,
                timeZoneIdentifier: date.timeZoneIdentifier,
                resolvedInstant: Date(timeIntervalSince1970:
                    date.resolvedInstant.timeIntervalSince1970.rounded(.down))
            ))
        case .array(let values):
            return .array(values.map(\.withLegacyDatePrecision))
        default:
            return self
        }
    }
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
    var displayName: String? = nil
    var path: [ScenarioProjectionPathComponent]? = nil
}

enum ScenarioProjectionPathKind: String, Codable, Sendable {
    case property
    case index
    case count
}

struct ScenarioProjectionPathComponent: Codable, Equatable, Sendable {
    var kind: ScenarioProjectionPathKind
    var name: String? = nil
    var index: Int? = nil
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

enum ScenarioPurpose: String, Codable, CaseIterable, Sendable {
    case exploratory
    case releaseRequirement
}

enum ScenarioCheckMode: String, Codable, CaseIterable, Sendable {
    case basic
    case behaviour
}

enum ScenarioProofClaim: String, Codable, CaseIterable, Sendable {
    case executionCompleted
    case returnedValueChecked
    case applicationStateChecked
}

enum ScenarioPlannedObservationSource: String, Codable, CaseIterable, Sendable {
    case intentResult
    case entityQuery
    case valueQuery
    case uiElement
    case testOnlyIntent

    var checksApplicationState: Bool { self != .intentResult }
}

struct ScenarioPlannedObservation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: ScenarioPlannedObservationSource
    /// A compiled, allowlisted operation in the consumer integration, when applicable.
    var operationID: String?
    /// A declared stable ID or UI selector, never an expression to evaluate.
    var selector: String?
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
    static let reusableSchemaVersion = 2
    static let stableSchemaVersion = 3

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
    /// v2 fields stay absent in v1 JSON so its canonical digest is unchanged.
    var purpose: ScenarioPurpose? = nil
    var checkMode: ScenarioCheckMode? = nil
    var requiredClaims: [ScenarioProofClaim]? = nil
    var observationPlan: [ScenarioPlannedObservation]? = nil
    var integration: ScenarioIntegrationIdentity? = nil
    /// v3 only. Unlike definitionDigest, this excludes authoring and execution identity.
    var testContractDigest: String? = nil
    var featureBinding: ScenarioFeatureBinding? = nil

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
        caseSet: ScenarioCaseSet? = .regression,
        purpose: ScenarioPurpose? = nil,
        checkMode: ScenarioCheckMode? = nil,
        requiredClaims: [ScenarioProofClaim]? = nil,
        observationPlan: [ScenarioPlannedObservation]? = nil,
        integration: ScenarioIntegrationIdentity? = nil
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
        self.purpose = purpose
        self.checkMode = checkMode
        self.requiredClaims = requiredClaims
        self.observationPlan = observationPlan
        self.integration = integration
    }

    /// Opt-in constructor for new integrations. The caller still supplies the
    /// target, action, safety policy, and any observations before freezing.
    static func reusable(
        name: String,
        target: ScenarioTarget,
        goal: ScenarioUserGoal,
        fixture: ScenarioFixture,
        directControl: ScenarioDirectControl,
        assertions: [ScenarioAssertion],
        coverage: ScenarioCoverage,
        safety: ScenarioSafety,
        purpose: ScenarioPurpose,
        checkMode: ScenarioCheckMode,
        requiredClaims: [ScenarioProofClaim],
        observationPlan: [ScenarioPlannedObservation],
        integration: ScenarioIntegrationIdentity
    ) -> Self {
        .init(
            schemaVersion: reusableSchemaVersion,
            name: name,
            target: target,
            goal: goal,
            fixture: fixture,
            directControl: directControl,
            assertions: assertions,
            coverage: coverage,
            safety: safety,
            purpose: purpose,
            checkMode: checkMode,
            requiredClaims: requiredClaims,
            observationPlan: observationPlan,
            integration: integration
        )
    }

    func calculatedDigest() throws -> String {
        var copy = self
        copy.definitionDigest = ""
        if schemaVersion == Self.stableSchemaVersion {
            return try ScenarioV3Canonical.digest(copy)
        }
        let encoder = JSONEncoder()
        encoder.userInfo[.omitPreciseScenarioDates] = true
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(copy)
        if schemaVersion == Self.reusableSchemaVersion {
            // JSON object-key sorting does not order Set-backed lane arrays.
            // Canonicalise only v2; historical v1 digests retain their original bytes.
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EncodingError.invalidValue(copy, .init(
                    codingPath: [], debugDescription: "A scenario must encode as a JSON object."
                ))
            }
            if var assertions = object["assertions"] as? [[String: Any]] {
                for index in assertions.indices {
                    if let lanes = assertions[index]["applicableLanes"] as? [String] {
                        assertions[index]["applicableLanes"] = lanes.sorted()
                    }
                }
                object["assertions"] = assertions
            }
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func frozen() throws -> Self {
        var copy = self
        if schemaVersion == Self.currentSchemaVersion || schemaVersion == Self.reusableSchemaVersion {
            for index in copy.directControl.parameters.indices {
                if case .value(let value) = copy.directControl.parameters[index].presence {
                    copy.directControl.parameters[index].presence = .value(value.withLegacyDatePrecision)
                }
            }
            for index in copy.assertions.indices {
                copy.assertions[index].expectedValue = copy.assertions[index].expectedValue?.withLegacyDatePrecision
            }
        }
        if schemaVersion == Self.stableSchemaVersion {
            guard directControl.linkedFeatureRunID == nil && directControl.linkedFeatureSubjectDigest.isEmpty else {
                throw ScenarioV3ContractError.executionBoundDefinition
            }
            copy.testContractDigest = try copy.calculatedTestContractDigest()
        }
        copy.definitionDigest = try copy.calculatedDigest()
        return copy
    }

    var hasValidDigest: Bool {
        guard !definitionDigest.isEmpty else { return false }
        guard (try? calculatedDigest()) == definitionDigest else { return false }
        if schemaVersion == Self.stableSchemaVersion {
            return (try? calculatedTestContractDigest()) == testContractDigest
        }
        // Legacy digests bind ISO8601 seconds, not exact-date metadata. Never
        // accept metadata that changes the value covered by a legacy digest.
        return directControl.parameters.allSatisfy { parameter in
            if case .value(let value) = parameter.presence { return value.hasBoundLegacyDatePrecision }
            return true
        } && assertions.allSatisfy { $0.expectedValue?.hasBoundLegacyDatePrecision != false }
    }
}

extension ScenarioDefinition {
    static func latestVersions(in definitions: [Self]) -> [Self] {
        Dictionary(grouping: definitions, by: \.id).values
            .compactMap { $0.max(by: { $0.version < $1.version }) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

extension ScenarioDefinition {
    /// v3's stable measurement contract. Authoring names/paths and linked run
    /// identifiers are intentionally absent; request text and fixture bytes are not.
    func calculatedTestContractDigest() throws -> String {
        guard schemaVersion == Self.stableSchemaVersion else {
            throw ScenarioV3ContractError.unsupportedSchemaVersion(schemaVersion)
        }
        return try ScenarioV3Canonical.digest(ScenarioV3Contract(definition: self))
    }
}

enum ScenarioV3ContractError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case executionBoundDefinition
}

private struct ScenarioV3Contract: Encodable {
    struct Target: Encodable {
        var bundleIdentifier: String
        var route: ScenarioInvocationRoute
    }
    struct Action: Encodable {
        var intentIdentifier: String
        var parameters: [ScenarioParameter]
        var outputFields: [OutputField]
    }
    struct OutputField: Encodable {
        var name: String
        var type: ScenarioValueType
        var path: [ScenarioProjectionPathComponent]?
        init(_ field: ScenarioOutputField) {
            name = field.name
            type = field.type
            path = field.path
        }
    }
    struct Binding: Encodable {
        var featureID: String
        var interfaceDigest: String
        var inputMapping: [ScenarioFeatureInputMapping]
        var outputProjections: [OutputField]
        init?(_ binding: ScenarioFeatureBinding?) {
            guard let binding else { return nil }
            featureID = binding.featureID
            interfaceDigest = binding.interfaceDigest
            inputMapping = binding.inputMapping
            outputProjections = binding.outputProjections.map(OutputField.init)
        }
    }
    struct Assertion: Encodable {
        var kind: ScenarioAssertionKind
        var observationKey: String
        var expectedValue: ScenarioValue?
        var explanation: String
        var required: Bool
        var applicableLanes: [ScenarioLane]?
        init(_ assertion: ScenarioAssertion) {
            kind = assertion.kind
            observationKey = assertion.observationKey
            expectedValue = assertion.expectedValue
            explanation = assertion.explanation
            required = assertion.required
            applicableLanes = assertion.applicableLanes?.sorted { $0.rawValue < $1.rawValue }
        }
    }
    var target: Target
    var goal: ScenarioUserGoal
    var fixture: ScenarioFixture
    var action: Action
    var featureBinding: Binding?
    var assertions: [Assertion]
    var coverage: ScenarioCoverage
    var safety: ScenarioSafety
    var purpose: ScenarioPurpose?
    var checkMode: ScenarioCheckMode?
    var requiredClaims: [ScenarioProofClaim]?
    var observationPlan: [ScenarioPlannedObservation]?
    var integration: ScenarioIntegrationIdentity?

    init(definition: ScenarioDefinition) {
        target = .init(bundleIdentifier: definition.target.bundleIdentifier, route: definition.target.route)
        goal = definition.goal
        fixture = definition.fixture
        action = .init(intentIdentifier: definition.directControl.intentIdentifier,
                       parameters: definition.directControl.parameters,
                       outputFields: definition.directControl.outputFields.map(OutputField.init))
        featureBinding = Binding(definition.featureBinding)
        assertions = definition.assertions.map(Assertion.init)
        coverage = definition.coverage
        safety = definition.safety
        purpose = definition.purpose
        checkMode = definition.checkMode
        requiredClaims = definition.requiredClaims
        observationPlan = definition.observationPlan
        integration = definition.integration
    }
}

private enum ScenarioV3Canonical {
    /// Sorted UTF-8 JSON object keys, original string bytes and ordered arrays.
    /// Codable enum cases tag value types and parameter presence. Date instants
    /// use the exact binary64 seconds bit pattern, avoiding formatter rounding.
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.userInfo[.omitPreciseScenarioDates] = true
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode("binary64:" + String(date.timeIntervalSince1970.bitPattern, radix: 16))
        }
        var data = try encoder.encode(value)
        if value is ScenarioDefinition {
            // Existing Set-backed assertion lanes have no deterministic order.
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Expected object"))
            }
            if var assertions = object["assertions"] as? [[String: Any]] {
                for index in assertions.indices {
                    if let lanes = assertions[index]["applicableLanes"] as? [String] {
                        assertions[index]["applicableLanes"] = lanes.sorted()
                    }
                }
                object["assertions"] = assertions
            }
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    var claims: [ScenarioProofClaim]? = nil

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
        observationSources: [String: ScenarioObservationSource]? = nil,
        claims: [ScenarioProofClaim]? = nil
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
        self.claims = claims
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
    static let reusableHarnessVersion = "intent-lab-v2"

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
    var integration: ScenarioIntegrationIdentity? = nil
    var requiredCapabilities: [String]? = nil
}

enum ScenarioObservationSource: String, Codable, CaseIterable, Sendable {
    case appIntentsTesting
    case entityQuery
    case valueQuery
    case testOnlyIntent
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
    static let reusableSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var invocation: ScenarioInvocationIdentity
    var sourceBundleIdentifier: String
    var observedAppProduct: ScenarioProductIdentity
    var observedTestProduct: ScenarioProductIdentity
    var environment: ScenarioEnvironment
    var testCount: Int
    var results: [ScenarioLaneResult]
    var integration: ScenarioIntegrationIdentity? = nil
    var runnerPackageVersion: String? = nil
    var negotiatedCapabilities: [String]? = nil
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
    var integration: ScenarioIntegrationIdentity? = nil
    var runnerPackageVersion: String? = nil
    var negotiatedCapabilities: [String]? = nil
    /// v3 execution provenance; absent on immutable legacy evidence.
    var scenarioSchemaVersion: Int? = nil
    var testContractDigest: String? = nil
    var measurementImplementation: ScenarioMeasurementImplementation? = nil
    var comparisonEnvironmentIdentity: ScenarioEnvironmentIdentity? = nil
    var subjectImplementation: ScenarioSubjectImplementation? = nil
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
