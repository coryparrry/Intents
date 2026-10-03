import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioSavedExecutionReportTests {
    private struct Fixture {
        var definition: ScenarioDefinition
        var plan: ScenarioExecutionPlan
        var record: ScenarioExecutionRecord
        var run: ScenarioRun
        var journal: ScenarioExecutionJournal
        var policy: ScenarioFrozenSemanticPolicy
        var selection: ScenarioAssessmentSelectionRecord
    }

    private func savedFixture(root: URL, semanticOnlyFeature: Bool = false, siriOnlySummary: Bool = false,
                              response: String = "A summary", directState: String = "packing-001") async throws -> Fixture {
        var definition = ScenarioDefinition.starter()
        definition.target.destinationIdentifier = "simulator"
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .required, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: 1)
        definition.fixture.digest = String(repeating: "c", count: 64)
        definition.integration = .init(id: "notes", version: "1", digest: String(repeating: "e", count: 64))
        definition.featureBinding = .init(featureID: "summarize", interfaceDigest: String(repeating: "7", count: 64),
                                          inputMapping: [], outputProjections: [])
        definition.actionPolicyVersion = 1
        if siriOnlySummary { definition.directControl.intentIdentifier = "SummarizeNoteIntent" }
        let enteredParameters = Dictionary(uniqueKeysWithValues: definition.directControl.parameters.compactMap {
            parameter -> (String, ScenarioValue)? in
            guard case .value(let value) = parameter.presence else { return nil }
            return (parameter.name, value)
        })
        definition.actionRequirements = [.init(lane: .appFeature, kind: .productionService,
                                               operationID: "SummarizeService", resolvedParameters: [:]),
                                               .init(lane: .intentIntegration, kind: .productionIntent,
                                                     operationID: "OpenNoteIntent", resolvedParameters: enteredParameters)]
        definition.assertions = [
            .init(kind: .returnedField, observationKey: "feature.response", expectedValue: .string("A summary"),
                  explanation: "Return the requested summary.", applicableLanes: [.appFeature]),
            .init(kind: .semanticRubric, observationKey: "feature.response", expectedValue: .string("A summary"),
                  explanation: "exact: \"A summary\"", applicableLanes: [.appFeature])
        ]
        definition.assertions.append(.init(kind: .returnedField, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"), explanation: "Open the requested note.", applicableLanes: [.intentIntegration]))
        definition.directControl.outputFields[0].path = [.init(kind: .property, name: "selectedNoteID")]
        definition.observationPlan = [
            .init(id: "feature.response", source: .testOnlyIntent, operationID: "SummarizeService", selector: nil),
            .init(id: "selectedNoteID", source: .intentResult, operationID: nil, selector: nil)
        ]
        definition.purpose = .releaseRequirement
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        if semanticOnlyFeature {
            definition.assertions.removeAll { $0.kind == .returnedField && $0.applies(to: .appFeature) }
            definition.assertions[1].kind = .stateTransition
            definition.observationPlan?[1].source = .uiElement
            definition.observationPlan?[1].selector = "selected-note"
            definition.checkMode = .behaviour
            definition.requiredClaims = [.executionCompleted, .applicationStateChecked]
        }
        if siriOnlySummary {
            definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .notApplicable,
                                        siri: .required, siriAttemptCount: 1)
            definition.featureBinding = nil
            definition.goal.requestText = "Summarize the packing note in Intent Lab Fixture"
            definition.checkMode = .behaviour
            definition.requiredClaims = [.executionCompleted, .applicationStateChecked]
            definition.actionRequirements = [.init(lane: .siri, kind: .productionIntent,
                operationID: "SummarizeNoteIntent", resolvedParameters: enteredParameters)]
            definition.assertions.removeAll { $0.kind != .semanticRubric }
            definition.assertions[0].observationKey = "summaryText"
            definition.assertions[0].applicableLanes = [.siri]
            definition.assertions.append(.init(kind: .entityIdentifier, observationKey: "selectedNoteID",
                expectedValue: .string("packing-001"), explanation: "Use the requested note.", applicableLanes: [.siri]))
            definition.assertions.append(.init(kind: .noMutation, observationKey: "mutationCount",
                expectedValue: .integer(0), explanation: "Preserve the note store.", applicableLanes: [.siri]))
            definition.observationPlan = [
                .init(id: "summaryText", source: .uiElement, selector: "summary"),
                .init(id: "selectedNoteID", source: .uiElement, selector: "selected-note"),
                .init(id: "mutationCount", source: .uiElement, selector: "mutation-count")
            ]
        }
        definition = try definition.frozen()
        let persistence = ScenarioPersistence(rootDirectory: root)
        try await persistence.saveDefinition(definition)
        let judge = EvaluationResolvedJudgeConnection(connection: .init(
            id: UUID(), name: "Fixture judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "fixture"), apiKey: nil)
        var configuration = EvaluationJudgeConfiguration()
        configuration.mode = .connection
        configuration.connectionID = judge.connection.id
        configuration.externalEvidenceApprovedAt = Date()
        configuration.approvedConnectionID = judge.connection.id
        configuration.approvedConnectionDigest = judge.connection.disclosureDigest
        configuration.approvedIncludeReferenceAttachments = configuration.includeReferenceAttachments
        let semantic = try #require(definition.assertions.first { $0.kind == .semanticRubric })
        let policy = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: semantic.id, configuration: configuration, resolvedJudge: judge)
        let assessments = ScenarioAssessmentStore(directory: root.appending(path: "Assessments"))
        try await assessments.freezeSemanticPolicy(policy, definition: definition)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let profile = ScenarioExecutionProfile(id: UUID(), projectPath: "fixture", scheme: "Fixture",
            testTarget: "FixtureUITests", destinationIdentifier: "simulator", signingSelection: nil,
            featureBackend: .projectLocalTestControl)
        let plan = try ScenarioExecutionPlan.make(definition: definition, profile: profile,
            appProductDigest: String(repeating: "a", count: 64), testProductDigest: String(repeating: "b", count: 64),
            sourceInputsDigest: String(repeating: "d", count: 64), sourceRevision: "fixture-revision",
            runnerBuildID: nil, runnerID: nil, createdAt: now)
        try await persistence.savePlan(plan)
        let route: ScenarioLane = siriOnlySummary ? .siri : .appFeature
        let responseKey = siriOnlySummary ? "summaryText" : "feature.response"
        let transport: ScenarioObservationSource = siriOnlySummary ? .accessibleUI : .testOnlyIntent
        let coordinate = try #require(plan.coordinates.first { $0.lane == route })
        let capabilities = ScenarioHarnessCapabilities.required(for: definition,
            scope: .init(lane: route, attempt: 1), featureBackend: .projectLocalTestControl).sorted()
        let invocation = ScenarioInvocationIdentity(id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "fixture.tests", className: "Fixture", methodName: "testFeature"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion, destinationIdentifier: "simulator",
            scenarioDigest: definition.definitionDigest, resultBundleIdentity: UUID().uuidString,
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier, executableName: "Fixture", sha256: plan.appProductDigest),
            testProduct: .init(bundleIdentifier: "fixture.tests", executableName: "FixtureTests", sha256: plan.testProductDigest),
            integration: definition.integration, requiredCapabilities: capabilities,
            featureBackend: siriOnlySummary ? nil : .projectLocalTestControl)
        let action = try #require(definition.actionRequirements?.first)
        let receipt = ScenarioActionReceipt(executionID: UUID(), appSessionID: UUID(),
            attemptContext: siriOnlySummary ? "siri-\(invocation.id.uuidString)-1" : "feature-\(invocation.id.uuidString)",
            lane: route, attempt: 1,
            kind: action.kind, operationID: action.operationID, resolvedParameters: action.resolvedParameters,
            terminalStatus: .succeeded, operationError: nil, sequence: 1, startedAt: now, completedAt: now,
            observationTransport: transport)
        var observations: [String: ScenarioValue] = [responseKey: .string(response),
            "intentlab.actionReceipts": .string(String(decoding: try CanonicalJSON.data(for: [receipt], prettyPrinted: false), as: UTF8.self))]
        let before: [String: ScenarioValue]? = siriOnlySummary ? ["mutationCount": .integer(0)] : nil
        if siriOnlySummary {
            observations["selectedNoteID"] = .string(directState)
            observations["mutationCount"] = .integer(0)
        }
        let evaluated = ScenarioResultEvaluator.evaluate(definition: definition, lane: route,
            observations: observations, executionStatus: .completed, beforeObservations: before,
            actionReceipts: [receipt], invocation: invocation, attempt: 1)
        var sources = Dictionary(uniqueKeysWithValues: observations.keys.map { ($0, transport) })
        sources["intentlab.actionReceipts"] = transport
        let lane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: route,
            executionStatus: .completed, outcome: semanticOnlyFeature ? .notObserved : evaluated.0, startedAt: now, completedAt: now,
            observations: observations, assertionResults: evaluated.1,
            observationSources: sources,
            claims: siriOnlySummary ? [.executionCompleted, .applicationStateChecked] : [.executionCompleted],
            beforeObservations: before, actionReceipts: [receipt], cleanupVerified: true)
        var run = ScenarioRun(id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation, startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "fixture", operatingSystem: "fixture",
                operatingSystemBuild: nil, languageCode: "en", regionCode: "GB", timeZoneIdentifier: "UTC",
                siriConfiguration: nil, siriConfigurationSource: nil, executedAt: now),
            executionStatus: .completed, outcome: lane.outcome, laneResults: [lane], linkedFeatureRunID: nil,
            importedAt: now, xctestExitCode: 0, fixture: definition.fixture,
            scenarioSchemaVersion: ScenarioDefinition.stableSchemaVersion, testContractDigest: definition.testContractDigest,
            executedTestCount: 1)
        run.integration = definition.integration
        run.runnerPackageVersion = "fixture-package"
        run.negotiatedCapabilities = capabilities
        run.measurementImplementation = .init(observerID: "fixture-observer", observerDigest: plan.testProductDigest,
                                              evaluatorID: "fixture-evaluator", evaluatorDigest: plan.testProductDigest)
        run.comparisonEnvironmentIdentity = .init(profileID: "fixture", profileDigest: String(repeating: "f", count: 64))
        let journal = ScenarioExecutionJournal(phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "fixture.xcresult", derivedDataPath: "fixture",
            buildLogPath: "fixture.log", intendedExecutable: "xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: now, updatedAt: now, recoveryReason: nil,
            evidenceAccepted: true, scope: .init(lane: route, attempt: 1))
        run = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveJournal(journal)
        try await persistence.saveLedger(.init(importedInvocationIDs: [run.id], importedNonces: [invocation.nonce]))
        run = try await persistence.acceptRun(run, journal: journal)
        let terminal = ScenarioExecutionCoordinateRecord(coordinate: coordinate, state: .completed,
            evidenceRunID: run.id, evidenceLaneResultID: lane.id, detail: nil, laneResult: lane,
            evidenceDigest: try nativeRunDigest(run))
        var terminals = [terminal]
        var savedRuns = [run]
        var savedJournals = [journal]
        if !siriOnlySummary {
            var directInvocation = invocation
            directInvocation.id = UUID()
            directInvocation.nonce = UUID().uuidString
            directInvocation.resultBundleIdentity = UUID().uuidString
            directInvocation.featureBackend = nil
            directInvocation.requiredCapabilities = ScenarioHarnessCapabilities.required(
                for: definition, scope: .init(lane: .intentIntegration, attempt: 1),
                featureBackend: .projectLocalTestControl).sorted()
            var directReceipt = receipt
            directReceipt.executionID = UUID()
            directReceipt.attemptContext = "intent-\(directInvocation.id.uuidString)"
            directReceipt.lane = .intentIntegration
            directReceipt.kind = .productionIntent
            directReceipt.operationID = "OpenNoteIntent"
            directReceipt.resolvedParameters = enteredParameters
            let directObservations: [String: ScenarioValue] = ["selectedNoteID": .string(directState),
                "intentlab.actionReceipts": .string(String(decoding: try CanonicalJSON.data(for: [directReceipt], prettyPrinted: false), as: UTF8.self))]
            let directEvaluated = ScenarioResultEvaluator.evaluate(definition: definition, lane: .intentIntegration,
                observations: directObservations, executionStatus: .completed, actionReceipts: [directReceipt],
                invocation: directInvocation, attempt: 1)
            let directLane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .intentIntegration,
                executionStatus: .completed, outcome: directEvaluated.0, startedAt: now, completedAt: now,
                observations: directObservations, assertionResults: directEvaluated.1,
                observationSources: ["selectedNoteID": semanticOnlyFeature ? .accessibleUI : .appIntentsTesting,
                                     "intentlab.actionReceipts": .testOnlyIntent],
                claims: [.executionCompleted, semanticOnlyFeature ? .applicationStateChecked : .returnedValueChecked],
                actionReceipts: [directReceipt], cleanupVerified: true)
            var directRun = run
            directRun.id = directInvocation.id
            directRun.invocation = directInvocation
            directRun.laneResults = [directLane]
            directRun.outcome = directEvaluated.0
            directRun.negotiatedCapabilities = directInvocation.requiredCapabilities
            directRun = try await persistence.saveRun(directRun, artifactRoot: nil)
            var directJournal = journal
            directJournal.invocation = directInvocation
            directJournal.scope = .init(lane: .intentIntegration, attempt: 1)
            try await persistence.saveJournal(directJournal)
            try await persistence.saveLedger(.init(importedInvocationIDs: [run.id, directRun.id],
                                                  importedNonces: [invocation.nonce, directInvocation.nonce]))
            directRun = try await persistence.acceptRun(directRun, journal: directJournal)
            let directCoordinate = try #require(plan.coordinates.first { $0.lane == .intentIntegration })
            let directTerminal = ScenarioExecutionCoordinateRecord(coordinate: directCoordinate, state: .completed,
                evidenceRunID: directRun.id, evidenceLaneResultID: directLane.id, detail: nil, laneResult: directLane,
                evidenceDigest: try nativeRunDigest(directRun))
            terminals.append(directTerminal)
            savedRuns.append(directRun)
            savedJournals.append(directJournal)
        }
        let record = try ScenarioExecutionRecord.make(plan: plan, records: terminals, completedAt: now)
        try await persistence.saveExecutionRecord(record)
        // The exact-text criterion is evaluated locally. No model or endpoint is invoked.
        let assessment = try await ScenarioIndependentAssessmentService.assess(
            .init(scenarioRunID: run.id, laneResult: lane, assertion: semantic, effectiveInput: definition.goal.requestText,
                  verifiedReference: "A summary", judgeConfiguration: configuration), resolvedJudge: nil)
        #expect(assessment.sample?.status == (response == "A summary" ? .passed : .failed))
        if siriOnlySummary {
            try await assessments.append(assessment, for: run, definition: definition)
        } else {
            try await assessments.appendFeature(assessment, for: record, definition: definition,
                nativeEvidence: .init(plan: plan, run: run, journal: journal))
        }
        let selection = try await assessments.sealSelection(executionRecord: record, runs: savedRuns,
            definition: definition, plan: plan, journals: savedJournals)
        return .init(definition: definition, plan: plan, record: record, run: run, journal: journal,
                     policy: policy, selection: selection)
    }

    @Test func siriOnlyTypedSummaryQualifiesWithFrozenLocalAssessmentWithoutNativeOrModelRerun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await savedFixture(root: root, siriOnlySummary: true)
        #expect(fixture.run.laneResults[0].outcome == .needsReview)
        #expect(fixture.run.laneResults[0].lane == .siri)
        let before = try fileSnapshot(root)
        let service = ScenarioSavedExecutionReportService(rootDirectory: root)
        let qualification = try await service.qualification(executionID: fixture.record.id)
        #expect(qualification.incompleteEvidence.isEmpty)
        #expect(qualification.requiredFailures.isEmpty)
        #expect(qualification.report?.outcome == .passed)
        #expect(try fileSnapshot(root) == before)
    }

    @MainActor
    @Test(arguments: [false, true])
    func guiMCPAndOfflineQualifyTheSameSavedSemanticSelectionWithoutWrites(semanticOnlyFeature: Bool) async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = EvaluationStore(supportDirectory: support)
        let root = store.overviewStorageDirectory.appending(path: "IntentLab")
        let fixture = try await savedFixture(root: root, semanticOnlyFeature: semanticOnlyFeature)
        if semanticOnlyFeature {
            #expect(fixture.run.laneResults[0].outcome == .notObserved)
            #expect(fixture.run.laneResults[0].claims == [.executionCompleted])
        }
        let service = ScenarioSavedExecutionReportService(rootDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: store.overviewStorageDirectory, evaluationStore: store,
                                              executionAdmission: ScenarioExecutionAdmission())
        await coordinator.load()
        coordinator.selectedExecutionID = fixture.record.id
        let before = try fileSnapshot(root)
        let qualification = try await service.qualification(executionID: fixture.record.id)
        #expect(qualification.incompleteEvidence.isEmpty)
        #expect(qualification.requiredFailures.isEmpty)
        #expect(qualification.report?.outcome == .passed)
        let response = await MCPStoreAuthority.make(store: store).call(.getScenarioExecutionReport(.init(executionID: fixture.record.id)))
        #expect(!response.isError)
        let mcpDecision = try #require(response.structuredContent.objectValue?["qualification"])
        #expect(mcpDecision.objectValue?["incompleteEvidence"] == .array([]))
        #expect(mcpDecision.objectValue?["requiredFailures"] == .array([]))
        let gui = try #require(await coordinator.qualificationForSelectedExecution())
        #expect(gui.report?.outcome == qualification.report?.outcome)
        var artifacts: [UUID: Data] = [:]
        let item = try await service.bundleCase(definition: fixture.definition, plan: fixture.plan,
            record: fixture.record, artifacts: &artifacts)
        let trusted = IntentEvidenceRequirements(collectionID: "fixture",
            cases: [try await service.evidenceRequirement(definition: fixture.definition)])
        let bundle = support.appending(path: "fixture.intentlabrun")
        try IntentEvidenceBundle.export(.init(requirements: trusted, cases: [item],
            sourceRevision: "fixture-revision", artifactBytes: artifacts), to: bundle)
        let offline = try IntentEvidenceQualification.check(imported: IntentEvidenceBundle.read(bundle), trusted: trusted,
            expectedSource: "fixture-revision", expectedAppDigest: fixture.plan.appProductDigest, referenceTime: Date())
        #expect(offline.requirementsMet)
        let requirementsURL = support.appending(path: "trusted-requirements.json")
        try CanonicalJSON.data(for: trusted, prettyPrinted: false).write(to: requirementsURL)
        let cli = try IntentEvidenceChecker.check(bundle: bundle, requirements: requirementsURL,
            expectedSource: "fixture-revision", expectedAppDigest: fixture.plan.appProductDigest,
            policy: IntentEvidenceChecker.policyID, referenceTime: Date())
        #expect(cli.exitCode == 0)
        #expect(try fileSnapshot(root) == before)
    }

    @Test(arguments: ["semantic", "direct"])
    func scoredSemanticEvidenceCannotOverrideARequiredFailure(failingLane: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await savedFixture(root: root, semanticOnlyFeature: true,
            response: failingLane == "semantic" ? "Wrong summary" : "A summary",
            directState: failingLane == "direct" ? "wrong-note" : "packing-001")
        let before = try fileSnapshot(root)
        let decision = try await ScenarioSavedExecutionReportService(rootDirectory: root)
            .qualification(executionID: fixture.record.id)
        #expect(!decision.requiredFailures.isEmpty)
        #expect(decision.incompleteEvidence.isEmpty)
        #expect(decision.report?.outcome == .failed)
        #expect(try fileSnapshot(root) == before)
    }

    @Test(arguments: ["output", "receipt", "cleanup"])
    func scoredSemanticEvidenceCannotOverrideTamperedNativeEvidence(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await savedFixture(root: root, semanticOnlyFeature: true)
        let runURL = root.appending(path: "Runs/\(fixture.definition.id.uuidString)/\(fixture.run.id.uuidString)/run.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: runURL)) as? [String: Any])
        var lanes = try #require(json["laneResults"] as? [[String: Any]])
        switch field {
        case "output":
            var observations = try #require(lanes[0]["observations"] as? [String: Any])
            observations["feature.response"] = ["string": ["_0": "Changed after assessment"]]
            lanes[0]["observations"] = observations
        case "receipt": lanes[0].removeValue(forKey: "actionReceipts")
        default: lanes[0]["cleanupVerified"] = false
        }
        json["laneResults"] = lanes
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: runURL)
        let before = try fileSnapshot(root)
        var qualified = false
        do {
            let decision = try await ScenarioSavedExecutionReportService(rootDirectory: root)
                .qualification(executionID: fixture.record.id)
            qualified = decision.report?.outcome == .passed
        } catch { /* Corrupt saved evidence may fail before qualification. */ }
        #expect(!qualified)
        #expect(try fileSnapshot(root) == before)
    }

    @MainActor
    @Test func pendingMissingAndTamperedEvidenceNeverQualifies() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = EvaluationStore(supportDirectory: support)
        let root = store.overviewStorageDirectory.appending(path: "IntentLab")
        let fixture = try await savedFixture(root: root, semanticOnlyFeature: true)
        let authority = MCPStoreAuthority.make(store: store)
        let missing = await authority.call(.getScenarioExecutionReport(.init(executionID: UUID())))
        #expect(missing.isError)
        let service = ScenarioSavedExecutionReportService(rootDirectory: root)
        let pendingPlan = try ScenarioExecutionPlan.make(definition: fixture.definition, profile: fixture.plan.profile,
            appProductDigest: fixture.plan.appProductDigest, testProductDigest: fixture.plan.testProductDigest,
            sourceInputsDigest: fixture.plan.sourceInputsDigest!, runnerBuildID: nil, runnerID: nil)
        let pendingRecord = try ScenarioExecutionRecord.make(plan: pendingPlan,
            records: pendingPlan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted))
        let persistence = ScenarioPersistence(rootDirectory: root)
        try await persistence.savePlan(pendingPlan)
        try await persistence.saveExecutionRecord(pendingRecord)
        let beforePending = try fileSnapshot(root)
        let pending = try await service.qualification(executionID: pendingRecord.id)
        #expect(!pending.incompleteEvidence.isEmpty)
        #expect(pending.report?.outcome != .passed)
        let pendingMCP = await authority.call(.getScenarioExecutionReport(.init(executionID: pendingRecord.id)))
        #expect(!pendingMCP.isError)
        #expect(pendingMCP.structuredContent.objectValue?["qualification"]?.objectValue?["incompleteEvidence"] != .array([]))
        #expect(try fileSnapshot(root) == beforePending)
        // A corrupt latest selection must produce an error, never fall back to a prior pass.
        let enumerator = try #require(FileManager.default.enumerator(at: root.appending(path: "Assessments"), includingPropertiesForKeys: nil))
        let actualPointer = try #require((enumerator.allObjects as? [URL])?.first { $0.lastPathComponent == "latest.json" })
        let pointerBytes = try Data(contentsOf: actualPointer)
        try Data("invalid".utf8).write(to: actualPointer)
        let corruptSelection = await authority.call(.getScenarioExecutionReport(.init(executionID: fixture.record.id)))
        #expect(corruptSelection.isError)
        try pointerBytes.write(to: actualPointer)
        let selectionPath = actualPointer.deletingLastPathComponent()
            .appending(path: fixture.selection.id.uuidString.lowercased() + ".json")
        let savedSelectionBytes = try Data(contentsOf: selectionPath)
        var changedSelection = fixture.selection
        changedSelection.executionRecordDigest = String(repeating: "0", count: 64)
        try CanonicalJSON.data(for: changedSelection, prettyPrinted: false).write(to: selectionPath)
        let beforeCorruptSelection = try fileSnapshot(root)
        let corruptSelectionBinding = await authority.call(.getScenarioExecutionReport(.init(executionID: fixture.record.id)))
        #expect(corruptSelectionBinding.isError)
        #expect(try fileSnapshot(root) == beforeCorruptSelection)
        try savedSelectionBytes.write(to: selectionPath)
        let policyPath = root.appending(path: "Assessments/Requirements/\(fixture.definition.id.uuidString.lowercased())-v\(fixture.definition.version).json")
        let policyBytes = try Data(contentsOf: policyPath)
        try FileManager.default.removeItem(at: policyPath)
        let beforeMissingPolicy = try fileSnapshot(root)
        let missingPolicy = try await service.qualification(executionID: fixture.record.id)
        #expect(!missingPolicy.incompleteEvidence.isEmpty)
        #expect(missingPolicy.report?.outcome != .passed)
        #expect(try fileSnapshot(root) == beforeMissingPolicy)
        try policyBytes.write(to: policyPath)
        var policy = fixture.policy
        policy.definitionDigest = String(repeating: "0", count: 64)
        try CanonicalJSON.data(for: policy, prettyPrinted: false).write(to: policyPath)
        let corruptPolicy = await authority.call(.getScenarioExecutionReport(.init(executionID: fixture.record.id)))
        #expect(corruptPolicy.isError)
    }

    @Test func toolRequiresStableExecutionIDAndIsReadOnly() throws {
        let id = UUID()
        let call = try MCPToolCatalog.parse(name: "eval_get_scenario_execution_report", arguments: .object(["executionID": .string(id.uuidString)]))
        if case .getScenarioExecutionReport(let arguments) = call { #expect(arguments.executionID == id) }
        else { Issue.record("Wrong tool routing") }
        let invalid: [MCPJSONValue] = [.object([:]), .object(["executionID": .string("bad")]), .object(["runID": .string(id.uuidString)])]
        let descriptor = try #require(MCPToolCatalog.allDefinitions.first { $0.name == "eval_get_scenario_execution_report" })
        #expect(descriptor.annotations.readOnlyHint)
        #expect(!descriptor.annotations.destructiveHint)
        for arguments in invalid {
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_get_scenario_execution_report", arguments: arguments) }
        }
    }

    private func nativeRunDigest(_ run: ScenarioRun) throws -> String {
        var immutableRun = run
        immutableRun.acceptanceStatus = .pending
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ScenarioIndependentAssessmentService.digest(try encoder.encode(immutableRun))
    }

    private func fileSnapshot(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
