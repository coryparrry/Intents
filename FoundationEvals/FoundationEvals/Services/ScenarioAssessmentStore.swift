import Foundation

enum ScenarioAssessmentStoreError: LocalizedError {
    case invalidBinding(String)
    case conflictingAssessment
    case corruptHistory(String)

    var errorDescription: String? {
        switch self {
        case .invalidBinding(let detail): "Assessment does not match the saved scenario evidence: \(detail)"
        case .conflictingAssessment: "An assessment with this ID already has different saved content."
        case .corruptHistory(let detail): "Saved assessment history needs review: \(detail)"
        }
    }
}

/// Append-only assessment evidence plus a separately replaceable selection.
/// The scenario run remains immutable. All reads rebind assessments to the
/// caller's saved run and frozen definition before presenting a selection.
actor ScenarioAssessmentStore {
    private let root: URL

    init(directory: URL) { root = directory }

    /// Reassess the supplied saved observation and append a new immutable
    /// assessment. The caller can retry `append` with the returned value after
    /// a save failure; neither path invokes the app feature or native route.
    func reassessSavedOutput(
        request: ScenarioAssessmentRequest,
        run: ScenarioRun,
        definition: ScenarioDefinition,
        resolvedJudge: EvaluationResolvedJudgeConnection?
    ) async throws -> ScenarioIndependentAssessment {
        let assessment = try await ScenarioIndependentAssessmentService.assess(
            request, resolvedJudge: resolvedJudge
        )
        try append(assessment, for: run, definition: definition)
        return assessment
    }

    /// The App Feature route is stored as a sealed child of the execution
    /// record, not as a ScenarioRun. Reassessment reads that child response and
    /// its host-only requirement; it never dispatches the feature again.
    func reassessSavedFeatureOutput(
        coordinateID: UUID,
        assertionID: UUID,
        executionRecord: ScenarioExecutionRecord,
        definition: ScenarioDefinition,
        judgeConfiguration: EvaluationJudgeConfiguration,
        resolvedJudge: EvaluationResolvedJudgeConnection?
    ) async throws -> ScenarioIndependentAssessment {
        guard let coordinate = executionRecord.records.first(where: { $0.id == coordinateID }),
              coordinate.coordinate.lane == .appFeature,
              let child = coordinate.featureChild,
              let lane = coordinate.laneResult,
              let assertion = definition.assertions.first(where: { $0.id == assertionID }),
              assertion.kind == .semanticRubric,
              assertion.applies(to: .appFeature) else {
            throw ScenarioAssessmentStoreError.invalidBinding("feature coordinate or semantic requirement")
        }
        let reference: String
        switch assertion.expectedValue {
        case .string(let value): reference = value
        case nil: reference = ""
        default: throw ScenarioAssessmentStoreError.invalidBinding("feature verified reference")
        }
        let request = ScenarioAssessmentRequest(
            scenarioRunID: child.runID, laneResult: lane, assertion: assertion,
            effectiveInput: definition.goal.requestText,
            verifiedReference: reference,
            judgeConfiguration: judgeConfiguration
        )
        let assessment = try await ScenarioIndependentAssessmentService.assess(
            request, resolvedJudge: resolvedJudge
        )
        try appendFeature(assessment, for: executionRecord, definition: definition)
        return assessment
    }

    func appendFeature(
        _ assessment: ScenarioIndependentAssessment,
        for executionRecord: ScenarioExecutionRecord,
        definition: ScenarioDefinition,
        select: Bool = true
    ) throws {
        try Self.validateFeature(assessment, executionRecord: executionRecord, definition: definition)
        try saveImmutableAssessment(assessment)
        if select {
            try selectFeature(assessment.id, for: assessment.laneResultID,
                              assertionID: assessment.assertionID,
                              executionRecord: executionRecord, definition: definition)
        }
    }

    func append(
        _ assessment: ScenarioIndependentAssessment,
        for run: ScenarioRun,
        definition: ScenarioDefinition,
        select: Bool = true
    ) throws {
        try Self.validate(assessment, run: run, definition: definition)
        try saveImmutableAssessment(assessment)
        if select {
            try self.select(assessment.id, for: assessment.laneResultID,
                            assertionID: assessment.assertionID, run: run, definition: definition)
        }
    }

    private func saveImmutableAssessment(_ assessment: ScenarioIndependentAssessment) throws {
        let folder = directory(for: assessment.scenarioRunID, laneResultID: assessment.laneResultID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: assessment.id.uuidString.lowercased() + ".json")
        let bytes = try CanonicalJSON.data(for: assessment)

        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else {
                throw ScenarioAssessmentStoreError.conflictingAssessment
            }
        } else {
            let temporary = folder.appending(path: ".assessment-\(UUID().uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try bytes.write(to: temporary, options: .atomic)
            do {
                // Hard-link creation is exclusive: another writer cannot replace
                // a previously committed assessment with this ID.
                try FileManager.default.linkItem(at: temporary, to: destination)
            } catch {
                guard FileManager.default.fileExists(atPath: destination.path),
                      try Data(contentsOf: destination) == bytes else { throw error }
            }
        }
    }

    func select(
        _ assessmentID: UUID,
        for laneResultID: UUID,
        assertionID: UUID,
        run: ScenarioRun,
        definition: ScenarioDefinition
    ) throws {
        var history = try self.history(for: run, laneResultID: laneResultID, definition: definition)
        try history.select(assessmentID, for: laneResultID, assertionID: assertionID)
        let selectionURL = directory(for: run.id, laneResultID: laneResultID)
            .appending(path: "selection.json")
        try CanonicalJSON.data(for: history.selections).write(to: selectionURL, options: .atomic)
    }

    func selectFeature(
        _ assessmentID: UUID,
        for laneResultID: UUID,
        assertionID: UUID,
        executionRecord: ScenarioExecutionRecord,
        definition: ScenarioDefinition
    ) throws {
        var history = try featureHistory(
            for: executionRecord, laneResultID: laneResultID, definition: definition
        )
        try history.select(assessmentID, for: laneResultID, assertionID: assertionID)
        guard let runID = executionRecord.records.first(where: {
            $0.evidenceLaneResultID == laneResultID && $0.coordinate.lane == .appFeature
        })?.evidenceRunID else {
            throw ScenarioAssessmentStoreError.invalidBinding("feature run")
        }
        let selectionURL = directory(for: runID, laneResultID: laneResultID)
            .appending(path: "selection.json")
        try CanonicalJSON.data(for: history.selections).write(to: selectionURL, options: .atomic)
    }

    func history(
        for run: ScenarioRun,
        laneResultID: UUID,
        definition: ScenarioDefinition
    ) throws -> ScenarioAssessmentHistory {
        try loadHistory(runID: run.id, laneResultID: laneResultID) { record in
            try Self.validate(record, run: run, definition: definition)
        }
    }

    func featureHistory(
        for executionRecord: ScenarioExecutionRecord,
        laneResultID: UUID,
        definition: ScenarioDefinition
    ) throws -> ScenarioAssessmentHistory {
        guard let runID = executionRecord.records.first(where: {
            $0.evidenceLaneResultID == laneResultID && $0.coordinate.lane == .appFeature
        })?.evidenceRunID else {
            throw ScenarioAssessmentStoreError.invalidBinding("feature run")
        }
        return try loadHistory(runID: runID, laneResultID: laneResultID) { record in
            try Self.validateFeature(record, executionRecord: executionRecord, definition: definition)
        }
    }

    private func loadHistory(
        runID: UUID,
        laneResultID: UUID,
        validate: (ScenarioIndependentAssessment) throws -> Void
    ) throws -> ScenarioAssessmentHistory {
        let folder = directory(for: runID, laneResultID: laneResultID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .init() }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") && $0 != "selection.json" }
            .sorted()
        var history = ScenarioAssessmentHistory()
        for name in names {
            guard let id = UUID(uuidString: String(name.dropLast(5))),
                  name == id.uuidString.lowercased() + ".json" else {
                throw ScenarioAssessmentStoreError.corruptHistory("Unexpected assessment filename.")
            }
            let url = folder.appending(path: name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ScenarioAssessmentStoreError.corruptHistory("Assessment is not a regular file.")
            }
            let record = try CanonicalJSON.decode(ScenarioIndependentAssessment.self, from: Data(contentsOf: url))
            guard record.id == id, record.laneResultID == laneResultID else {
                throw ScenarioAssessmentStoreError.corruptHistory("Assessment identity does not match its file.")
            }
            try validate(record)
            try history.append(record, select: false)
        }
        let selectionURL = folder.appending(path: "selection.json")
        if FileManager.default.fileExists(atPath: selectionURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: selectionURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ScenarioAssessmentStoreError.corruptHistory("Selection is not a regular file.")
            }
            let selections = try CanonicalJSON.decode(
                [ScenarioAssessmentHistory.Selection].self,
                from: Data(contentsOf: selectionURL)
            )
            guard Set(selections.map { "\($0.laneResultID):\($0.assertionID)" }).count == selections.count else {
                throw ScenarioAssessmentStoreError.corruptHistory("Duplicate selected assessment.")
            }
            for selection in selections {
                try history.select(selection.assessmentID,
                                   for: selection.laneResultID, assertionID: selection.assertionID)
            }
        }
        return history
    }

    /// Freeze the current per-coordinate selections as a new, separately
    /// sealed measurement record. Selection after reassessment creates another
    /// record; it never rewrites the terminal execution record.
    func sealSelection(
        executionRecord: ScenarioExecutionRecord,
        runs: [ScenarioRun],
        definition: ScenarioDefinition,
        previousSelectionID: UUID? = nil
    ) throws -> ScenarioAssessmentSelectionRecord {
        var projections: [ScenarioSelectedAssessmentProjection] = []
        for coordinate in executionRecord.records {
            guard let runID = coordinate.evidenceRunID,
                  let laneResultID = coordinate.evidenceLaneResultID else { continue }
            let history: ScenarioAssessmentHistory
            if coordinate.coordinate.lane == .appFeature {
                history = try featureHistory(
                    for: executionRecord, laneResultID: laneResultID, definition: definition
                )
            } else {
                guard let run = runs.first(where: { $0.id == runID }) else {
                    throw ScenarioAssessmentStoreError.invalidBinding("missing source run")
                }
                history = try self.history(
                    for: run, laneResultID: laneResultID, definition: definition
                )
            }
            for selection in history.selections {
                guard let assessment = history.selected(
                    for: selection.laneResultID, assertionID: selection.assertionID
                ) else {
                    throw ScenarioAssessmentStoreError.corruptHistory("Selected assessment is unavailable.")
                }
                projections.append(try assessment.portableProjection())
            }
        }
        let sealed = try ScenarioAssessmentSelectionRecord.make(
            executionRecord: executionRecord, assessments: projections,
            previousSelectionID: previousSelectionID
        )
        try saveSelectionRecord(sealed, for: executionRecord)
        return sealed
    }

    func loadSelectionRecord(
        id: UUID,
        executionRecord: ScenarioExecutionRecord
    ) throws -> ScenarioAssessmentSelectionRecord {
        let url = selectionRecordDirectory(for: executionRecord.id)
            .appending(path: id.uuidString.lowercased() + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ScenarioAssessmentStoreError.corruptHistory("Selection record is not a regular file.")
        }
        let record = try CanonicalJSON.decode(
            ScenarioAssessmentSelectionRecord.self, from: Data(contentsOf: url)
        )
        guard record.id == id, record.isBound(to: executionRecord) else {
            throw ScenarioAssessmentStoreError.corruptHistory("Selection record failed its source binding.")
        }
        return record
    }

    func latestSelectionRecord(
        executionRecord: ScenarioExecutionRecord
    ) throws -> ScenarioAssessmentSelectionRecord? {
        let pointer = selectionRecordDirectory(for: executionRecord.id)
            .appending(path: "latest.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: pointer.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ScenarioAssessmentStoreError.corruptHistory("Latest selection pointer is not a regular file.")
        }
        let id = try CanonicalJSON.decode(UUID.self, from: Data(contentsOf: pointer))
        return try loadSelectionRecord(id: id, executionRecord: executionRecord)
    }

    func selectionRecords(
        executionRecord: ScenarioExecutionRecord
    ) throws -> [ScenarioAssessmentSelectionRecord] {
        let folder = selectionRecordDirectory(for: executionRecord.id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") && $0 != "latest.json" }
            .map { name in
                guard let id = UUID(uuidString: String(name.dropLast(5))),
                      name == id.uuidString.lowercased() + ".json" else {
                    throw ScenarioAssessmentStoreError.corruptHistory("Unexpected selection record filename.")
                }
                return try loadSelectionRecord(id: id, executionRecord: executionRecord)
            }
            .sorted { $0.selectedAt < $1.selectedAt }
    }

    /// Export exactly the retained assessments named by a sealed selection.
    /// Bundle writers must use these validated originals, not synthesize a
    /// status from the projection.
    func retainedArtifacts(
        for selection: ScenarioAssessmentSelectionRecord,
        executionRecord: ScenarioExecutionRecord,
        runs: [ScenarioRun],
        definition: ScenarioDefinition
    ) throws -> [ScenarioRetainedAssessmentArtifact] {
        guard selection.isBound(to: executionRecord) else {
            throw ScenarioAssessmentStoreError.invalidBinding("selected execution record")
        }
        return try retainedArtifacts(
            projections: selection.assessments, executionRecord: executionRecord,
            runs: runs, definition: definition
        )
    }

    func retainedArtifacts(
        for executionRecord: ScenarioExecutionRecord,
        runs: [ScenarioRun],
        definition: ScenarioDefinition
    ) throws -> [ScenarioRetainedAssessmentArtifact] {
        try retainedArtifacts(
            projections: executionRecord.selectedAssessments ?? [],
            executionRecord: executionRecord, runs: runs, definition: definition
        )
    }

    private func retainedArtifacts(
        projections: [ScenarioSelectedAssessmentProjection],
        executionRecord: ScenarioExecutionRecord,
        runs: [ScenarioRun],
        definition: ScenarioDefinition
    ) throws -> [ScenarioRetainedAssessmentArtifact] {
        guard ScenarioExecutionRecord.selectedAssessmentsAreBound(
            projections, to: executionRecord.records
        ) else {
            throw ScenarioAssessmentStoreError.invalidBinding("selected assessment coordinates")
        }
        return try projections.map { projection in
            let history: ScenarioAssessmentHistory
            if projection.lane == .appFeature {
                history = try featureHistory(
                    for: executionRecord, laneResultID: projection.laneResultID,
                    definition: definition
                )
            } else {
                guard let run = runs.first(where: { $0.id == projection.scenarioRunID }) else {
                    throw ScenarioAssessmentStoreError.invalidBinding("missing source run")
                }
                history = try self.history(
                    for: run, laneResultID: projection.laneResultID,
                    definition: definition
                )
            }
            guard let retained = history.assessments.first(where: {
                $0.id == projection.selectedAssessmentID
            }), try retained.portableProjection() == projection else {
                throw ScenarioAssessmentStoreError.invalidBinding("retained selected assessment")
            }
            return try retained.portableArtifact()
        }
    }

    private func saveSelectionRecord(
        _ record: ScenarioAssessmentSelectionRecord,
        for executionRecord: ScenarioExecutionRecord
    ) throws {
        guard record.isBound(to: executionRecord) else {
            throw ScenarioAssessmentStoreError.invalidBinding("selection seal")
        }
        let folder = selectionRecordDirectory(for: executionRecord.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: record.id.uuidString.lowercased() + ".json")
        let bytes = try CanonicalJSON.data(for: record)
        let temporary = folder.appending(path: ".selection-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .atomic)
        do {
            try FileManager.default.linkItem(at: temporary, to: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path),
                  try Data(contentsOf: url) == bytes else { throw error }
        }
        // This pointer is mutable by design; the referenced record is not.
        let pointer = folder.appending(path: "latest.json")
        try CanonicalJSON.data(for: record.id).write(to: pointer, options: .atomic)
    }

    private func selectionRecordDirectory(for executionRecordID: UUID) -> URL {
        root.appending(path: "Selections", directoryHint: .isDirectory)
            .appending(path: executionRecordID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func directory(for runID: UUID, laneResultID: UUID) -> URL {
        root.appending(path: runID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: laneResultID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private static func validate(
        _ record: ScenarioIndependentAssessment,
        run: ScenarioRun,
        definition: ScenarioDefinition
    ) throws {
        func reject(_ detail: String) -> ScenarioAssessmentStoreError { .invalidBinding(detail) }
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              run.id == record.scenarioRunID,
              run.scenarioID == definition.id,
              run.scenarioVersion == definition.version,
              run.scenarioDigest == definition.definitionDigest else {
            throw reject("run or requirement revision")
        }
        let matchingLanes = run.laneResults.filter { $0.id == record.laneResultID }
        guard matchingLanes.count == 1, let lane = matchingLanes.first else {
            throw reject("route coordinate")
        }
        try validateCommon(record, lane: lane, definition: definition)
    }

    private static func validateFeature(
        _ record: ScenarioIndependentAssessment,
        executionRecord: ScenarioExecutionRecord,
        definition: ScenarioDefinition
    ) throws {
        func reject(_ detail: String) -> ScenarioAssessmentStoreError { .invalidBinding(detail) }
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              let coordinate = executionRecord.records.first(where: {
                  $0.evidenceLaneResultID == record.laneResultID
                      && $0.evidenceRunID == record.scenarioRunID
                      && $0.coordinate.lane == .appFeature
              }),
              let child = coordinate.featureChild,
              child.hasValidDigest,
              coordinate.coordinate.caseID == definition.id,
              child.runID == record.scenarioRunID,
              case .string(let featureResponse)? = coordinate.laneResult?.observations["feature.response"],
              child.response == featureResponse,
              child.caseID == record.caseID,
              child.attempt == record.attempt,
              let lane = coordinate.laneResult else {
            throw reject("sealed feature child or captured response")
        }
        try validateCommon(record, lane: lane, definition: definition)
    }

    private static func validateCommon(
        _ record: ScenarioIndependentAssessment,
        lane: ScenarioLaneResult,
        definition: ScenarioDefinition
    ) throws {
        func reject(_ detail: String) -> ScenarioAssessmentStoreError { .invalidBinding(detail) }
        guard lane.id == record.laneResultID,
              lane.caseID == record.caseID,
              lane.lane == record.lane,
              lane.attempt == record.attempt,
              case .string(let rawOutput)? = lane.observations[record.observationKey],
              record.rawOutputDigest == ScenarioIndependentAssessmentService.digest(rawOutput) else {
            throw reject("route coordinate or captured output")
        }
        guard let assertion = definition.assertions.first(where: { $0.id == record.assertionID }),
              assertion.kind == .semanticRubric,
              assertion.applies(to: lane.lane),
              assertion.observationKey == record.observationKey,
              assertion.explanation.trimmingCharacters(in: .whitespacesAndNewlines) == record.rubric,
              definition.goal.requestText == record.effectiveInput else {
            throw reject("semantic requirement")
        }
        switch assertion.expectedValue {
        case .string(let reference) where reference == record.verifiedReference: break
        case nil where record.verifiedReference.isEmpty: break
        default: throw reject("verified reference")
        }
        let binding = ScenarioAssessmentSourceBinding(
            scenarioRunID: record.scenarioRunID,
            laneResultID: record.laneResultID,
            caseID: record.caseID,
            lane: record.lane,
            attempt: record.attempt,
            assertionID: record.assertionID,
            observationKey: record.observationKey,
            rawOutputDigest: record.rawOutputDigest,
            verifiedReferenceDigest: record.verifiedReferenceDigest,
            rubricDigest: record.rubricDigest
        )
        guard record.verifiedReferenceDigest == ScenarioIndependentAssessmentService.digest(record.verifiedReference),
              record.rubricDigest == ScenarioIndependentAssessmentService.digest(record.rubric),
              record.sourceBindingDigest == ScenarioIndependentAssessmentService.digest(
                try CanonicalJSON.data(for: binding, prettyPrinted: false)
              ),
              record.judgePolicyDigest == ScenarioIndependentAssessmentService.digest(
                try CanonicalJSON.data(for: record.judgePolicy, prettyPrinted: false)
              ) else {
            throw reject("source or judge policy digest")
        }
        let evaluationCase = EvaluationCase(
            id: record.caseID, name: record.lane.title,
            prompt: record.effectiveInput, expected: record.verifiedReference
        )
        let contract = try EvaluationScoringContract(
            scoringMode: .modelJudge,
            rubricCriteria: record.rubric.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            judgePromptVersion: record.judgePolicy.promptVersion,
            judgePassingScore: record.judgePolicy.passingScore,
            cases: [evaluationCase]
        )
        guard record.scoringContract == contract,
              record.judgePolicy.scoringContract == contract,
              record.assessment.scoringContract == contract,
              record.assessment.runID == record.scenarioRunID,
              record.assessment.rubric == record.rubric,
              record.assessment.promptVersion == record.judgePolicy.promptVersion,
              record.assessment.passingScore == record.judgePolicy.passingScore,
              record.assessment.subjectEvidenceDigest == record.sourceBindingDigest,
              record.assessment.samples.count == 1,
              record.assessment.samples[0].sampleID == lane.id,
              (!record.isScored || record.availabilityIssue == nil) else {
            throw reject("assessment or scoring contract")
        }
        let semanticNeedsJudge = contract.rubricCriteria.contains {
            EvaluationExactCriterion.expectedText(in: $0) == nil
        }
        if record.isScored && semanticNeedsJudge {
            guard record.judgePolicy.judgeMode == .connection,
                  record.judgePolicy.connectionID != nil,
                  record.assessment.judge.mode == .connection,
                  record.assessment.judge.connectionID == record.judgePolicy.connectionID,
                  record.assessment.observedJudgeIdentities?.count == 1,
                  record.assessment.observedJudgeIdentities?.first?.connectionID == record.judgePolicy.connectionID else {
                throw reject("independent judge identity")
            }
        }
    }
}
