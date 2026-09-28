import CryptoKit
import Foundation

enum ScenarioCollectionService {
    static func member(_ definition: ScenarioDefinition) throws -> ScenarioCollectionMember {
        try .init(definition: definition)
    }

    /// The source definition and collection remain untouched. Every approved
    /// draft creates a distinct case whose exact reviewed wording is frozen.
    static func addingApprovedVariations(
        _ approvals: [ScenarioApprovedVariation],
        source: ScenarioDefinition,
        to collection: ScenarioCollection
    ) throws -> (collection: ScenarioCollection, cases: [ScenarioDefinition]) {
        try collection.validate()
        guard let sourceMember = collection.members.first(where: { $0.caseID == source.id }),
              sourceMember.version == source.version,
              sourceMember.definitionDigest == source.definitionDigest,
              sourceMember.testContractDigest == source.testContractDigest,
              source.hasValidDigest, !approvals.isEmpty else {
            throw ScenarioCollectionError.invalidDefinition(source.id)
        }
        var members = collection.members
        var definitions: [ScenarioDefinition] = []
        var draftIDs = Set<UUID>()
        for approval in approvals {
            let draft = approval.draft
            let candidate = approval.reviewedDefinition
            guard draftIDs.insert(draft.id).inserted,
                  draft.sourceCaseID == source.id, draft.sourceVersion == source.version,
                  !draft.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.schemaVersion == ScenarioDefinition.stableSchemaVersion,
                  candidate.id != source.id, candidate.version == 1,
                  candidate.projectID == collection.projectID,
                  candidate.goal.requestText == draft.requestText,
                  candidate.directControl.parameters == draft.parameters,
                  (candidate.featureBinding?.inputMapping ?? []) == draft.featureInputs,
                  !members.contains(where: { $0.caseID == candidate.id }) else {
                throw ScenarioCollectionError.invalidVariation(draft.id)
            }
            if let reason = draft.unsupportedReason, !reason.isEmpty {
                throw ScenarioCollectionError.unsupportedVariation(draft.id, reason)
            }
            switch draft.outcomeReview {
            case .sameOutcome:
                guard candidate.goal.expectedBehavior == source.goal.expectedBehavior,
                      sameChecksIgnoringIDs(candidate.assertions, source.assertions) else {
                    throw ScenarioCollectionError.changedOutcomeNeedsReview(draft.id)
                }
            case .differentOutcomeReviewed:
                guard candidate.goal.expectedBehavior != source.goal.expectedBehavior,
                      !sameChecksIgnoringIDs(candidate.assertions, source.assertions),
                      !candidate.goal.expectedBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ScenarioCollectionError.changedOutcomeNeedsReview(draft.id)
                }
            }
            let frozen = try candidate.frozen()
            let lineage = ScenarioCaseLineage(
                sourceCaseID: source.id, sourceVersion: source.version,
                approvedDraftID: draft.id, reviewedRequestText: draft.requestText,
                outcomeReview: draft.outcomeReview
            )
            members.append(try .init(definition: frozen, lineage: lineage))
            definitions.append(frozen)
        }
        return (try collection.revised(members: members), definitions)
    }

    private static func sameChecksIgnoringIDs(_ lhs: [ScenarioAssertion],
                                              _ rhs: [ScenarioAssertion]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.kind == b.kind && a.observationKey == b.observationKey
                && a.expectedValue == b.expectedValue && a.explanation == b.explanation
                && a.required == b.required && a.applicableLanes == b.applicableLanes
        }
    }

    static func freezeManifest(
        collection: ScenarioCollection,
        definitions: [ScenarioDefinition],
        scope: ScenarioCollectionScope,
        appProductDigest: String,
        subjectInputDigests: [UUID: String] = [:],
        selectedCaseIDs: Set<UUID>? = nil,
        priorBatchID: UUID? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> ScenarioCollectionBatchManifest {
        try collection.validate()
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        guard definitionsByID.count == definitions.count,
              Set(definitionsByID.keys) == Set(collection.members.map(\.caseID)) else {
            throw ScenarioCollectionError.invalidSelection
        }
        for member in collection.members {
            guard let definition = definitionsByID[member.caseID],
                  definition.projectID == collection.projectID,
                  definition.version == member.version,
                  definition.definitionDigest == member.definitionDigest,
                  definition.testContractDigest == member.testContractDigest,
                  definition.hasValidDigest else {
                throw ScenarioCollectionError.invalidDefinition(member.caseID)
            }
        }
        let selected = selectedCaseIDs ?? Set(collection.members.map(\.caseID))
        guard !appProductDigest.isEmpty, !selected.isEmpty,
              selected.isSubset(of: Set(collection.members.map(\.caseID))),
              (scope != .full || selected == Set(collection.members.map(\.caseID))),
              (scope == .rerunFailed) == (priorBatchID != nil) else {
            throw ScenarioCollectionError.invalidSelection
        }
        let selectedMembers = collection.members.filter { selected.contains($0.caseID) }
        let cases = try selectedMembers.map { member -> ScenarioBatchCase in
            let definition = definitionsByID[member.caseID]!
            let expectedSubjectInputDigest: String?
            if definition.coverage.appFeature != .notApplicable {
                guard definition.featureBinding != nil,
                      let digest = subjectInputDigests[member.caseID], !digest.isEmpty else {
                    throw ScenarioCollectionError.invalidDefinition(member.caseID)
                }
                expectedSubjectInputDigest = digest
            } else {
                expectedSubjectInputDigest = nil
            }
            return .init(member: member, executionPlanID: UUID(),
                         fixtureContractDigest: definition.fixture.digest,
                         targetBundleIdentifier: definition.target.bundleIdentifier,
                         featureID: definition.featureBinding?.featureID,
                         expectedSubjectInputDigest: expectedSubjectInputDigest)
        }
        var coordinates: [ScenarioPlannedCoordinate] = []
        for member in selectedMembers {
            let definition = definitionsByID[member.caseID]!
            for lane in ScenarioLane.allCases {
                let requirement = definition.coverage[lane]
                guard requirement != .notApplicable else { continue }
                let count: Int
                if lane == .siri {
                    count = definition.coverage.siriAttemptCount ?? 1
                    guard count >= 1 && count <= 3,
                          definition.safety.mutationPolicy == .readOnly || count == 1 else {
                        throw ScenarioCollectionError.invalidDefinition(member.caseID)
                    }
                } else {
                    count = 1
                }
                for repetition in 1...count {
                    coordinates.append(.init(id: UUID(), caseID: member.caseID, lane: lane,
                                             repetition: repetition, required: requirement == .required))
                }
            }
        }
        guard !coordinates.isEmpty else { throw ScenarioCollectionError.invalidSelection }
        var manifest = ScenarioCollectionBatchManifest(
            id: id, collectionID: collection.id, collectionVersion: collection.version,
            membershipDigest: collection.membershipDigest,
            appProductDigest: appProductDigest, scope: scope,
            priorBatchID: priorBatchID, cases: cases, coordinates: coordinates,
            createdAt: createdAt, manifestDigest: ""
        )
        manifest.manifestDigest = try manifest.calculatedDigest()
        return manifest
    }

    static func freezeFailedRerun(
        collection: ScenarioCollection,
        definitions: [ScenarioDefinition],
        priorManifest: ScenarioCollectionBatchManifest,
        priorResult: ScenarioCollectionBatchResult?,
        priorRuns: [ScenarioRun],
        appProductDigest: String,
        subjectInputDigests: [UUID: String] = [:],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> ScenarioCollectionBatchManifest {
        let prior = assess(manifest: priorManifest, collection: collection,
                           result: priorResult, runs: priorRuns)
        guard prior.qualification != .incompatible,
              priorManifest.collectionID == collection.id,
              priorManifest.collectionVersion == collection.version else {
            throw ScenarioCollectionError.invalidManifest
        }
        let failed = failedCaseIDs(in: prior)
        guard !failed.isEmpty else { throw ScenarioCollectionError.invalidSelection }
        return try freezeManifest(
            collection: collection, definitions: definitions, scope: .rerunFailed,
            appProductDigest: appProductDigest, subjectInputDigests: subjectInputDigests,
            selectedCaseIDs: failed,
            priorBatchID: priorManifest.id, id: id, createdAt: createdAt
        )
    }

    /// All planned coordinates are assessed from this batch's own terminal
    /// records. A missing row is visible as notRun. Historical green evidence
    /// cannot fill a selected rerun or a newer manifest.
    static func assess(
        manifest: ScenarioCollectionBatchManifest,
        collection: ScenarioCollection,
        result: ScenarioCollectionBatchResult?,
        runs: [ScenarioRun]
    ) -> ScenarioCollectionBatchAssessment {
        guard (try? validate(manifest: manifest, collection: collection)) != nil,
              result == nil || (result?.id == manifest.id && result?.manifestID == manifest.id) else {
            return .init(qualification: .incompatible, coordinates: [], passedCount: 0,
                         plannedCount: manifest.coordinates.count, reasons: ["Batch manifest or collection membership changed."])
        }
        let executions = result?.executions ?? []
        let duplicatePlans = Dictionary(grouping: executions, by: \.planID).filter { $0.value.count != 1 }
        let casesByPlan = Dictionary(uniqueKeysWithValues: manifest.cases.map { ($0.executionPlanID, $0) })
        let plannedCoordinates = Dictionary(uniqueKeysWithValues: manifest.coordinates.map { ($0.id, $0) })
        let unexpectedExecution = executions.contains { execution in
            guard let plannedCase = casesByPlan[execution.planID] else { return true }
            let expected = manifest.coordinates.filter { $0.caseID == plannedCase.id }
            return execution.id != execution.planID
                || execution.completedAt < manifest.createdAt
                || !hasValidSeal(execution)
                || execution.records.count != expected.count
                || Set(execution.records.map(\.id)) != Set(expected.map(\.id))
                || execution.records.contains { plannedCoordinates[$0.id] != $0.coordinate }
        }
        let rows = executions.flatMap(\.records)
        let duplicateRows = Dictionary(grouping: rows, by: \.id).filter { $0.value.count != 1 }
        let runByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let caseByID = Dictionary(uniqueKeysWithValues: manifest.cases.map { ($0.id, $0) })
        let rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var usedLaneResults = Set<UUID>()
        var usedFeatureSamples = Set<UUID>()
        let assessments = manifest.coordinates.map { coordinate -> ScenarioBatchCoordinateAssessment in
            guard let row = rowByID[coordinate.id] else {
                return .init(coordinate: coordinate, terminalState: .notRun, outcome: nil,
                             reason: "No terminal record for this planned attempt.")
            }
            guard !duplicateRows.keys.contains(coordinate.id), row.coordinate == coordinate else {
                return .init(coordinate: coordinate, terminalState: .blocked, outcome: nil,
                             reason: "Duplicate or mismatched coordinate record.")
            }
            guard row.state == .completed else {
                return .init(coordinate: coordinate, terminalState: row.state, outcome: nil,
                             reason: row.detail ?? "Attempt did not complete.")
            }
            if coordinate.lane == .appFeature {
                guard let child = row.featureChild,
                      let lane = row.laneResult,
                      let snapshot = caseByID[coordinate.caseID],
                      child.hasValidDigest, child.hasVerifiedBuildBinding,
                      child.startedAt >= manifest.createdAt,
                      child.completedAt >= child.startedAt,
                      child.checkedAppProductDigest == manifest.appProductDigest,
                      child.appBundleIdentifier == snapshot.targetBundleIdentifier,
                      child.featureID == snapshot.featureID,
                      child.fixtureContractDigest == snapshot.fixtureContractDigest,
                      child.subjectInputDigest == snapshot.expectedSubjectInputDigest,
                      child.caseID == coordinate.caseID,
                      child.attempt == coordinate.repetition,
                      child.runID == row.evidenceRunID,
                      lane.id == row.evidenceLaneResultID,
                      lane.caseID == coordinate.caseID,
                      lane.lane == .appFeature,
                      lane.attempt == coordinate.repetition,
                      lane.observations["feature.response"] == .string(child.response),
                      lane.observations["feature.runID"] == .string(child.runID.uuidString),
                      lane.observations["feature.sampleID"] == .string(child.sampleID.uuidString),
                      usedFeatureSamples.insert(child.sampleID).inserted else {
                    return .init(coordinate: coordinate, terminalState: .blocked, outcome: nil,
                                 reason: "Feature sample is missing, duplicated or bound to a different build/case/fixture.")
                }
                let passed = lane.executionStatus == .completed && lane.outcome == .passed
                    && child.errorCategory == nil && child.errorMessage == nil
                return .init(coordinate: coordinate, terminalState: .completed,
                             outcome: passed ? .passed : lane.outcome,
                             reason: passed ? nil : (lane.diagnostic ?? "The feature requirement did not pass."))
            }
            guard let runID = row.evidenceRunID, let run = runByID[runID],
                  let laneID = row.evidenceLaneResultID,
                  let lane = run.laneResults.first(where: { $0.id == laneID }),
                  let caseSnapshot = caseByID[coordinate.caseID],
                  run.scenarioID == coordinate.caseID,
                  run.scenarioVersion == caseSnapshot.member.version,
                  run.testContractDigest == caseSnapshot.member.testContractDigest,
                  run.startedAt >= manifest.createdAt,
                  run.invocation.appProduct?.sha256 == manifest.appProductDigest,
                  lane.caseID == coordinate.caseID, lane.lane == coordinate.lane,
                  lane.attempt == coordinate.repetition,
                  usedLaneResults.insert(laneID).inserted else {
                return .init(coordinate: coordinate, terminalState: .blocked, outcome: nil,
                             reason: "Evidence is missing, stale, duplicated or belongs to another case/attempt.")
            }
            let passed = run.executionStatus == .completed && lane.executionStatus == .completed
                && lane.outcome == .passed
            return .init(coordinate: coordinate, terminalState: .completed,
                         outcome: passed ? .passed : lane.outcome,
                         reason: passed ? nil : (lane.diagnostic ?? "The requirement did not pass."))
        }
        let plannedIDs = Set(manifest.coordinates.map(\.id))
        let hasUnexpectedRows = rows.contains { !plannedIDs.contains($0.id) }
        let passedCount = assessments.count { $0.outcome == .passed }
        let incomplete = assessments.contains { $0.terminalState != .completed || $0.outcome == nil }
        let qualification: ScenarioBatchQualification
        if hasUnexpectedRows || unexpectedExecution || !duplicateRows.isEmpty || !duplicatePlans.isEmpty {
            qualification = .incompatible
        } else if manifest.scope != .full {
            qualification = .partial
        } else if incomplete {
            qualification = .incomplete
        } else if passedCount == assessments.count {
            qualification = .passedFull
        } else {
            qualification = .failedFull
        }
        var reasons: [String] = []
        if manifest.scope != .full { reasons.append("This execution selected only part of the collection.") }
        if hasUnexpectedRows || unexpectedExecution || !duplicateRows.isEmpty || !duplicatePlans.isEmpty {
            reasons.append("The batch contains an invalid case execution or duplicate coordinates.")
        }
        if incomplete { reasons.append("One or more planned attempts have no complete evidence.") }
        return .init(qualification: qualification, coordinates: assessments,
                     passedCount: passedCount, plannedCount: assessments.count, reasons: reasons)
    }

    static func hasValidSeal(_ execution: ScenarioExecutionRecord) -> Bool {
        struct Seal: Encodable {
            var planID: UUID
            var records: [ScenarioExecutionCoordinateRecord]
            var selectedAssessments: [ScenarioSelectedAssessmentProjection]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let sorted = execution.records.sorted { $0.id.uuidString < $1.id.uuidString }
        guard let data = try? encoder.encode(Seal(
            planID: execution.planID, records: sorted,
            selectedAssessments: ScenarioExecutionRecord.sortedAssessments(
                execution.selectedAssessments ?? []
            )
        )) else {
            return false
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == execution.evidenceDigest
    }

    static func failedCaseIDs(in assessment: ScenarioCollectionBatchAssessment) -> Set<UUID> {
        Set(assessment.coordinates.filter { $0.outcome != .passed }.map { $0.coordinate.caseID })
    }

    static func membershipDifference(
        baseline: ScenarioCollection, candidate: ScenarioCollection
    ) throws -> [ScenarioCollectionMembershipDifference] {
        try baseline.validate()
        try candidate.validate()
        guard baseline.id == candidate.id else { throw ScenarioCollectionError.invalidCollection }
        let old = Dictionary(uniqueKeysWithValues: baseline.members.map { ($0.caseID, $0) })
        let new = Dictionary(uniqueKeysWithValues: candidate.members.map { ($0.caseID, $0) })
        let ordered = baseline.members.map(\.caseID) + candidate.members.map(\.caseID).filter { old[$0] == nil }
        return ordered.map { id in
            let before = old[id]
            let after = new[id]
            let change: ScenarioCollectionMembershipChange
            switch (before, after) {
            case (nil, _?): change = .added
            case (_?, nil): change = .removed
            case (let lhs?, let rhs?):
                change = lhs.testContractDigest == rhs.testContractDigest ? .unchanged : .changed
            default: change = .changed
            }
            return .init(caseID: id, baseline: before, candidate: after, change: change)
        }
    }

    static func validate(manifest: ScenarioCollectionBatchManifest,
                         collection: ScenarioCollection) throws {
        try collection.validate()
        let all = collection.members
        let selected = manifest.cases.map(\.member)
        guard manifest.collectionID == collection.id,
              manifest.collectionVersion == collection.version,
              manifest.membershipDigest == collection.membershipDigest,
              manifest.hasValidDigest,
              !manifest.appProductDigest.isEmpty,
              !selected.isEmpty, Set(selected.map(\.caseID)).count == selected.count,
              selected == all.filter({ member in selected.contains(where: { $0.caseID == member.caseID }) }),
              Set(manifest.cases.map(\.executionPlanID)).count == manifest.cases.count,
              manifest.cases.allSatisfy({ !$0.fixtureContractDigest.isEmpty
                  && !$0.targetBundleIdentifier.isEmpty
                  && ($0.featureID == nil || $0.expectedSubjectInputDigest?.isEmpty == false) }),
              (manifest.scope != .full || selected == all),
              (manifest.scope == .rerunFailed) == (manifest.priorBatchID != nil),
              !manifest.coordinates.isEmpty,
              Set(manifest.coordinates.map(\.id)).count == manifest.coordinates.count else {
            throw ScenarioCollectionError.invalidManifest
        }
        let selectedIDs = Set(selected.map(\.caseID))
        guard manifest.coordinates.allSatisfy({ selectedIDs.contains($0.caseID) && $0.repetition > 0 }),
              Set(manifest.coordinates.map { "\($0.caseID)/\($0.lane.rawValue)/\($0.repetition)" }).count
                == manifest.coordinates.count else {
            throw ScenarioCollectionError.invalidManifest
        }
    }
}
