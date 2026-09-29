import Foundation

/// Reads saved evidence without coordinator recovery or any history writes.
/// GUI qualification, export and MCP use this same durable snapshot builder.
struct ScenarioSavedExecutionReportService {
    let rootDirectory: URL
    private let persistence: ScenarioPersistence
    private let assessmentStore: ScenarioAssessmentStore

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        persistence = ScenarioPersistence(rootDirectory: rootDirectory)
        assessmentStore = ScenarioAssessmentStore(directory: rootDirectory.appending(path: "Assessments"))
    }

    func qualification(executionID: UUID, referenceTime: Date = Date()) async throws -> IntentEvidenceCaseDecision {
        guard let record = try await persistence.loadExecutionRecords().first(where: { $0.id == executionID }),
              let plan = try await persistence.loadPlan(id: record.planID),
              let definition = try await persistence.loadDefinitions().first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }) else {
            throw ScenarioPersistenceError.invalidRun("The saved execution, frozen plan, or requirement is unavailable.")
        }
        var artifacts: [UUID: Data] = [:]
        let item = try await bundleCase(definition: definition, plan: plan, record: record, artifacts: &artifacts)
        return IntentEvidenceQualification.qualify(
            item, requirement: try await evidenceRequirement(definition: definition), referenceTime: referenceTime
        )
    }

    func evidenceRequirement(definition: ScenarioDefinition) async throws -> IntentEvidenceRequirements.CaseRequirement {
        let policy = try await assessmentStore.frozenSemanticPolicy(definition: definition)
        return .init(required: true, definition: definition, semanticPolicy: try policy?.requirementPolicy())
    }

    func bundleCase(
        definition: ScenarioDefinition, plan: ScenarioExecutionPlan,
        record: ScenarioExecutionRecord, artifacts: inout [UUID: Data]
    ) async throws -> IntentEvidenceBundleCase {
        guard record.planID == plan.id,
              let savedPlan = try await persistence.loadPlans().first(where: { $0.id == plan.id }),
              try Self.matchesPersistedEncoding(savedPlan, plan),
              let savedRecord = try await persistence.loadExecutionRecords().first(where: { $0.id == record.id }),
              try Self.matchesPersistedEncoding(savedRecord, record) else {
            throw ScenarioPersistenceError.invalidRun("Execution plan or terminal record is missing from durable history.")
        }
        let childIDs = Set(record.records.filter { $0.featureChild == nil }
            .compactMap(\.evidenceRunID))
        let nativeRuns = try await persistence.loadRuns(scenarioID: definition.id)
            .filter { childIDs.contains($0.id) }
        guard nativeRuns.count == childIDs.count else {
            throw ScenarioPersistenceError.invalidRun("A native child run is missing from durable history.")
        }
        let allJournals = try await persistence.loadJournals()
        let childJournals = allJournals.filter { childIDs.contains($0.id) }
        guard childJournals.count == childIDs.count else {
            throw ScenarioPersistenceError.invalidRun("A native child journal is missing from durable history.")
        }
        for run in nativeRuns {
            for artifact in run.laneResults.flatMap(\.artifacts) {
                artifacts[artifact.id] = try Data(contentsOf: rootDirectory.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)").appending(path: artifact.relativePath))
            }
        }
        let selection = try await assessmentStore.latestSelectionRecord(executionRecord: savedRecord)
        let retained: [ScenarioRetainedAssessmentArtifact]
        if let selection {
            retained = try await assessmentStore.retainedArtifacts(
                for: selection, executionRecord: savedRecord,
                runs: nativeRuns, definition: definition,
                plan: savedPlan, journals: childJournals
            )
        } else if savedRecord.selectedAssessments != nil {
            retained = try await assessmentStore.retainedArtifacts(
                for: savedRecord, runs: nativeRuns, definition: definition,
                plan: savedPlan, journals: childJournals
            )
        } else {
            retained = []
        }
        return .init(definition: definition, plan: savedPlan, record: savedRecord,
                     runs: nativeRuns, journals: childJournals,
                     selectedAssessment: selection, retainedAssessments: retained)
    }

    private static func matchesPersistedEncoding<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }

}
