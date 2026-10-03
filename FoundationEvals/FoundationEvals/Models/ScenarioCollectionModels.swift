import CryptoKit
import Foundation

struct ScenarioCaseLineage: Codable, Equatable, Sendable {
    var sourceCaseID: UUID
    var sourceVersion: Int
    var approvedDraftID: UUID
    var reviewedRequestText: String
    var outcomeReview: ScenarioVariationOutcomeReview
}

enum ScenarioVariationOutcomeReview: String, Codable, Sendable {
    case sameOutcome
    case differentOutcomeReviewed
}

struct ScenarioCollectionMember: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { caseID }
    var caseID: UUID
    var version: Int
    var definitionDigest: String
    var testContractDigest: String
    var lineage: ScenarioCaseLineage? = nil

    init(definition: ScenarioDefinition, lineage: ScenarioCaseLineage? = nil) throws {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest, let contract = definition.testContractDigest else {
            throw ScenarioCollectionError.invalidDefinition(definition.id)
        }
        caseID = definition.id
        version = definition.version
        definitionDigest = definition.definitionDigest
        testContractDigest = contract
        self.lineage = lineage
    }
}

/// A version names an ordered population of immutable case revisions.
struct ScenarioCollection: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var version: Int
    var projectID: UUID
    var name: String
    var members: [ScenarioCollectionMember]
    var membershipDigest: String
    var previousMembershipDigest: String?

    init(id: UUID = UUID(), version: Int = 1, projectID: UUID, name: String,
         members: [ScenarioCollectionMember], previousMembershipDigest: String? = nil) throws {
        self.id = id
        self.version = version
        self.projectID = projectID
        self.name = name
        self.members = members
        membershipDigest = try Self.digest(members)
        self.previousMembershipDigest = previousMembershipDigest
        try validate()
    }

    func validate() throws {
        guard version > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !members.isEmpty, Set(members.map(\.caseID)).count == members.count,
              (version == 1) == (previousMembershipDigest == nil),
              members.allSatisfy({ $0.version > 0 && !$0.definitionDigest.isEmpty && !$0.testContractDigest.isEmpty }),
              membershipDigest == (try Self.digest(members)) else {
            throw ScenarioCollectionError.invalidCollection
        }
    }

    func revised(members: [ScenarioCollectionMember]) throws -> Self {
        try .init(id: id, version: version + 1, projectID: projectID, name: name,
                  members: members, previousMembershipDigest: membershipDigest)
    }

    private static func digest(_ members: [ScenarioCollectionMember]) throws -> String {
        try ScenarioCollectionDigest.hash(members)
    }
}

/// Proposed wording is never itself a case. The caller must present and save a
/// reviewed, frozen definition before adding it to a collection.
struct ScenarioVariationDraft: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sourceCaseID: UUID
    var sourceVersion: Int
    var requestText: String
    var parameters: [ScenarioParameter]
    var featureInputs: [ScenarioFeatureInputMapping]
    var outcomeReview: ScenarioVariationOutcomeReview
    var unsupportedReason: String? = nil
}

struct ScenarioApprovedVariation: Sendable {
    var draft: ScenarioVariationDraft
    var reviewedDefinition: ScenarioDefinition
}

enum ScenarioCollectionScope: String, Codable, Sendable {
    case full
    case selected
    case rerunFailed
}

struct ScenarioBatchCase: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { member.caseID }
    var member: ScenarioCollectionMember
    var executionPlanID: UUID
    var fixtureContractDigest: String
    var targetBundleIdentifier: String
    var featureID: String?
    var expectedSubjectInputDigest: String?
}

struct ScenarioCollectionBatchManifest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var collectionID: UUID
    var collectionVersion: Int
    var membershipDigest: String
    var appProductDigest: String
    var scope: ScenarioCollectionScope
    var priorBatchID: UUID?
    var cases: [ScenarioBatchCase]
    var coordinates: [ScenarioPlannedCoordinate]
    var createdAt: Date
    var manifestDigest: String
    /// Nil only for historical manifests, which used the connected runner.
    var featureBackend: ScenarioFeatureBackend? = nil

    var selectedFeatureBackend: ScenarioFeatureBackend { featureBackend ?? .connectedRunner }

    var isFullPopulation: Bool { scope == .full }

    func calculatedDigest() throws -> String {
        var copy = self
        copy.manifestDigest = ""
        return try ScenarioCollectionDigest.hash(copy)
    }

    var hasValidDigest: Bool { (try? calculatedDigest()) == manifestDigest }
}

struct ScenarioCollectionBatchResult: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var manifestID: UUID
    /// A missing case execution remains visible from the frozen manifest.
    /// Every present child is the same immutable record used by single-case runs.
    var executions: [ScenarioExecutionRecord]
    var recordedAt: Date
}

enum ScenarioBatchQualification: String, Codable, Sendable {
    case passedFull
    case failedFull
    case incomplete
    case partial
    case incompatible
}

struct ScenarioBatchCoordinateAssessment: Equatable, Identifiable, Sendable {
    var id: UUID { coordinate.id }
    var coordinate: ScenarioPlannedCoordinate
    var terminalState: ScenarioCoordinateTerminalState
    var outcome: ScenarioOutcome?
    var reason: String?
}

struct ScenarioCollectionBatchAssessment: Equatable, Sendable {
    var qualification: ScenarioBatchQualification
    var coordinates: [ScenarioBatchCoordinateAssessment]
    var passedCount: Int
    var plannedCount: Int
    var reasons: [String]
}

enum ScenarioCollectionMembershipChange: String, Codable, Sendable {
    case unchanged
    case changed
    case added
    case removed
}

struct ScenarioCollectionMembershipDifference: Equatable, Identifiable, Sendable {
    var id: UUID { caseID }
    var caseID: UUID
    var baseline: ScenarioCollectionMember?
    var candidate: ScenarioCollectionMember?
    var change: ScenarioCollectionMembershipChange
}

enum ScenarioCollectionError: Error, Equatable {
    case invalidDefinition(UUID)
    case invalidCollection
    case invalidVariation(UUID)
    case unsupportedVariation(UUID, String)
    case changedOutcomeNeedsReview(UUID)
    case invalidSelection
    case invalidManifest
    case conflictingSavedObject
    case invalidSavedObject
}

enum ScenarioCollectionDigest {
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
