import CryptoKit
import Foundation

enum ScenarioExecutorPhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case running
    case cancelling
    case stopped
    case recoveryRequired
}

struct ScenarioExecutionJournal: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { invocation.id }
    var phase: ScenarioExecutorPhase
    var invocation: ScenarioInvocationIdentity
    var scenarioID: UUID
    var scenarioVersion: Int
    var resultBundlePath: String
    var derivedDataPath: String
    var buildLogPath: String
    var intendedExecutable: String
    var intendedArguments: [String]
    var processIdentifier: Int32?
    var processStartedAt: Date?
    var updatedAt: Date
    var recoveryReason: String?
    /// Nil for older or unfinished journals; only true authorizes release evidence.
    var evidenceAccepted: Bool? = nil
    /// v3-only native coordinate; nil retains the historical all-routes test.
    var scope: ScenarioNativeExecutionScope? = nil
    var physicalRunner: ScenarioPhysicalRunnerRecord? = nil
}

struct ScenarioImportLedger: Codable, Equatable, Sendable {
    var importedInvocationIDs: Set<UUID> = []
    var importedNonces: Set<String> = []
    var importedArtifactIDs: Set<UUID> = []

    mutating func record(_ envelope: ScenarioEvidenceEnvelope) {
        importedInvocationIDs.insert(envelope.invocation.id)
        importedNonces.insert(envelope.invocation.nonce)
        importedArtifactIDs.formUnion(envelope.results.flatMap(\.artifacts).map(\.id))
    }
}

struct ScenarioEvidenceImportLimits: Sendable {
    var maximumEnvelopeBytes = 2_000_000
    var maximumArtifactBytes = 20_000_000
    var maximumTotalArtifactBytes = 100_000_000
    var maximumArtifacts = 50
    var maximumLaneResults = 20
}

enum ScenarioEvidenceImportError: LocalizedError, Equatable, Sendable {
    case oversizedEnvelope
    case malformedEnvelope(String)
    case schemaMismatch
    case journalNotActive
    case identityMismatch(String)
    case replayedInvocation
    case invalidTestCount
    case invalidResult(String)
    case invalidArtifact(String)

    var errorDescription: String? {
        switch self {
        case .oversizedEnvelope:
            "The evidence attachment exceeds the configured size limit."
        case .malformedEnvelope(let message):
            "The evidence attachment is malformed: \(message)"
        case .schemaMismatch:
            "The evidence attachment uses an unsupported schema version."
        case .journalNotActive:
            "The evidence does not belong to the active journalled invocation."
        case .identityMismatch(let message):
            "The evidence identity does not match the invocation: \(message)"
        case .replayedInvocation:
            "This invocation or nonce has already been imported. Stale evidence cannot satisfy a new run."
        case .invalidTestCount:
            "The result bundle did not execute the fixed Intent Lab test entry point."
        case .invalidResult(let message):
            "The evidence results are invalid: \(message)"
        case .invalidArtifact(let message):
            "An evidence artifact is invalid: \(message)"
        }
    }
}

struct XCTestEvidenceImporter: Sendable {
    var limits = ScenarioEvidenceImportLimits()

    func decodeEnvelope(from data: Data) throws -> ScenarioEvidenceEnvelope {
        guard data.count <= limits.maximumEnvelopeBytes else {
            throw ScenarioEvidenceImportError.oversizedEnvelope
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ScenarioEvidenceEnvelope.self, from: data)
        } catch {
            throw ScenarioEvidenceImportError.malformedEnvelope(error.localizedDescription)
        }
    }

    func importEvidence(
        data: Data,
        definition: ScenarioDefinition,
        journal: ScenarioExecutionJournal,
        artifactRoot: URL,
        ledger: inout ScenarioImportLedger,
        supplementaryResults: [ScenarioLaneResult] = [],
        statedChangedDimensions: Set<String> = [],
        importedAt: Date = Date(),
        scope: ScenarioNativeExecutionScope? = nil,
        measurementImplementation: ScenarioMeasurementImplementation? = nil
    ) throws -> ScenarioRun {
        try ScenarioValidator.validate(definition)
        guard journal.scope == scope,
              scope == nil || (scope?.isValid(
                  for: definition,
                  featureBackend: journal.invocation.featureBackend ?? .connectedRunner
              ) == true && supplementaryResults.isEmpty) else {
            throw ScenarioEvidenceImportError.identityMismatch("the native route scope differs from its journal")
        }
        let envelope = try decodeEnvelope(from: data)
        let expectedEnvelopeVersion = ScenarioHarnessCapabilities.usesReusableProtocol(definition)
            ? ScenarioEvidenceEnvelope.reusableSchemaVersion : ScenarioEvidenceEnvelope.currentSchemaVersion
        guard envelope.schemaVersion == expectedEnvelopeVersion else {
            throw ScenarioEvidenceImportError.schemaMismatch
        }
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition) {
            let required = ScenarioHarnessCapabilities.required(
                for: definition, scope: scope,
                featureBackend: journal.invocation.featureBackend ?? .connectedRunner
            )
            guard let integration = definition.integration,
                  envelope.integration == integration,
                  envelope.invocation.integration == integration,
                  journal.invocation.integration == integration,
                  envelope.invocation.requiredCapabilities == required.sorted(),
                  journal.invocation.requiredCapabilities == required.sorted(),
                  let packageVersion = envelope.runnerPackageVersion,
                  !packageVersion.isEmpty, packageVersion.count <= 64,
                  let negotiated = envelope.negotiatedCapabilities,
                  Set(negotiated).count == negotiated.count,
                  required.isSubset(of: Set(negotiated)) else {
                throw ScenarioEvidenceImportError.identityMismatch(
                    "integration declaration, runner package, or negotiated capabilities differ"
                )
            }
        } else if envelope.integration != nil || envelope.runnerPackageVersion != nil
                    || envelope.negotiatedCapabilities != nil
                    || envelope.invocation.integration != nil
                    || envelope.invocation.requiredCapabilities != nil {
            throw ScenarioEvidenceImportError.schemaMismatch
        }
        guard journal.phase == .running || journal.phase == .cancelling || journal.phase == .stopped else {
            throw ScenarioEvidenceImportError.journalNotActive
        }
        if scope?.lane == .appFeature {
            guard journal.invocation.featureBackend == .projectLocalTestControl else {
                throw ScenarioEvidenceImportError.identityMismatch("the local Feature backend was not frozen in the native invocation")
            }
        } else if journal.invocation.featureBackend != nil {
            throw ScenarioEvidenceImportError.identityMismatch("a non-Feature route claimed a Feature backend")
        }
        try validateIdentity(envelope, definition: definition, journal: journal)
        if let measurementImplementation {
            guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
                  let testProduct = journal.invocation.testProduct,
                  measurementImplementation.hasCompleteProvenance,
                  measurementImplementation
                    == XcodeTestExecutor.measurementImplementation(testProduct: testProduct) else {
                throw ScenarioEvidenceImportError.identityMismatch(
                    "observer or host evaluator executable provenance is unverified"
                )
            }
        }
        guard !ledger.importedInvocationIDs.contains(envelope.invocation.id),
              !ledger.importedNonces.contains(envelope.invocation.nonce) else {
            throw ScenarioEvidenceImportError.replayedInvocation
        }
        guard envelope.testCount == 1 else { throw ScenarioEvidenceImportError.invalidTestCount }
        var results = supplementaryResults + envelope.results
        if definition.actionRequirements != nil {
            for index in results.indices where results[index].actionReceipts == nil {
                guard let rawValue = results[index].observations["intentlab.actionReceipts"] else { continue }
                guard case .string(let rawJSON) = rawValue else {
                    throw ScenarioEvidenceImportError.invalidResult("the raw app action record is not text")
                }
                guard rawJSON.utf8.count <= 65_536,
                      let transport = results[index].observationSources?["intentlab.actionReceipts"],
                      transport == .accessibleUI || transport == .testOnlyIntent else {
                    throw ScenarioEvidenceImportError.invalidResult("the raw app action record has no bounded observation provenance")
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let receipts = try? decoder.decode(
                    [ScenarioActionReceipt].self, from: Data(rawJSON.utf8)
                ), receipts.count <= 16 else {
                    throw ScenarioEvidenceImportError.invalidResult("the raw app action record is malformed or exceeds the limit")
                }
                results[index].actionReceipts = receipts
                let verdict = ScenarioResultEvaluator.actionVerdict(
                    definition: definition, lane: results[index].lane,
                    attempt: results[index].attempt, invocation: journal.invocation,
                    receipts: receipts
                )
                if verdict.0 == .failed, results[index].executionStatus == .completed {
                    results[index].outcome = .failed
                    results[index].actionFailureReason = verdict.1
                    results[index].diagnostic = verdict.1?.rawValue
                }
            }
            for index in results.indices where results[index].executionStatus == .completed {
                let result = results[index]
                let action = ScenarioResultEvaluator.actionVerdict(
                    definition: definition, lane: result.lane, attempt: result.attempt,
                    invocation: journal.invocation, receipts: result.actionReceipts
                )
                guard action.0 == .passed else { continue }
                let evaluated = ScenarioResultEvaluator.evaluate(
                    definition: definition, lane: result.lane,
                    observations: result.observations, executionStatus: result.executionStatus,
                    beforeObservations: result.beforeObservations,
                    actionReceipts: result.actionReceipts, invocation: journal.invocation,
                    attempt: result.attempt
                )
                let wrongOutcome = evaluated.1.contains { check in
                    !check.passed && definition.assertions.contains {
                        $0.id == check.assertionID && $0.required
                            && $0.kind != .semanticRubric && $0.applies(to: result.lane)
                    }
                }
                if wrongOutcome {
                    results[index].outcome = .failed
                    let reason = ScenarioResultEvaluator.failureReason(
                        action: action, deterministicFailure: true
                    )
                    results[index].actionFailureReason = reason
                    results[index].diagnostic = reason?.rawValue
                }
            }
        }
        try validateResults(results, definition: definition, scope: scope, invocation: journal.invocation)
        try validateArtifacts(results.flatMap(\.artifacts), root: artifactRoot, ledger: ledger)

        // A coordinate import is evidence for one route attempt. Only the
        // coordinator can qualify the complete selected run after combining
        // independently bound invocations.
        let overall: ScenarioOutcome = scope == nil
            ? ScenarioResultEvaluator.overall(definition: definition, laneResults: results)
            : .notObserved
        let executionStatus: ScenarioExecutionStatus = results.allSatisfy { $0.executionStatus == .completed }
            ? .completed
            : results.first(where: { $0.executionStatus != .completed })?.executionStatus ?? .invalidEvidence
        let startedAt = results.map(\.startedAt).min() ?? envelope.invocation.issuedAt
        let completedAt = results.map(\.completedAt).max() ?? importedAt
        var run = ScenarioRun(
            id: envelope.invocation.id,
            scenarioID: definition.id,
            scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest,
            invocation: envelope.invocation,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: envelope.environment,
            executionStatus: executionStatus,
            outcome: overall,
            laneResults: results,
            linkedFeatureRunID: definition.directControl.linkedFeatureRunID,
            importedAt: importedAt,
            fixture: definition.fixture,
            statedChangedDimensions: statedChangedDimensions
        )
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition) {
            run.integration = envelope.integration
            run.runnerPackageVersion = envelope.runnerPackageVersion
            run.negotiatedCapabilities = envelope.negotiatedCapabilities?.sorted()
        }
        if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            // This metadata comes from the validated frozen host contract, not
            // the v2 consumer wire. Observer and environment provenance remain
            // unknown until separately verified; a bundle hash is not enough.
            run.scenarioSchemaVersion = definition.schemaVersion
            run.testContractDigest = definition.testContractDigest
            run.measurementImplementation = measurementImplementation
            run.executedTestCount = envelope.testCount
        }
        ledger.record(envelope)
        return run
    }

    private func validateIdentity(
        _ envelope: ScenarioEvidenceEnvelope,
        definition: ScenarioDefinition,
        journal: ScenarioExecutionJournal
    ) throws {
        if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            guard journal.scenarioID == definition.id,
                  journal.scenarioVersion == definition.version,
                  !journal.resultBundlePath.isEmpty,
                  URL(filePath: journal.resultBundlePath).lastPathComponent
                    == journal.invocation.resultBundleIdentity,
                  journal.invocation.testIdentity.className == "IntentLabScenarioTests",
                  journal.invocation.testIdentity.methodName == "testIntentLabScenario" else {
                throw ScenarioEvidenceImportError.identityMismatch(
                    "the journal does not bind this case, result bundle, and fixed test entry point"
                )
            }
        }
        guard envelope.invocation.id == journal.invocation.id,
              envelope.invocation.nonce == journal.invocation.nonce,
              envelope.invocation.resultBundleIdentity == journal.invocation.resultBundleIdentity else {
            throw ScenarioEvidenceImportError.identityMismatch("invocation ID, nonce, or result-bundle identity differs")
        }
        guard envelope.invocation.scenarioDigest == definition.definitionDigest,
              envelope.invocation.scenarioDigest == journal.invocation.scenarioDigest else {
            throw ScenarioEvidenceImportError.identityMismatch("scenario digest differs")
        }
        let expectedHarnessVersion = ScenarioHarnessCapabilities.usesReusableProtocol(definition)
            ? ScenarioInvocationIdentity.reusableHarnessVersion : ScenarioInvocationIdentity.currentHarnessVersion
        guard envelope.invocation.testIdentity == journal.invocation.testIdentity,
              envelope.invocation.harnessVersion == expectedHarnessVersion,
              envelope.invocation.featureBackend == journal.invocation.featureBackend else {
            throw ScenarioEvidenceImportError.identityMismatch("test entry point or harness version differs")
        }
        let expectedDestination = definition.schemaVersion == ScenarioDefinition.stableSchemaVersion
            ? journal.invocation.destinationIdentifier : definition.target.destinationIdentifier
        guard !expectedDestination.isEmpty,
              envelope.invocation.destinationIdentifier == expectedDestination,
              envelope.invocation.destinationIdentifier == journal.invocation.destinationIdentifier else {
            throw ScenarioEvidenceImportError.identityMismatch("selected destination differs")
        }
        guard envelope.sourceBundleIdentifier == definition.target.bundleIdentifier,
              envelope.observedAppProduct.bundleIdentifier == definition.target.bundleIdentifier else {
            throw ScenarioEvidenceImportError.identityMismatch("application bundle identifier differs")
        }
        guard let expectedApp = journal.invocation.appProduct,
              let expectedTest = journal.invocation.testProduct else {
            throw ScenarioEvidenceImportError.identityMismatch("host product fingerprints were not journalled before launch")
        }
        guard envelope.observedAppProduct == expectedApp,
              envelope.observedTestProduct == expectedTest,
              envelope.invocation.appProduct == expectedApp,
              envelope.invocation.testProduct == expectedTest else {
            throw ScenarioEvidenceImportError.identityMismatch("built product fingerprints differ")
        }
    }

    private func validateResults(
        _ results: [ScenarioLaneResult],
        definition: ScenarioDefinition,
        scope: ScenarioNativeExecutionScope?,
        invocation: ScenarioInvocationIdentity
    ) throws {
        guard !results.isEmpty, results.count <= limits.maximumLaneResults else {
            throw ScenarioEvidenceImportError.invalidResult("the result count is empty or exceeds the limit")
        }
        if let scope {
            guard results.count == 1,
                  results[0].lane == scope.lane,
                  results[0].attempt == scope.attempt else {
                throw ScenarioEvidenceImportError.invalidResult(
                    "the scoped invocation must contain exactly its selected route and attempt"
                )
            }
        }
        let coordinates = results.map { "\($0.caseID.uuidString):\($0.lane.rawValue):\($0.attempt)" }
        guard Set(coordinates).count == coordinates.count else {
            throw ScenarioEvidenceImportError.invalidResult("duplicate case, lane, and attempt coordinates")
        }
        for result in results {
            if ScenarioHarnessCapabilities.usesReusableProtocol(definition),
               definition.coverage[result.lane] == .notApplicable {
                throw ScenarioEvidenceImportError.invalidResult("a not-applicable lane supplied evidence")
            }
            let assertionIDs = result.assertionResults.map(\.assertionID)
            guard Set(assertionIDs).count == assertionIDs.count else {
                throw ScenarioEvidenceImportError.invalidResult("duplicate assertion IDs")
            }
            guard result.caseID == definition.id, result.attempt > 0 else {
                throw ScenarioEvidenceImportError.invalidResult("a result has the wrong case ID or attempt number")
            }
            guard result.completedAt >= result.startedAt else {
                throw ScenarioEvidenceImportError.invalidResult("a result completes before it starts")
            }
            if scope?.lane == .appFeature {
                guard let binding = definition.featureBinding,
                      ScenarioValidator.validLocalFeatureObservations(result, binding: binding) else {
                    throw ScenarioEvidenceImportError.invalidResult(
                        "local Feature output lacks the declared typed test-intent provenance"
                    )
                }
            }
            if definition.actionRequirements != nil, let receipts = result.actionReceipts {
                guard receipts.count <= 16,
                      ScenarioResultEvaluator.actionObservationIsConsistent(result) else {
                    throw ScenarioEvidenceImportError.invalidResult(
                        "action receipts differ from bounded app observations or transport provenance"
                    )
                }
            }
            if result.outcome == .passed {
                guard result.executionStatus == .completed else {
                    throw ScenarioEvidenceImportError.invalidResult("a non-completed execution is marked passed")
                }
                let requiredIDs = Set(definition.assertions.filter {
                    $0.required && $0.applies(to: result.lane)
                }.map(\.id))
                let assertionByID = Dictionary(uniqueKeysWithValues: result.assertionResults.map { ($0.assertionID, $0) })
                guard requiredIDs.allSatisfy({ assertionByID[$0]?.passed == true }) else {
                    throw ScenarioEvidenceImportError.invalidResult("a pass is missing a successful required assertion")
                }
            }
            let evaluated = ScenarioResultEvaluator.evaluate(
                definition: definition,
                lane: result.lane,
                observations: result.observations,
                executionStatus: result.executionStatus,
                beforeObservations: definition.schemaVersion == ScenarioDefinition.stableSchemaVersion
                    ? result.beforeObservations : nil,
                actionReceipts: result.actionReceipts,
                invocation: invocation,
                attempt: result.attempt
            )
            if result.outcome == .passed, evaluated.0 != .passed {
                throw ScenarioEvidenceImportError.invalidResult("a claimed pass conflicts with the captured observations")
            }
            if ScenarioHarnessCapabilities.usesReusableProtocol(definition),
               result.outcome == .passed,
               result.lane != .appFeature {
                guard let claims = result.claims,
                      Set(claims).count == claims.count,
                      claims.contains(.executionCompleted) else {
                    throw ScenarioEvidenceImportError.invalidResult("a pass lacks distinct execution proof claims")
                }
                for claim in claims {
                    if result.lane == .siri && claim == .executionCompleted { continue }
                    guard ScenarioResultEvaluator.verifiedClaim(claim, definition: definition, result: result) else {
                        throw ScenarioEvidenceImportError.invalidResult("a claimed pass lacks verified \(claim.rawValue) evidence")
                    }
                }
                if result.lane == .intentIntegration {
                    for claim in definition.requiredClaims ?? [] {
                        guard ScenarioResultEvaluator.verifiedClaim(claim, definition: definition, result: result) else {
                            throw ScenarioEvidenceImportError.invalidResult("a claimed pass lacks verified \(claim.rawValue) evidence")
                        }
                    }
                } else if result.lane == .siri,
                          !ScenarioResultEvaluator.verifiedClaim(
                              .applicationStateChecked, definition: definition, result: result
                          ) {
                    throw ScenarioEvidenceImportError.invalidResult("a Siri pass lacks verified final-state evidence")
                }
            }
        }
        if scope == nil {
            for lane in ScenarioLane.allCases where definition.coverage[lane] == .required {
                guard results.contains(where: { $0.lane == lane }) else {
                    throw ScenarioEvidenceImportError.invalidResult("required lane \(lane.rawValue) is missing")
                }
            }
        }
        if scope == nil && definition.coverage.siri != .notApplicable {
            let expected = definition.coverage.siriAttemptCount ?? 3
            let attempts = results.filter { $0.lane == .siri }.map(\.attempt).sorted()
            if definition.coverage.siri == .required,
               attempts != Array(1...expected) {
                throw ScenarioEvidenceImportError.invalidResult(
                    "the Siri lane must retain attempts 1 through \(expected) in order"
                )
            }
        }
    }


    private func validateArtifacts(
        _ artifacts: [ScenarioArtifactReference],
        root: URL,
        ledger: ScenarioImportLedger
    ) throws {
        guard artifacts.count <= limits.maximumArtifacts else {
            throw ScenarioEvidenceImportError.invalidArtifact("too many artifacts")
        }
        guard Set(artifacts.map(\.id)).count == artifacts.count else {
            throw ScenarioEvidenceImportError.invalidArtifact("duplicate artifact identifiers")
        }
        guard artifacts.allSatisfy({ !ledger.importedArtifactIDs.contains($0.id) }) else {
            throw ScenarioEvidenceImportError.invalidArtifact("an artifact identifier was replayed")
        }
        let total = artifacts.reduce(0) { partial, artifact in
            let (sum, overflowed) = partial.addingReportingOverflow(artifact.byteCount)
            return overflowed ? Int.max : sum
        }
        guard total <= limits.maximumTotalArtifactBytes else {
            throw ScenarioEvidenceImportError.invalidArtifact("combined artifact size exceeds the limit")
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        for artifact in artifacts {
            guard artifact.byteCount >= 0, artifact.byteCount <= limits.maximumArtifactBytes else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) exceeds the per-file size limit")
            }
            let relative = artifact.relativePath
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) uses an unsafe path")
            }
            let url = resolvedRoot.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
            let rootComponents = resolvedRoot.pathComponents
            guard Array(url.pathComponents.prefix(rootComponents.count)) == rootComponents else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) escapes the import directory")
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.fileSize == artifact.byteCount else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) is missing or has a different size")
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) could not be read")
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == artifact.sha256 else {
                throw ScenarioEvidenceImportError.invalidArtifact("\(artifact.filename) failed its digest check")
            }
        }
    }
}
