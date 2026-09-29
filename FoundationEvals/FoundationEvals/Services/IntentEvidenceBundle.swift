import CryptoKit
import Foundation

// This directory format is intentionally independent of the scenario, harness,
// and report-policy versions. Every ordinary file is named in the manifest.
struct IntentEvidenceBundleManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var policyID: String
    var sourceRevision: String
    var collectionID: String
    var cases: [CaseFile]
    var files: [File]
    var collection: String? = nil
    var batchManifest: String? = nil
    var batchResult: String? = nil

    struct CaseFile: Codable, Equatable, Sendable {
        var caseID: UUID
        var definition: String
        var plan: String
        var executionRecord: String
        var runs: [String]
        var journals: [String]
        var featureChildren: [String]
        var selectedAssessment: String? = nil
        var captureAssessments: String? = nil
        var retainedAssessments: [String] = []
    }

    struct File: Codable, Equatable, Sendable {
        var path: String
        var bytes: Int
        var sha256: String
    }
}

struct IntentEvidenceRequirements: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var collectionID: String
    var cases: [CaseRequirement]

    struct CaseRequirement: Codable, Equatable, Sendable {
        var required: Bool
        var definition: ScenarioDefinition
        var semanticPolicy: SemanticPolicy? = nil
    }

    /// Reviewed outside the exported result. A bundle cannot select its own
    /// judge or scoring contract and then call that choice qualified.
    struct SemanticPolicy: Codable, Equatable, Sendable {
        var scoringContractDigest: String
        var judgePolicyDigest: String
        /// Unix timestamp of an independently reviewed policy freeze. Nil
        /// preserves existing consumer-reviewed policies without a time gate.
        var frozenAt: TimeInterval? = nil
    }
}

struct IntentEvidenceBundleCase: Sendable {
    var definition: ScenarioDefinition
    var plan: ScenarioExecutionPlan
    var record: ScenarioExecutionRecord
    var runs: [ScenarioRun]
    var journals: [ScenarioExecutionJournal]
    var selectedAssessment: ScenarioAssessmentSelectionRecord? = nil
    var retainedAssessments: [ScenarioRetainedAssessmentArtifact] = []
}

/// The caller obtains these immutable values after the store has committed its
/// terminal record. Export writes one staging directory and atomically renames it.
struct IntentEvidenceBundleSnapshot: Sendable {
    var requirements: IntentEvidenceRequirements
    var cases: [IntentEvidenceBundleCase]
    var sourceRevision: String
    var artifactBytes: [UUID: Data] = [:]
    var report: Data? = nil
    var collection: ScenarioCollection? = nil
    var batchManifest: ScenarioCollectionBatchManifest? = nil
    var batchResult: ScenarioCollectionBatchResult? = nil
}

enum IntentEvidenceBundleError: LocalizedError {
    case invalid(String)
    case oversized(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "Invalid evidence bundle: \(detail)"
        case .oversized(let detail): "Evidence bundle exceeds its size limit: \(detail)"
        }
    }
}

enum IntentEvidenceBundle {
    static let policyID = "intent-lab-report-v3"
    static let maximumFiles = 500
    static let maximumFileBytes = 20_000_000
    static let maximumTotalBytes = 150_000_000
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func export(_ snapshot: IntentEvidenceBundleSnapshot, to destination: URL) throws {
        guard destination.pathExtension == "intentlabrun" else {
            throw IntentEvidenceBundleError.invalid("Use a .intentlabrun directory.")
        }
        guard !snapshot.sourceRevision.isEmpty, !snapshot.requirements.collectionID.isEmpty,
              snapshot.requirements.schemaVersion == IntentEvidenceRequirements.schemaVersion,
              Set(snapshot.cases.map { $0.definition.id }).count == snapshot.cases.count,
              Set(snapshot.requirements.cases.map { $0.definition.id }).count == snapshot.requirements.cases.count
        else { throw IntentEvidenceBundleError.invalid("The frozen case set is incomplete or duplicated.") }
        let trustedIDs = Set(snapshot.requirements.cases.map { $0.definition.id })
        let caseIDs = Set(snapshot.cases.map { $0.definition.id })
        let hasBatch = snapshot.collection != nil || snapshot.batchManifest != nil || snapshot.batchResult != nil
        if hasBatch {
            guard let collection = snapshot.collection,
                  let batch = snapshot.batchManifest,
                  let result = snapshot.batchResult else {
                throw IntentEvidenceBundleError.invalid("Collection batch metadata is incomplete.")
            }
            try collection.validate()
            guard batch.hasValidDigest, result.manifestID == batch.id,
                  result.id == batch.id, batch.collectionID == collection.id,
                  batch.collectionVersion == collection.version,
                  batch.membershipDigest == collection.membershipDigest,
                  snapshot.requirements.collectionID == collection.id.uuidString,
                  matchesMembership(collection, requirements: snapshot.requirements),
                  caseIDs.isSubset(of: Set(batch.cases.map(\.id))),
                  Set(result.executions.map(\.id)) == Set(snapshot.cases.map { $0.record.id }),
                  snapshot.cases.allSatisfy({ item in
                      batch.cases.contains(where: {
                          $0.id == item.definition.id && $0.executionPlanID == item.plan.id
                      }) && Set(item.plan.coordinates.map(\.id)) == Set(
                          batch.coordinates.filter { $0.caseID == item.definition.id }.map(\.id)
                      )
                  }) else {
                throw IntentEvidenceBundleError.invalid("Collection batch does not bind to full trusted membership.")
            }
        } else if caseIDs != trustedIDs || snapshot.cases.isEmpty {
            throw IntentEvidenceBundleError.invalid("The frozen case set is incomplete.")
        }

        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw IntentEvidenceBundleError.invalid("Destination already exists; evidence export is immutable.")
        }
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).intentlabrun", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: staging) } }

        var files: [IntentEvidenceBundleManifest.File] = []
        func write(_ path: String, _ data: Data) throws {
            try validatePath(path)
            guard data.count <= maximumFileBytes else { throw IntentEvidenceBundleError.oversized(path) }
            guard !files.contains(where: { $0.path == path }) else {
                throw IntentEvidenceBundleError.invalid("Duplicate path \(path).")
            }
            let url = staging.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            files.append(.init(path: path, bytes: data.count, sha256: digest(data)))
        }
        try write("requirements/collection.json", try jsonEncoder.encode(snapshot.requirements))
        if let collection = snapshot.collection,
           let batch = snapshot.batchManifest,
           let result = snapshot.batchResult {
            try write("requirements/membership.json", try jsonEncoder.encode(collection))
            try write("executions/batch-manifest.json", try jsonEncoder.encode(batch))
            try write("executions/batch-result.json", try jsonEncoder.encode(result))
        }
        var caseFiles: [IntentEvidenceBundleManifest.CaseFile] = []
        for item in snapshot.cases.sorted(by: { $0.definition.id.uuidString < $1.definition.id.uuidString }) {
            let caseID = item.definition.id
            guard let trustedCase = snapshot.requirements.cases.first(where: { $0.definition.id == caseID }),
                  item.definition.hasValidDigest,
                  trustedCase.definition.hasValidDigest,
                  item.definition.testContractDigest == trustedCase.definition.testContractDigest,
                  let rebuilt = try? ScenarioExecutionRecord.make(
                      plan: item.plan, records: item.record.records,
                      selectedAssessments: item.record.selectedAssessments ?? [],
                      completedAt: item.record.completedAt
                  ), rebuilt == item.record else {
                throw IntentEvidenceBundleError.invalid("Case \(caseID) has no valid frozen requirement and terminal seal.")
            }
            let prefix = caseID.uuidString
            let definitionPath = "requirements/\(prefix).json"
            let planPath = "executions/\(prefix)-plan.json"
            let recordPath = "executions/\(prefix)-terminal.json"
            try write(definitionPath, try jsonEncoder.encode(item.definition))
            try write(planPath, try jsonEncoder.encode(item.plan))
            try write(recordPath, try jsonEncoder.encode(item.record))
            var runPaths: [String] = []
            for run in item.runs.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let path = "executions/\(prefix)-run-\(run.id.uuidString).json"
                try write(path, try jsonEncoder.encode(run))
                runPaths.append(path)
                if let assessments = run.responseAssessments {
                    try write("assessments/\(prefix)-\(run.id.uuidString).json", try jsonEncoder.encode(assessments))
                }
                for lane in run.laneResults {
                    for artifact in lane.artifacts {
                        guard let bytes = snapshot.artifactBytes[artifact.id] else {
                            throw IntentEvidenceBundleError.invalid("Artifact \(artifact.id) is missing.")
                        }
                        guard bytes.count == artifact.byteCount, digest(bytes) == artifact.sha256 else {
                            throw IntentEvidenceBundleError.invalid("Artifact checksum mismatch: \(artifact.id).")
                        }
                        let path = "artifacts/\(artifact.id.uuidString)"
                        if !files.contains(where: { $0.path == path }) { try write(path, bytes) }
                    }
                }
            }
            var featurePaths: [String] = []
            for terminal in item.record.records where terminal.featureChild != nil {
                let child = terminal.featureChild!
                guard child.hasValidDigest, terminal.coordinate.lane == .appFeature else {
                    throw IntentEvidenceBundleError.invalid("Feature child has invalid coordinate or seal.")
                }
                let path = "executions/\(prefix)-feature-\(terminal.id.uuidString).json"
                try write(path, try jsonEncoder.encode(child))
                featurePaths.append(path)
            }
            var journalPaths: [String] = []
            for journal in item.journals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let path = "journals/\(prefix)-\(journal.id.uuidString).json"
                try write(path, try jsonEncoder.encode(journal))
                journalPaths.append(path)
            }
            var selectedAssessmentPath: String?
            var captureAssessmentsPath: String?
            if let selected = item.record.selectedAssessments {
                let path = "assessments/\(prefix)-capture.json"
                try write(path, try jsonEncoder.encode(selected))
                captureAssessmentsPath = path
            }
            if let selection = item.selectedAssessment {
                guard selection.isBound(to: item.record) else {
                    throw IntentEvidenceBundleError.invalid("Selected assessment is not bound to the terminal record.")
                }
                let path = "assessments/\(prefix)-selection.json"
                try write(path, try jsonEncoder.encode(selection))
                selectedAssessmentPath = path
            }
            let selected = item.selectedAssessment?.assessments
                ?? item.record.selectedAssessments ?? []
            guard Set(selected.map(\.selectedAssessmentID)).count == selected.count,
                  Set(item.retainedAssessments.map(\.id)).count == item.retainedAssessments.count,
                  Set(selected.map(\.selectedAssessmentID)) == Set(item.retainedAssessments.map(\.id)) else {
                throw IntentEvidenceBundleError.invalid("Retained assessments do not match the selected semantic population.")
            }
            var retainedPaths: [String] = []
            for artifact in item.retainedAssessments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard artifact.hasValidDigest,
                      selected.contains(artifact.projection) else {
                    throw IntentEvidenceBundleError.invalid("Retained assessment has no matching selected projection or seal.")
                }
                let path = "assessments/\(prefix)-retained-\(artifact.id.uuidString).json"
                try write(path, try jsonEncoder.encode(artifact))
                retainedPaths.append(path)
            }
            caseFiles.append(.init(caseID: caseID, definition: definitionPath, plan: planPath,
                                   executionRecord: recordPath, runs: runPaths, journals: journalPaths,
                                   featureChildren: featurePaths,
                                   selectedAssessment: selectedAssessmentPath,
                                   captureAssessments: captureAssessmentsPath,
                                   retainedAssessments: retainedPaths))
        }
        try write("provenance/source.json", try jsonEncoder.encode(["sourceRevision": snapshot.sourceRevision]))
        if let report = snapshot.report { try write("report.json", report) }
        guard files.count <= maximumFiles, files.reduce(0, { $0 + $1.bytes }) <= maximumTotalBytes else {
            throw IntentEvidenceBundleError.oversized("total file count or bytes")
        }
        var manifest = IntentEvidenceBundleManifest(policyID: policyID,
                                                    sourceRevision: snapshot.sourceRevision,
                                                    collectionID: snapshot.requirements.collectionID,
                                                    cases: caseFiles, files: files.sorted { $0.path < $1.path })
        if hasBatch {
            manifest.collection = "requirements/membership.json"
            manifest.batchManifest = "executions/batch-manifest.json"
            manifest.batchResult = "executions/batch-result.json"
        }
        try jsonEncoder.encode(manifest).write(to: staging.appending(path: "manifest.json"),
                                               options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        committed = true
    }

    struct Imported {
        var manifest: IntentEvidenceBundleManifest
        var requirements: IntentEvidenceRequirements
        var cases: [IntentEvidenceBundleCase]
        var collection: ScenarioCollection?
        var batchManifest: ScenarioCollectionBatchManifest?
        var batchResult: ScenarioCollectionBatchResult?
    }

    static func read(_ root: URL) throws -> Imported {
        let manager = FileManager.default
        guard root.pathExtension == "intentlabrun" else {
            throw IntentEvidenceBundleError.invalid("Expected a .intentlabrun directory.")
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw IntentEvidenceBundleError.invalid("Expected a regular .intentlabrun directory.")
        }
        let manifestData = try boundedData(root.appending(path: "manifest.json"))
        let manifest = try jsonDecoder.decode(IntentEvidenceBundleManifest.self, from: manifestData)
        guard manifest.schemaVersion == IntentEvidenceBundleManifest.schemaVersion,
              manifest.policyID == policyID, !manifest.collectionID.isEmpty,
              !manifest.sourceRevision.isEmpty else {
            throw IntentEvidenceBundleError.invalid("Unsupported bundle schema or policy.")
        }
        guard manifest.files.count <= maximumFiles,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              Set(manifest.cases.map(\.caseID)).count == manifest.cases.count,
              (!manifest.cases.isEmpty || manifest.batchManifest != nil) else {
            throw IntentEvidenceBundleError.invalid("Duplicate or excessive manifest entries.")
        }
        // Inspect the tree before reading any manifest-listed path, so a
        // symlinked parent directory cannot redirect a read outside the bundle.
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
        ], options: []) else {
            throw IntentEvidenceBundleError.invalid("Cannot enumerate bundle.")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var actual: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw IntentEvidenceBundleError.invalid("Symlink or special file: \(url.lastPathComponent).")
            }
            if values.isRegularFile == true {
                let relative = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                    .dropFirst(canonicalRoot.pathComponents.count)
                    .joined(separator: "/")
                try validatePath(relative)
                actual.insert(relative)
                guard actual.count <= maximumFiles + 1 else {
                    throw IntentEvidenceBundleError.oversized("file count")
                }
            }
        }
        var listed: Set<String> = ["manifest.json"]
        var total = manifestData.count
        for entry in manifest.files {
            try validatePath(entry.path)
            guard entry.bytes >= 0, entry.bytes <= maximumFileBytes else {
                throw IntentEvidenceBundleError.oversized(entry.path)
            }
            let bytes = try boundedData(root.appending(path: entry.path))
            guard bytes.count == entry.bytes, digest(bytes) == entry.sha256 else {
                throw IntentEvidenceBundleError.invalid("Checksum mismatch: \(entry.path).")
            }
            total += bytes.count
            listed.insert(entry.path)
        }
        guard total <= maximumTotalBytes else { throw IntentEvidenceBundleError.oversized("total bytes") }
        guard actual == listed else {
            throw IntentEvidenceBundleError.invalid(
                "The bundle contains unlisted or missing files: extra=\(actual.subtracting(listed).sorted()), missing=\(listed.subtracting(actual).sorted())."
            )
        }
        func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            guard listed.contains(path) else { throw IntentEvidenceBundleError.invalid("Unlisted reference \(path).") }
            return try jsonDecoder.decode(type, from: boundedData(root.appending(path: path)))
        }
        let requirements: IntentEvidenceRequirements = try decode(IntentEvidenceRequirements.self, "requirements/collection.json")
        guard requirements.schemaVersion == IntentEvidenceRequirements.schemaVersion,
              requirements.collectionID == manifest.collectionID else {
            throw IntentEvidenceBundleError.invalid("Collection metadata mismatch.")
        }
        let source: [String: String] = try decode([String: String].self, "provenance/source.json")
        guard source == ["sourceRevision": manifest.sourceRevision] else {
            throw IntentEvidenceBundleError.invalid("Source provenance mismatch.")
        }
        var cases: [IntentEvidenceBundleCase] = []
        var referenced: Set<String> = ["requirements/collection.json", "provenance/source.json"]
        if listed.contains("report.json") { referenced.insert("report.json") }
        var collection: ScenarioCollection?
        var batchManifest: ScenarioCollectionBatchManifest?
        var batchResult: ScenarioCollectionBatchResult?
        if let collectionPath = manifest.collection,
           let batchPath = manifest.batchManifest,
           let resultPath = manifest.batchResult {
            collection = try decode(ScenarioCollection.self, collectionPath)
            batchManifest = try decode(ScenarioCollectionBatchManifest.self, batchPath)
            batchResult = try decode(ScenarioCollectionBatchResult.self, resultPath)
            try collection!.validate()
            guard batchManifest!.hasValidDigest,
                  batchManifest!.collectionID == collection!.id,
                  batchManifest!.collectionVersion == collection!.version,
                  batchManifest!.membershipDigest == collection!.membershipDigest,
                  requirements.collectionID == collection!.id.uuidString,
                  matchesMembership(collection!, requirements: requirements),
                  batchResult!.id == batchManifest!.id,
                  batchResult!.manifestID == batchManifest!.id else {
                throw IntentEvidenceBundleError.invalid("Collection batch identity or seal is invalid.")
            }
            referenced.formUnion([collectionPath, batchPath, resultPath])
        } else if manifest.collection != nil || manifest.batchManifest != nil || manifest.batchResult != nil {
            throw IntentEvidenceBundleError.invalid("Collection batch metadata is incomplete.")
        }
        for entry in manifest.cases {
            let definition: ScenarioDefinition = try decode(ScenarioDefinition.self, entry.definition)
            let plan: ScenarioExecutionPlan = try decode(ScenarioExecutionPlan.self, entry.plan)
            let record: ScenarioExecutionRecord = try decode(ScenarioExecutionRecord.self, entry.executionRecord)
            guard definition.id == entry.caseID else {
                throw IntentEvidenceBundleError.invalid("Case definition identity mismatch.")
            }
            guard let rebuilt = try? ScenarioExecutionRecord.make(
                plan: plan, records: record.records,
                selectedAssessments: record.selectedAssessments ?? [],
                completedAt: record.completedAt
            ), rebuilt == record else {
                throw IntentEvidenceBundleError.invalid("Terminal record seal or population is invalid.")
            }
            referenced.formUnion([entry.definition, entry.plan, entry.executionRecord])
            let runs: [ScenarioRun] = try entry.runs.map { path in
                referenced.insert(path)
                let run: ScenarioRun = try decode(ScenarioRun.self, path)
                if run.responseAssessments != nil {
                    let assessmentPath = "assessments/\(entry.caseID.uuidString)-\(run.id.uuidString).json"
                    let assessments: [ScenarioResponseAssessment] = try decode([ScenarioResponseAssessment].self, assessmentPath)
                    guard assessments == run.responseAssessments else {
                        throw IntentEvidenceBundleError.invalid("Assessment copy mismatch.")
                    }
                    referenced.insert(assessmentPath)
                }
                for lane in run.laneResults {
                    for artifact in lane.artifacts {
                        let artifactPath = "artifacts/\(artifact.id.uuidString)"
                        guard listed.contains(artifactPath) else {
                            throw IntentEvidenceBundleError.invalid("Referenced artifact is missing.")
                        }
                        let bytes = try boundedData(root.appending(path: artifactPath))
                        guard bytes.count == artifact.byteCount,
                              digest(bytes) == artifact.sha256 else {
                            throw IntentEvidenceBundleError.invalid("Artifact content differs from its saved evidence digest.")
                        }
                        referenced.insert(artifactPath)
                    }
                }
                return run
            }
            let journals: [ScenarioExecutionJournal] = try entry.journals.map { path in
                referenced.insert(path)
                return try decode(ScenarioExecutionJournal.self, path)
            }
            let childCoordinates = record.records.filter { $0.featureChild != nil }
            guard entry.featureChildren.count == childCoordinates.count else {
                throw IntentEvidenceBundleError.invalid("Feature child population is incomplete.")
            }
            for (coordinate, path) in zip(
                childCoordinates.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
                entry.featureChildren.sorted()
            ) {
                let child: ScenarioFeatureChildEvidence = try decode(ScenarioFeatureChildEvidence.self, path)
                guard child == coordinate.featureChild, child.hasValidDigest else {
                    throw IntentEvidenceBundleError.invalid("Feature child does not match its terminal record.")
                }
                referenced.insert(path)
            }
            var selection: ScenarioAssessmentSelectionRecord?
            if let path = entry.captureAssessments {
                let selected: [ScenarioSelectedAssessmentProjection] = try decode(
                    [ScenarioSelectedAssessmentProjection].self, path
                )
                guard selected == record.selectedAssessments else {
                    throw IntentEvidenceBundleError.invalid("Capture-time assessment copy differs from terminal seal.")
                }
                referenced.insert(path)
            } else if record.selectedAssessments != nil {
                throw IntentEvidenceBundleError.invalid("Capture-time selected assessment copy is missing.")
            }
            if let path = entry.selectedAssessment {
                selection = try decode(ScenarioAssessmentSelectionRecord.self, path)
                guard selection!.isBound(to: record) else {
                    throw IntentEvidenceBundleError.invalid("Selected assessment overlay is not bound to the run.")
                }
                referenced.insert(path)
            }
            let selected = selection?.assessments ?? record.selectedAssessments ?? []
            let retained: [ScenarioRetainedAssessmentArtifact] = try entry.retainedAssessments.map { path in
                referenced.insert(path)
                return try decode(ScenarioRetainedAssessmentArtifact.self, path)
            }
            guard Set(selected.map(\.selectedAssessmentID)).count == selected.count,
                  Set(retained.map(\.id)).count == retained.count,
                  Set(selected.map(\.selectedAssessmentID)) == Set(retained.map(\.id)),
                  retained.allSatisfy({ $0.hasValidDigest && selected.contains($0.projection) }) else {
                throw IntentEvidenceBundleError.invalid("Retained assessments do not bind to selected semantic evidence.")
            }
            cases.append(.init(definition: definition, plan: plan, record: record,
                               runs: runs, journals: journals, selectedAssessment: selection,
                               retainedAssessments: retained))
        }
        guard referenced == listed.subtracting(["manifest.json"]) else {
            throw IntentEvidenceBundleError.invalid("Unreferenced evidence file.")
        }
        if let batchManifest, let batchResult {
            guard Set(batchResult.executions.map(\.id)) == Set(cases.map { $0.record.id }),
                  cases.allSatisfy({ item in
                      batchManifest.cases.contains(where: {
                          $0.id == item.definition.id && $0.executionPlanID == item.plan.id
                      }) && Set(item.plan.coordinates.map(\.id)) == Set(
                          batchManifest.coordinates.filter { $0.caseID == item.definition.id }.map(\.id)
                      )
                  }) else {
                throw IntentEvidenceBundleError.invalid("Batch results and exported child cases differ.")
            }
        }
        return .init(manifest: manifest, requirements: requirements, cases: cases,
                     collection: collection, batchManifest: batchManifest, batchResult: batchResult)
    }

    static func decodeRequirements(_ url: URL) throws -> IntentEvidenceRequirements {
        let value = try jsonDecoder.decode(IntentEvidenceRequirements.self, from: boundedData(url))
        guard value.schemaVersion == IntentEvidenceRequirements.schemaVersion,
              !value.collectionID.isEmpty, !value.cases.isEmpty,
              Set(value.cases.map { $0.definition.id }).count == value.cases.count,
              value.cases.allSatisfy({ item in
                  guard item.definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
                        item.definition.hasValidDigest else { return false }
                  let hasSemantic = item.definition.assertions.contains {
                      $0.required && $0.kind == .semanticRubric
                  }
                  if hasSemantic && item.semanticPolicy == nil { return false }
                  guard let policy = item.semanticPolicy else { return true }
                  return isSHA256(policy.scoringContractDigest)
                      && isSHA256(policy.judgePolicyDigest)
                      && (policy.frozenAt.map { $0.isFinite && $0 > 0 } ?? true)
              }) else {
            throw IntentEvidenceBundleError.invalid("Trusted requirements are invalid.")
        }
        return value
    }

    private static func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw IntentEvidenceBundleError.invalid("Expected regular file: \(url.lastPathComponent).")
        }
        guard (values.fileSize ?? maximumFileBytes + 1) <= maximumFileBytes else {
            throw IntentEvidenceBundleError.oversized(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileBytes else {
            throw IntentEvidenceBundleError.oversized(url.lastPathComponent)
        }
        return data
    }

    private static func validatePath(_ path: String) throws {
        guard path.count <= 240, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
              }) else {
            throw IntentEvidenceBundleError.invalid("Unsafe relative path: \(path).")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func matchesMembership(
        _ collection: ScenarioCollection,
        requirements: IntentEvidenceRequirements
    ) -> Bool {
        let byID = Dictionary(grouping: requirements.cases, by: { $0.definition.id })
        return collection.members.count == requirements.cases.count
            && collection.members.allSatisfy { member in
                guard let matches = byID[member.caseID], matches.count == 1 else { return false }
                let definition = matches[0].definition
                return member.version == definition.version
                    && member.definitionDigest == definition.definitionDigest
                    && member.testContractDigest == definition.testContractDigest
            }
    }
}
