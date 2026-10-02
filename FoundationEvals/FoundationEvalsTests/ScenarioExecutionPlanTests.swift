import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioExecutionPlanTests {
    @Test func legacyProfileDecodesConnectedBackendAndLocalPlanRejectsRunnerIdentity() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","projectPath":"/App.xcodeproj","scheme":"App","testTarget":"AppTests","destinationIdentifier":"device"}"#
        let decoded = try JSONDecoder().decode(ScenarioExecutionProfile.self, from: Data(legacy.utf8))
        #expect(decoded.featureBackend == .connectedRunner)

        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage.appFeature = .notApplicable
        definition = try definition.frozen()
        var local = decoded
        local.featureBackend = .projectLocalTestControl
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: local,
            appProductDigest: "app", testProductDigest: "tests",
            sourceInputsDigest: "source", runnerBuildID: nil, runnerID: nil
        )
        #expect(plan.profile.featureBackend == .projectLocalTestControl)
        #expect(plan.runnerID == nil)
        #expect(throws: ScenarioPersistenceError.self) {
            _ = try ScenarioExecutionPlan.make(
                definition: definition, profile: local,
                appProductDigest: "app", testProductDigest: "tests",
                sourceInputsDigest: "source", runnerBuildID: "app", runnerID: UUID()
            )
        }
    }

    @Test func staleGlobalRunnerSelectionUsesOnlyMatchingAppRunner() {
        let matching = UUID()
        let otherApp = UUID()
        #expect(ScenarioRunnerSelection.chosenID(candidateIDs: [matching], selectedID: otherApp) == matching)
        #expect(ScenarioRunnerSelection.chosenID(candidateIDs: [matching], selectedID: matching) == matching)
        #expect(ScenarioRunnerSelection.chosenID(candidateIDs: [matching, UUID()], selectedID: otherApp) == nil)
        #expect(ScenarioRunnerSelection.chosenID(candidateIDs: [], selectedID: otherApp) == nil)
    }

    @Test func featureRecoveryCannotAttributeNewCodeToCapturedMeasurement() {
        let captured = ScenarioMeasurementImplementation(observerID: "host", observerDigest: "old", evaluatorID: "host", evaluatorDigest: "old")
        var changed = captured
        changed.evaluatorDigest = "new"
        #expect(ScenarioExecutionRecoveryPolicy.canReevaluateFeature(captured: captured, current: captured))
        #expect(!ScenarioExecutionRecoveryPolicy.canReevaluateFeature(captured: captured, current: changed))
        #expect(!ScenarioExecutionRecoveryPolicy.canReevaluateFeature(captured: captured, current: nil))
    }

    @Test func frozenCoordinatesCoverEverySelectedRouteAttempt() throws {
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .required, intentIntegration: .required,
                                    siri: .required, siriAttemptCount: 3)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: "app", runnerID: UUID()
        )

        #expect(plan.coordinates.count == 5)
        #expect(plan.coordinates.count == Set(plan.coordinates.map(\.id)).count)
        #expect(plan.coordinates.filter { $0.lane == .appFeature }.map(\.repetition) == [1])
        #expect(plan.coordinates.filter { $0.lane == .intentIntegration }.map(\.repetition) == [1])
        #expect(plan.coordinates.filter { $0.lane == .siri }.map(\.repetition) == [1, 2, 3])
        #expect(plan.coordinates.allSatisfy { $0.required })

        let records = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        let terminal = try ScenarioExecutionRecord.make(plan: plan, records: records)
        #expect(!terminal.isComplete)
        #expect(terminal.records.count == 5)
        #expect(terminal.evidenceDigest.count == 64)
    }

    @Test func partialDiagnosticPlanFreezesSubsetAndLegacyPlanDefaultsToFull() throws {
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .required, siriAttemptCount: 3)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let full = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil
        )
        #expect(full.purpose == .fullRequirement)

        let selected = try #require(full.coordinates.first {
            $0.lane == .siri && $0.repetition == 2
        })
        #expect(throws: ScenarioPersistenceError.self) {
            _ = try ScenarioExecutionPlan.make(
                definition: definition, profile: profile, appProductDigest: "app",
                testProductDigest: "tests", sourceInputsDigest: "source",
                runnerBuildID: nil, runnerID: nil,
                plannedCoordinates: [selected]
            )
        }
        let diagnostic = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil,
            plannedCoordinates: [selected], purpose: .partialDiagnostic
        )
        #expect(diagnostic.purpose == .partialDiagnostic)
        #expect(diagnostic.coordinates == [selected])
        let record = try ScenarioExecutionRecord.make(
            plan: diagnostic, records: [.unstarted(selected)]
        )
        #expect(record.plannedCount == 1)

        var oldPlanJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any]
        )
        oldPlanJSON.removeValue(forKey: "purpose")
        let oldPlan = try JSONDecoder().decode(
            ScenarioExecutionPlan.self,
            from: JSONSerialization.data(withJSONObject: oldPlanJSON)
        )
        #expect(oldPlan == full)
    }

    @Test func singleCoordinateDiagnosticMayEqualFullPopulation() throws {
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let full = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil
        )
        #expect(full.coordinates.count == 1)

        let diagnostic = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil,
            plannedCoordinates: full.coordinates, purpose: .partialDiagnostic
        )
        #expect(diagnostic.purpose == .partialDiagnostic)
        #expect(diagnostic.coordinates == full.coordinates)
        #expect(diagnostic.requiredCoordinates == full.requiredCoordinates)
    }

    @Test func recoveryKeepsUnfinishedCoordinateSeparateFromOlderEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ScenarioExecutionPlanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .required, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: "app", runnerID: UUID()
        )
        try await persistence.savePlan(plan)
        var records = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        records[0].state = .recoveryRequired
        try await persistence.saveProgress(.init(planID: plan.id, records: records, updatedAt: Date()))

        let recovered = try await persistence.recoverIncompleteExecutionRecords()
        #expect(recovered.count == 1)
        #expect(recovered[0].records.count == 2)
        #expect(recovered[0].records.count { $0.state == .recoveryRequired } == 1)
        #expect(recovered[0].records.count { $0.state == .notRun } == 1)
        let repeatedRecovery = try await persistence.recoverIncompleteExecutionRecords()
        #expect(repeatedRecovery.isEmpty)
    }

    @Test func completedFeatureSaveCheckpointRemainsRetryableAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ScenarioFeatureSaveRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .required, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: "app", runnerID: UUID()
        )
        try await persistence.savePlan(plan)
        var rows = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        let feature = try #require(rows.firstIndex(where: { $0.coordinate.lane == .appFeature }))
        let pendingRunID = UUID()
        rows[feature].state = .recoveryRequired
        rows[feature].evidenceRunID = pendingRunID
        rows[feature].featureMeasurementImplementation = .init(observerID: "captured", observerDigest: "old-observer", evaluatorID: "captured", evaluatorDigest: "old-evaluator")
        try await persistence.saveProgress(.init(planID: plan.id, records: rows, updatedAt: .now))
        let recovered = try await persistence.recoverIncompleteExecutionRecords()
        #expect(recovered.isEmpty)
        let saved = try await persistence.loadProgress(planID: plan.id)
        #expect(saved?.records[feature].evidenceRunID == pendingRunID)
        #expect(saved?.records[feature].featureMeasurementImplementation?.observerDigest == "old-observer")
        let terminal = try await persistence.loadExecutionRecords()
        #expect(terminal.isEmpty)
    }

    @Test(arguments: [false, true]) func importedNativeChildStageRemainsSaveOnlyAfterRelaunch(wasSealed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ScenarioNativeSaveRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil
        )
        try await persistence.savePlan(plan)
        var rows = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        rows[0].state = .recoveryRequired
        try await persistence.saveProgress(.init(planID: plan.id, records: rows, updatedAt: .now))
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "nonce", issuedAt: now,
            testIdentity: .init(bundleIdentifier: "test.bundle", className: "Tests", methodName: "test"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "device", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "result", appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                                                               executableName: "App", sha256: "app"),
            testProduct: .init(bundleIdentifier: "test.bundle", executableName: "Tests", sha256: "tests")
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
            operatingSystem: "iOS 27", operatingSystemBuild: "27A1", languageCode: "en",
            regionCode: "GB", timeZoneIdentifier: "Europe/London",
            siriConfiguration: nil, siriConfigurationSource: nil, executedAt: now
        )
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .passed, startedAt: now, completedAt: now
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now, environment: environment,
            executionStatus: .completed, outcome: .notObserved,
            laneResults: [lane], linkedFeatureRunID: nil, importedAt: now
        )
        let stage = ScenarioPendingNativeSave(
            planID: plan.id, coordinateID: rows[0].id, run: run,
            artifactRootPath: root.path, ledger: .init(), evidenceValidationPassed: true, deviceReadinessProven: true
        )
        try await persistence.savePendingNativeSave(stage)
        let recovered = try await persistence.recoverIncompleteExecutionRecords()
        #expect(recovered.isEmpty)
        let pending = try await persistence.loadPendingNativeSave(planID: plan.id, coordinateID: rows[0].id)
        #expect(pending?.run.id == invocation.id)
        #expect(pending?.evidenceValidationPassed == true)
        #expect(pending?.deviceReadinessProven == true)
        let terminal = try await persistence.loadExecutionRecords()
        #expect(terminal.isEmpty)
        let originalURL = root.appending(path: "ExecutionRecords/\(plan.id.uuidString).json")
        var originalBytes: Data?
        if wasSealed {
            try await persistence.saveExecutionRecord(ScenarioExecutionRecord.make(plan: plan, records: rows))
            originalBytes = try Data(contentsOf: originalURL)
        }
        rows[0].state = .completed
        rows[0].laneResult = lane
        rows[0].evidenceRunID = run.id
        rows[0].evidenceLaneResultID = lane.id
        try await persistence.saveProgress(.init(planID: plan.id, records: rows, updatedAt: .now))
        if wasSealed {
            let stored = try await persistence.saveRun(run, artifactRoot: nil)
            await #expect(throws: ScenarioPersistenceError.self) {
                _ = try await persistence.finalizeExecutionRecord(plan: plan, records: rows)
            }
            var journal = ScenarioExecutionJournal(phase: .stopped, invocation: run.invocation, scenarioID: run.scenarioID, scenarioVersion: run.scenarioVersion, resultBundlePath: "result", derivedDataPath: "derived", buildLogPath: "log", intendedExecutable: "/usr/bin/xcodebuild", intendedArguments: [], processIdentifier: nil, processStartedAt: nil, updatedAt: .now, recoveryReason: nil)
            journal.evidenceAccepted = true
            try await persistence.saveJournal(journal)
            var ledger = ScenarioImportLedger()
            ledger.importedInvocationIDs.insert(run.invocation.id)
            ledger.importedNonces.insert(run.invocation.nonce)
            try await persistence.saveLedger(ledger)
            let accepted = try await persistence.acceptRun(stored, journal: journal)
            rows[0].laneResult = accepted.laneResults[0]
        }
        let first = try await persistence.finalizeExecutionRecord(plan: plan, records: rows)
        let retry = try await persistence.finalizeExecutionRecord(plan: plan, records: rows)
        #expect(first.evidenceDigest == retry.evidenceDigest)
        if let originalBytes {
            #expect(try Data(contentsOf: originalURL) == originalBytes)
            let reloaded = try await ScenarioPersistence(rootDirectory: root).loadExecutionRecords()
            #expect(reloaded.count == 1 && reloaded[0].evidenceDigest == first.evidenceDigest)
            var changed = rows
            changed[0].detail = "unsupported change"
            await #expect(throws: ScenarioPersistenceError.self) {
                _ = try await persistence.finalizeExecutionRecord(plan: plan, records: changed)
            }
        }
        #expect(try await persistence.loadPendingNativeSave(planID: plan.id, coordinateID: rows[0].id) != nil)

    }

    @Test func localFeatureNativeStageRemainsSaveOnlyAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ScenarioLocalFeatureSaveRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .required, intentIntegration: .notApplicable,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition.featureBinding = .init(
            featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [], outputProjections: []
        )
        definition.actionRequirements = [.init(
            lane: .appFeature, kind: .productionService,
            operationID: "SummarizeNoteService", resolvedParameters: [:]
        )]
        definition.actionPolicyVersion = 1
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            featureBackend: .projectLocalTestControl
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil
        )
        try await persistence.savePlan(plan)
        let coordinate = try #require(plan.coordinates.first)
        var recovery = ScenarioExecutionCoordinateRecord.unstarted(coordinate)
        recovery.state = .recoveryRequired
        try await persistence.saveProgress(.init(
            planID: plan.id, records: [recovery], updatedAt: .now
        ))
        let now = Date()
        var invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "nonce", issuedAt: now,
            testIdentity: .init(bundleIdentifier: "test.bundle", className: "Tests", methodName: "test"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "device", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "result",
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                              executableName: "App", sha256: "app"),
            testProduct: .init(bundleIdentifier: "test.bundle", executableName: "Tests", sha256: "tests")
        )
        invocation.featureBackend = .projectLocalTestControl
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
            operatingSystem: "iOS 27", operatingSystemBuild: "27A1", languageCode: "en",
            regionCode: "GB", timeZoneIdentifier: "Europe/London",
            siriConfiguration: nil, siriConfigurationSource: nil, executedAt: now
        )
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now,
            observations: ["feature.response": .string("Packed")]
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now, environment: environment,
            executionStatus: .completed, outcome: .passed,
            laneResults: [lane], linkedFeatureRunID: nil, importedAt: now
        )
        var completed = recovery
        completed.state = .completed
        completed.evidenceRunID = run.id
        completed.evidenceLaneResultID = lane.id
        completed.laneResult = lane
        let localRecord = try ScenarioExecutionRecord.make(plan: plan, records: [completed])
        #expect(localRecord.isComplete)
        var wrongBackendPlan = plan
        wrongBackendPlan.profile.featureBackend = .connectedRunner
        #expect(throws: ScenarioPersistenceError.self) {
            _ = try ScenarioExecutionRecord.make(plan: wrongBackendPlan, records: [completed])
        }
        try await persistence.savePendingNativeSave(.init(
            planID: plan.id, coordinateID: coordinate.id, run: run,
            artifactRootPath: root.path, ledger: .init()
        ))
        let relaunched = ScenarioPersistence(rootDirectory: root)
        let recovered = try await relaunched.recoverIncompleteExecutionRecords()
        #expect(recovered.isEmpty)
        let pending = try await relaunched.loadPendingNativeSave(
            planID: plan.id, coordinateID: coordinate.id
        )
        #expect(pending?.run.id == run.id)
        #expect(pending?.run.invocation.featureBackend == .projectLocalTestControl)
        let terminal = try await relaunched.loadExecutionRecords()
        #expect(terminal.isEmpty)
    }

    @Test func optionalUnobservedRouteDoesNotEraseRequiredPass() throws {
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .optional, siriAttemptCount: 1)
        definition = try definition.frozen()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil
        )
        #expect(plan.requiredCoordinates.count == 1)
        #expect(plan.requiredCoordinates.allSatisfy { $0.required })
        var records = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        let required = try #require(records.firstIndex(where: { $0.coordinate.required }))
        let now = Date()
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now,
            observations: ["selectedNoteID": .string("packing-001")],
            assertionResults: [.init(assertionID: UUID(), passed: true, message: "Observed")]
        )
        records[required].state = .completed
        records[required].laneResult = lane
        records[required].evidenceLaneResultID = lane.id
        let terminal = try ScenarioExecutionRecord.make(plan: plan, records: records)
        #expect(!terminal.isComplete)
        #expect(terminal.plannedCount == 2)
        #expect(terminal.executedCount == 1)
        #expect(terminal.aggregateOutcome == .passed)
        let optional = try #require(records.firstIndex(where: { !$0.coordinate.required }))
        var duplicate = lane
        duplicate.lane = .siri
        records[optional].state = .completed
        records[optional].laneResult = duplicate
        records[optional].evidenceLaneResultID = duplicate.id
        #expect(throws: ScenarioPersistenceError.self) {
            try ScenarioExecutionRecord.make(plan: plan, records: records)
        }
    }

    @Test func runtimeEnvironmentIdentityIgnoresRunTimestampButTracksObservedDevice() throws {
        let first = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
            operatingSystem: "iOS 27", operatingSystemBuild: "27A1",
            languageCode: "en", regionCode: "GB", timeZoneIdentifier: "Europe/London",
            siriConfiguration: "enabled", siriConfigurationSource: .applicationInstrumentation,
            executedAt: .now
        )
        var later = first
        later.executedAt = first.executedAt.addingTimeInterval(300)
        let baselineValue = try ScenarioExecutionEnvironmentIdentity.derive(
            environment: first, destinationIdentifier: "device-1", lane: .siri
        )
        let baseline = try #require(baselineValue)
        let candidateValue = try ScenarioExecutionEnvironmentIdentity.derive(
            environment: later, destinationIdentifier: "device-1", lane: .siri
        )
        let candidate = try #require(candidateValue)
        #expect(baseline == candidate)
        later.deviceModel = "Different iPhone"
        let changedValue = try ScenarioExecutionEnvironmentIdentity.derive(
            environment: later, destinationIdentifier: "device-1", lane: .siri
        )
        let changed = try #require(changedValue)
        #expect(changed != baseline)
        later.siriConfigurationSource = nil
        #expect(try ScenarioExecutionEnvironmentIdentity.derive(
            environment: later, destinationIdentifier: "device-1", lane: .siri
        ) == nil)
    }

    @Test func wrongSourceRemainsFailedBusinessEvidence() {
        let actual = ScenarioFixtureReceipt(observed: "different-note-content", expected: "planned-note-content")
        #expect(actual == .wrongSource)
        #expect(actual.outcome(after: .passed) == .failed)
        let absent = ScenarioFixtureReceipt(observed: nil, expected: "planned-note-content")
        #expect(absent == .missing)
        #expect(absent.outcome(after: .passed) == .notObserved)
        let matching = ScenarioFixtureReceipt(observed: "planned-note-content", expected: "planned-note-content")
        #expect(matching.outcome(after: .passed) == .passed)
    }

    @Test func editableCaseTitleDoesNotChangeInternalFeatureSuite() throws {
        var definition = ScenarioDefinition.starter(projectID: UUID())
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition = try definition.frozen()
        let original = ScenarioFeatureSuiteIdentity(definition: definition)
        definition.name = "Renamed for display"
        definition = try definition.frozen()
        let renamed = ScenarioFeatureSuiteIdentity(definition: definition)
        #expect(original == renamed)
    }

    @Test func typedFeatureProjectionUsesOnlyEncodedBusinessOutput() throws {
        let encoded = try JSONSerialization.data(withJSONObject: [
            "summary": "Actual generated summary",
            "sourceContentDigest": "observed-source",
            "mutationCount": 0,
            "claimedPassed": true
        ])
        let fields: [ScenarioOutputField] = [
            .init(name: "summary", type: .primitive(.string)),
            .init(name: "mutationCount", type: .primitive(.integer)),
            .init(name: "missingField", type: .primitive(.string)),
            .init(name: "claimedPassed", type: .primitive(.string))
        ]
        let observed = ScenarioObservedFeatureOutput.project(encoded, fields: fields)
        #expect(observed["summary"] == .string("Actual generated summary"))
        #expect(observed["mutationCount"] == .integer(0))
        #expect(observed["missingField"] == nil)
        #expect(observed["claimedPassed"] == nil)
    }
}
