import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioCollectionTests {
    @Test func collectionMembersNeedTheirOwnOptionalRouteReadiness() async throws {
        let projectID = UUID()
        let editorCase = try caseDefinition(projectID: projectID, name: "Direct only")
        var member = try caseDefinition(projectID: projectID, name: "Optional Siri")
        member.coverage.siri = .optional
        member = try member.frozen()
        let collection = try ScenarioCollection(projectID: projectID, name: "Mixed routes",
            members: [ScenarioCollectionService.member(editorCase), ScenarioCollectionService.member(member)])
        let manifest = try ScenarioCollectionService.freezeManifest(collection: collection,
            definitions: [editorCase, member], scope: .full, appProductDigest: "app-build")
        let optional = try #require(manifest.coordinates.first { $0.caseID == member.id && $0.lane == .siri })
        #expect(!optional.required)
        #expect(!manifest.coordinates.contains { $0.caseID == editorCase.id && $0.lane == .siri })

        let root = FileManager.default.temporaryDirectory.appending(path: "MemberReadiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"),
            persistence: ScenarioPersistence(rootDirectory: root),
            destinationStatusReader: { _, _ in (true, "Fixture destination", .iOS) })
        let configuration = XcodeTestConfiguration(containerPath: root.path, isWorkspace: false,
            scheme: "Fixture", testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: "fixture", generatedResourceDirectory: root.path)
        let editorReadiness = await executor.routeReadiness(definition: editorCase,
            configuration: configuration, projectTrusted: true)
        let memberReadiness = await executor.routeReadiness(definition: member,
            configuration: configuration, projectTrusted: true)
        #expect(editorReadiness[.siri]?.detail == "This route is not included in the current requirement.")
        #expect(memberReadiness[.siri]?.detail != editorReadiness[.siri]?.detail)
        #expect(memberReadiness[.siri]?.checks.contains { $0.id == "nativeScope" && $0.state == .ready } == true)

        // A checked Siri route is ready for the member that includes it. Reusing
        // the editor's excluded-route snapshot would silently block this coordinate.
        let receipt = ScenarioReadinessProbeReceipt(schemaVersion: 1, testName: "readiness",
            testIdentifier: "Fixture/testReadiness()", testMethodStarted: true, createdAt: Date(),
            targetBundleIdentifier: member.target.bundleIdentifier, testBundleIdentifier: "fixture.tests",
            integration: nil, routes: [ScenarioLane.siri.rawValue: .init(status: .ready,
                operationID: nil, supportType: "CoreTesting", context: "member-probe",
                observations: ["intentlab.readiness.appState": .string("runningForeground")], detail: nil)])
        let probe = ScenarioReadinessProbeEvidence(receipt: receipt, resultBundlePath: nil,
            logPath: nil, issue: nil, expectedReadinessOperationID: nil)
        let report = ScenarioPreflightReport(checks: [])
        let stale = XcodeTestExecutor.readiness(lane: optional.lane, report: report, probe: probe,
            included: editorCase.coverage[optional.lane] != .notApplicable)
        let current = XcodeTestExecutor.readiness(lane: optional.lane, report: report, probe: probe,
            included: member.coverage[optional.lane] != .notApplicable)
        #expect(stale.state == .notYetVerified)
        #expect(current.state == .ready)
    }

    @Test func noFixtureBasicCollectionExplainsItsCurrentFormatBoundary() throws {
        var definition = try caseDefinition(projectID: UUID(), name: "Basic Direct")
        definition.fixture = .init(id: "", version: "", digest: "", isSynthetic: false,
                                   preparationOperation: "none", cleanupOperation: "none")
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.assertions = [.init(kind: .returnedField, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"), explanation: "Return the selected ID", applicableLanes: [.intentIntegration])]
        definition.observationPlan = [.init(id: "selectedNoteID", source: .intentResult)]
        definition = try definition.frozen()
        #expect(ScenarioExpectationAuthoring.isUnpreparedBasicDirectCheck(definition))
        let collection = try ScenarioCollection(
            projectID: definition.projectID!, name: "Basic checks", members: [ScenarioCollectionService.member(definition)]
        )
        do {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: [definition], scope: .full, appProductDigest: "app-build"
            )
            Issue.record("The current collection format cannot represent absent independent fixture evidence")
        } catch {
            #expect(error as? ScenarioCollectionError == .unpreparedBasicCollection)
            #expect(error.localizedDescription.contains("individually"))
        }
    }

    @Test(arguments: ["blocked", "notRun", "cancelled", "failedToExecute", "failed", "recoveryRequired", "invalidEvidence", "incompleteLane"])
    func optionalRoutesDistinguishBusinessDiagnosticsFromEvidenceRemediation(terminal: String) async throws {
        var definition = try caseDefinition(projectID: UUID(), name: "Optional Siri")
        definition.coverage.siri = .optional
        definition.integration = .init(id: "fixture-integration", version: "1", digest: String(repeating: "a", count: 64))
        definition = try definition.frozen()
        let collection = try ScenarioCollection(
            projectID: definition.projectID!, name: "Read-only checks",
            members: [ScenarioCollectionService.member(definition)]
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", createdAt: instant
        )
        let direct = try #require(manifest.coordinates.first { $0.lane == .intentIntegration })
        let optional = try #require(manifest.coordinates.first { $0.lane == .siri })
        let passing = run(for: definition, coordinate: direct, startedAt: instant.addingTimeInterval(1), outcome: .passed)
        var runs = [passing]
        var rows: [ScenarioExecutionCoordinateRecord] = [.init(
            coordinate: direct, state: .completed, evidenceRunID: passing.id,
            evidenceLaneResultID: passing.laneResults[0].id, detail: nil, laneResult: passing.laneResults[0]
        )]
        if ["failed", "invalidEvidence", "incompleteLane"].contains(terminal) {
            var diagnostic = run(for: definition, coordinate: optional, startedAt: instant.addingTimeInterval(1),
                                 outcome: terminal == "failed" ? .failed : .passed)
            if terminal == "incompleteLane" { diagnostic.laneResults[0].executionStatus = .invalidEvidence }
            runs.append(diagnostic)
            rows.append(.init(coordinate: optional, state: .completed, evidenceRunID: diagnostic.id,
                              evidenceLaneResultID: diagnostic.laneResults[0].id, detail: nil,
                              laneResult: diagnostic.laneResults[0]))
        } else {
            let state = try #require(ScenarioCoordinateTerminalState(rawValue: terminal))
            rows.append(.init(coordinate: optional, state: state, evidenceRunID: nil,
                              evidenceLaneResultID: nil, detail: "Siri is unavailable"))
        }
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: rows)],
            recordedAt: instant.addingTimeInterval(2)
        )
        let journals = runs.map(acceptedJournal(for:)).filter {
            terminal != "invalidEvidence" || $0.scope?.lane != .siri
        }
        let assessment = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: runs, journals: journals
        )
        let requiresRemediation = ["recoveryRequired", "invalidEvidence", "incompleteLane"].contains(terminal)
        #expect(assessment.qualification == (requiresRemediation ? .incomplete : .passedFull))
        #expect(assessment.coordinates.count == 2)
        #expect(assessment.requiredPlannedCount == 1)
        #expect(assessment.requiredPassedCount == 1)
        let optionalAssessment = try #require(assessment.coordinates.first { $0.id == optional.id })
        #expect(optionalAssessment.requiresEvidenceValidation == ["invalidEvidence", "incompleteLane"].contains(terminal))
        let expectedCases: Set<UUID> = requiresRemediation ? [definition.id] : []
        #expect(ScenarioCollectionService.failedCaseIDs(in: assessment) == expectedCases)
        if requiresRemediation {
            let rerun = try ScenarioCollectionService.freezeFailedRerun(
                collection: collection, definitions: [definition],
                priorManifest: manifest, priorResult: result, priorRuns: runs,
                priorJournals: journals, appProductDigest: "app-build",
                createdAt: instant.addingTimeInterval(3)
            )
            #expect(rerun.scope == .rerunFailed)
            #expect(rerun.priorBatchID == manifest.id)
            #expect(rerun.cases.map(\.id) == [definition.id])
            #expect(Set(rerun.coordinates.map(\.id)).isDisjoint(with: manifest.coordinates.map(\.id)))
            if terminal == "recoveryRequired" {
                // Selection is a plan, not authority to replay an unresolved action.
                // The same connection admission used by runSelectedCollection
                // must still reject its restored destination quarantine.
                let root = FileManager.default.temporaryDirectory.appending(path: "CollectionRecovery-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let persistence = ScenarioPersistence(rootDirectory: root)
                var interrupted = acceptedJournal(for: run(
                    for: definition, coordinate: optional, startedAt: instant.addingTimeInterval(1), outcome: .passed
                ))
                interrupted.phase = .recoveryRequired
                interrupted.evidenceAccepted = nil
                interrupted.recoveryReason = "The prior Siri invocation has not been proven stopped."
                interrupted.derivedDataPath = root.appending(path: "DerivedData").path
                try await persistence.saveJournal(interrupted)
                let executor = XcodeTestExecutor(
                    workDirectory: root.appending(path: "Executor"), persistence: persistence,
                    destinationStatusReader: { _, _ in
                        Issue.record("A quarantined rerun reached a device probe.")
                        return (false, "Unexpected probe", nil)
                    }
                )
                #expect(try await executor.reconcileInterruptedJournals().map(\.id) == [interrupted.id])
                let configuration = XcodeTestConfiguration(
                    containerPath: root.path, isWorkspace: false, scheme: "Fixture",
                    testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
                    destinationIdentifier: interrupted.invocation.destinationIdentifier,
                    generatedResourceDirectory: root.path
                )
                do {
                    _ = try await executor.verifyConnection(
                        definition: definition, configuration: configuration, projectTrusted: true
                    )
                    Issue.record("A recovery-case selection bypassed connection admission.")
                } catch XcodeTestExecutorError.deviceUnavailable(let detail) {
                    #expect(detail.contains("recovery"))
                }
                #expect(await executor.reservation(for: configuration.destinationIdentifier) != nil)
                #expect(await executor.hasActiveExecution() == false)
                let retained = try await persistence.loadJournals()
                #expect(retained.count == 1)
                #expect(retained.first?.phase == .recoveryRequired)
            }
        } else {
            #expect(throws: ScenarioCollectionError.self) {
                _ = try ScenarioCollectionService.freezeFailedRerun(
                    collection: collection, definitions: [definition],
                    priorManifest: manifest, priorResult: result, priorRuns: runs,
                    priorJournals: journals, appProductDigest: "app-build"
                )
            }
        }
    }

    @Test(arguments: ["acceptance", "missingJournal", "journalAcceptance", "nonce", "scope", "exit", "unknownExit", "incompleteExecution", "duplicateRun"])
    func nativeBatchNeverPromotesDiagnosticEvidenceToFullPass(mutation: String) throws {
        let definition = try caseDefinition(projectID: UUID(), name: "Bound Direct")
        let collection = try ScenarioCollection(
            projectID: definition.projectID!, name: "Native checks",
            members: [ScenarioCollectionService.member(definition)]
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", createdAt: instant
        )
        let coordinate = manifest.coordinates[0]
        var observed = run(for: definition, coordinate: coordinate,
                           startedAt: instant.addingTimeInterval(1), outcome: .passed)
        let row = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed, evidenceRunID: observed.id,
            evidenceLaneResultID: observed.laneResults[0].id, detail: nil, laneResult: observed.laneResults[0]
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [row])],
            recordedAt: instant.addingTimeInterval(2)
        )
        var journal = acceptedJournal(for: observed)
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result, runs: [observed], journals: [journal]
        ).qualification == .passedFull)
        switch mutation {
        case "acceptance": observed.acceptanceStatus = nil
        case "journalAcceptance": journal.evidenceAccepted = false
        case "nonce": journal.invocation.nonce = "another-attempt"
        case "scope": journal.scope = .init(lane: .siri, attempt: 1)
        case "exit": observed.xctestExitCode = 65
        case "unknownExit": observed.xctestExitCode = nil
        case "incompleteExecution": observed.executionStatus = .invalidEvidence
        default: break
        }
        let assessment = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: mutation == "duplicateRun" ? [observed, observed] : [observed],
            journals: mutation == "missingJournal" ? [] : [journal]
        )
        #expect(assessment.qualification == .incomplete)
        #expect(assessment.passedCount == 0)
        #expect(assessment.coordinates[0].terminalState == .blocked)
    }

    @Test func sameMemberIDsWithNewRevisionsEnableCollectionUpdate() throws {
        let original = try caseDefinition(projectID: UUID(), name: "Original")
        let collection = try ScenarioCollection(projectID: original.projectID!, name: "Collection", members: [ScenarioCollectionService.member(original)])
        #expect(ScenarioCollectionService.membershipMatchesLatest(collection, selectedIDs: [original.id], definitions: [original]))
        var updated = original
        updated.version += 1
        updated.goal.requestText += " revised"
        updated = try updated.frozen()
        #expect(!ScenarioCollectionService.membershipMatchesLatest(collection, selectedIDs: [original.id], definitions: [original, updated]))
    }

    @Test func omittedSiriAttemptCountUsesThreeAttemptsInBatch() throws {
        var definition = try caseDefinition(projectID: UUID(), name: "Siri default")
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .notApplicable, siri: .required)
        definition.safety.mutationPolicy = .readOnly
        definition = try definition.frozen()
        let collection = try ScenarioCollection(projectID: definition.projectID!, name: "Siri", members: [ScenarioCollectionService.member(definition)])
        let manifest = try ScenarioCollectionService.freezeManifest(collection: collection, definitions: [definition], scope: .full, appProductDigest: "app")
        #expect(manifest.coordinates.map(\.repetition) == [1, 2, 3])
    }

    @Test func selectedManifestPreservesCollectionOrderRegardlessOfDefinitionOrder() throws {
        let projectID = UUID()
        let definitions = try (0..<3).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Selected cases",
            members: try definitions.map(ScenarioCollectionService.member)
        )
        let selectedIDs: Set<UUID> = [definitions[2].id, definitions[0].id]
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: Array(definitions.reversed()), scope: .selected,
            appProductDigest: "app-build", selectedCaseIDs: selectedIDs
        )
        #expect(manifest.cases.map(\.member) == [collection.members[0], collection.members[2]])
        try ScenarioCollectionService.validate(manifest: manifest, collection: collection)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: definitions, scope: .selected,
                appProductDigest: "app-build", selectedCaseIDs: selectedIDs.union([UUID()])
            )
        }
    }

    @Test(arguments: ["reordered", "duplicate", "unknown", "revision", "digest", "fullScope"])
    func manifestRejectsInvalidSelectedMembership(mutation: String) throws {
        let projectID = UUID()
        let definitions = try (0..<3).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Selected cases",
            members: try definitions.map(ScenarioCollectionService.member)
        )
        var manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .selected,
            appProductDigest: "app-build", selectedCaseIDs: [definitions[0].id, definitions[2].id]
        )
        switch mutation {
        case "reordered": manifest.cases.reverse()
        case "duplicate":
            manifest.cases[1].member = manifest.cases[0].member
            manifest.coordinates[1].caseID = manifest.cases[0].id
            manifest.coordinates[1].repetition = 2
        case "unknown":
            manifest.cases[0].member.caseID = UUID()
            manifest.coordinates[0].caseID = manifest.cases[0].id
        case "revision": manifest.cases[0].member.version += 1
        case "digest": manifest.cases[0].member.definitionDigest = "changed"
        case "fullScope": manifest.scope = .full
        default: Issue.record("Unknown membership mutation: \(mutation)")
        }
        manifest.manifestDigest = try manifest.calculatedDigest()
        #expect(manifest.hasValidDigest)
        #expect(throws: ScenarioCollectionError.self) {
            try ScenarioCollectionService.validate(manifest: manifest, collection: collection)
        }
    }

    @Test func interruptedBatchKeepsEntirePlannedPopulationVisibleAfterRelaunch() async throws {
        let projectID = UUID()
        let definitions = try (0..<3).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Summaries",
            members: try definitions.map(ScenarioCollectionService.member)
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000.234)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .full,
            appProductDigest: "app-build", createdAt: instant
        )
        #expect(manifest.coordinates.count == 3)
        let first = manifest.coordinates[0]
        let second = manifest.coordinates[1]
        let passing = run(for: definitions[0], coordinate: first, startedAt: instant.addingTimeInterval(1), outcome: .passed)
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [
                try execution(manifest: manifest, caseID: first.caseID, records: [
                    .init(coordinate: first, state: .completed, evidenceRunID: passing.id,
                          evidenceLaneResultID: passing.laneResults[0].id, detail: nil)
                ]),
                try execution(manifest: manifest, caseID: second.caseID, records: [
                    .init(coordinate: second, state: .cancelled, evidenceRunID: nil,
                          evidenceLaneResultID: nil, detail: "Interrupted")
                ])
            ], recordedAt: instant.addingTimeInterval(2)
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioCollectionStore(rootDirectory: root)
        try await store.saveCollection(collection, definitions: definitions)
        try await store.saveManifest(manifest, collection: collection)
        try await store.saveResult(result)

        let reloaded = ScenarioCollectionStore(rootDirectory: root)
        let savedCollection = try #require(await reloaded.loadCollection(id: collection.id, version: 1))
        let savedManifest = try #require(await reloaded.loadManifest(id: manifest.id))
        let savedResult = try #require(await reloaded.loadResult(id: result.id))
        let assessment = ScenarioCollectionService.assess(
            manifest: savedManifest, collection: savedCollection, result: savedResult,
            runs: [passing], journals: [acceptedJournal(for: passing)]
        )
        #expect(assessment.qualification == .incomplete)
        #expect(assessment.plannedCount == 3)
        #expect(assessment.passedCount == 1)
        #expect(assessment.coordinates.map(\.terminalState) == [.completed, .cancelled, .notRun])
        #expect(ScenarioCollectionService.failedCaseIDs(in: assessment).count == 2)
    }

    @Test func selectedRerunCannotBorrowOlderGreenRowsOrQualifyFullCollection() throws {
        let projectID = UUID()
        let definitions = try (0..<2).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(projectID: projectID, name: "Regression",
                                                members: try definitions.map(ScenarioCollectionService.member))
        let baselineTime = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .full,
            appProductDigest: "app-build", createdAt: baselineTime
        )
        let allFailedRerun = try ScenarioCollectionService.freezeFailedRerun(
            collection: collection, definitions: definitions,
            priorManifest: baseline, priorResult: nil, priorRuns: [],
            appProductDigest: "app-build", createdAt: baselineTime.addingTimeInterval(50)
        )
        #expect(allFailedRerun.scope == .rerunFailed)
        #expect(allFailedRerun.cases.count == 2)
        #expect(ScenarioCollectionService.assess(
            manifest: allFailedRerun, collection: collection, result: nil, runs: []
        ).qualification == .partial)
        let candidateTime = baselineTime.addingTimeInterval(100)
        let candidate = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .rerunFailed,
            appProductDigest: "app-build",
            selectedCaseIDs: [definitions[0].id], priorBatchID: baseline.id,
            createdAt: candidateTime
        )
        #expect(candidate.coordinates.count == 1)
        let oldRun = run(for: definitions[0], coordinate: baseline.coordinates[0],
                         startedAt: baselineTime.addingTimeInterval(1), outcome: .passed)
        let coordinate = candidate.coordinates[0]
        let stale = ScenarioCollectionBatchResult(
            id: candidate.id, manifestID: candidate.id,
            executions: [try execution(manifest: candidate, caseID: coordinate.caseID, records: [
                .init(coordinate: coordinate, state: .completed, evidenceRunID: oldRun.id,
                      evidenceLaneResultID: oldRun.laneResults[0].id, detail: nil)
            ])],
            recordedAt: candidateTime.addingTimeInterval(1)
        )
        let staleAssessment = ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: stale, runs: [oldRun]
        )
        #expect(staleAssessment.qualification == .partial)
        #expect(staleAssessment.passedCount == 0)
        #expect(staleAssessment.coordinates[0].reason?.contains("stale") == true)

        let freshRun = run(for: definitions[0], coordinate: coordinate,
                           startedAt: candidateTime.addingTimeInterval(1), outcome: .passed)
        let fresh = ScenarioCollectionBatchResult(
            id: candidate.id, manifestID: candidate.id,
            executions: [try execution(manifest: candidate, caseID: coordinate.caseID, records: [
                .init(coordinate: coordinate, state: .completed, evidenceRunID: freshRun.id,
                      evidenceLaneResultID: freshRun.laneResults[0].id, detail: nil)
            ])],
            recordedAt: candidateTime.addingTimeInterval(2)
        )
        let freshAssessment = ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: fresh, runs: [freshRun, oldRun],
            journals: [acceptedJournal(for: freshRun)]
        )
        #expect(freshAssessment.passedCount == 1)
        #expect(freshAssessment.qualification == .partial)
        var siblingRouteFailed = freshRun
        siblingRouteFailed.outcome = .failed
        #expect(ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: fresh,
            runs: [siblingRouteFailed], journals: [acceptedJournal(for: siblingRouteFailed)]
        ).passedCount == 1)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: definitions, scope: .full,
                appProductDigest: "app-build",
                selectedCaseIDs: [definitions[0].id]
            )
        }
    }

    @Test func approvedVariationBecomesSeparateReviewedCaseWithoutChangingSource() async throws {
        let projectID = UUID()
        let source = try caseDefinition(projectID: projectID, name: "Source")
        let collection = try ScenarioCollection(projectID: projectID, name: "Phrases",
                                                members: [ScenarioCollectionService.member(source)])
        let reviewedText = "Summarise the packing note in one sentence"
        let draft = ScenarioVariationDraft(
            id: UUID(), sourceCaseID: source.id, sourceVersion: source.version,
            requestText: reviewedText, parameters: source.directControl.parameters,
            featureInputs: [], outcomeReview: .sameOutcome
        )
        var reviewed = source
        reviewed.id = UUID()
        reviewed.definitionDigest = ""
        reviewed.testContractDigest = nil
        reviewed.goal.requestText = reviewedText
        reviewed.assertions = reviewed.assertions.map { assertion in
            var copy = assertion
            copy.id = UUID()
            return copy
        }
        let result = try ScenarioCollectionService.addingApprovedVariations(
            [.init(draft: draft, reviewedDefinition: reviewed)], source: source, to: collection
        )
        #expect(collection.version == 1)
        #expect(collection.members.count == 1)
        #expect(source.goal.requestText != reviewedText)
        #expect(result.collection.version == 2)
        #expect(result.collection.members.count == 2)
        #expect(result.cases[0].goal.requestText == reviewedText)
        #expect(result.collection.members[1].lineage?.approvedDraftID == draft.id)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioCollectionStore(rootDirectory: root)
        try await store.saveCollection(collection, definitions: [source])
        try await store.saveCollection(result.collection, definitions: [source] + result.cases)
        let reloaded = ScenarioCollectionStore(rootDirectory: root)
        #expect(try await reloaded.loadCollection(id: collection.id, version: 2)?.members.count == 2)
        #expect(try await reloaded.loadCollections().count == 2)

        var changed = reviewed
        changed.id = UUID()
        changed.goal.expectedBehavior = "Change the note's title"
        let unreviewed = ScenarioApprovedVariation(draft: draft, reviewedDefinition: changed)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations([unreviewed],
                                                                       source: source, to: collection)
        }
        var reviewedDifferent = changed
        reviewedDifferent.assertions[0].expectedValue = .string("changed-note-id")
        var differentDraft = draft
        differentDraft.outcomeReview = .differentOutcomeReviewed
        let changedResult = try ScenarioCollectionService.addingApprovedVariations(
            [.init(draft: differentDraft, reviewedDefinition: reviewedDifferent)],
            source: source, to: collection
        )
        #expect(changedResult.collection.members[1].lineage?.outcomeReview == .differentOutcomeReviewed)
        var changedCheck = reviewed
        changedCheck.id = UUID()
        changedCheck.assertions[0].expectedValue = .string("Different note")
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations(
                [.init(draft: draft, reviewedDefinition: changedCheck)], source: source, to: collection
            )
        }
        var unsupported = draft
        unsupported.unsupportedReason = "Multi-turn Siri is not supported"
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations(
                [.init(draft: unsupported, reviewedDefinition: reviewed)], source: source, to: collection
            )
        }
    }

    @Test func membershipDiffLabelsAddedRemovedAndChangedWithoutCallingDeletionImprovement() throws {
        let projectID = UUID()
        let a = try caseDefinition(projectID: projectID, name: "A")
        let b = try caseDefinition(projectID: projectID, name: "B")
        let c = try caseDefinition(projectID: projectID, name: "C")
        let baseline = try ScenarioCollection(projectID: projectID, name: "Cases",
                                              members: [ScenarioCollectionService.member(a),
                                                        ScenarioCollectionService.member(b)])
        var changedB = b
        changedB.version = 2
        changedB.goal.expectedBehavior = "A different expected outcome"
        changedB = try changedB.frozen()
        let candidate = try baseline.revised(members: [
            ScenarioCollectionService.member(changedB), ScenarioCollectionService.member(c)
        ])
        let difference = try ScenarioCollectionService.membershipDifference(
            baseline: baseline, candidate: candidate
        )
        #expect(difference.map(\.change) == [.removed, .changed, .added])
        #expect(difference.map(\.caseID) == [a.id, b.id, c.id])
        #expect(baseline.membershipDigest != candidate.membershipDigest)
    }

    @Test func featureCoordinateRequiresItsOwnFreshSealedChildEvidence() throws {
        let projectID = UUID()
        var definition = try caseDefinition(projectID: projectID, name: "Feature")
        definition.coverage = .init(appFeature: .required, intentIntegration: .notApplicable,
                                    siri: .notApplicable, siriAttemptCount: 1)
        definition.featureBinding = .init(featureID: "summarize", interfaceDigest: "interface",
                                           inputMapping: [], outputProjections: [])
        definition = try definition.frozen()
        let collection = try ScenarioCollection(projectID: projectID, name: "Feature checks",
                                                members: [ScenarioCollectionService.member(definition)])
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: [definition], scope: .full,
                appProductDigest: "app-build", createdAt: instant
            )
        }
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            createdAt: instant
        )
        let coordinate = manifest.coordinates[0]
        let featureRunID = UUID()
        let featureSampleID = UUID()
        let lane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .appFeature,
                                      executionStatus: .completed, outcome: .passed,
                                      startedAt: instant.addingTimeInterval(1),
                                      completedAt: instant.addingTimeInterval(2),
                                      observations: [
                                          "feature.response": .string("The actual summary"),
                                          "feature.runID": .string(featureRunID.uuidString),
                                          "feature.sampleID": .string(featureSampleID.uuidString)
                                      ])
        let child = try ScenarioFeatureChildEvidence(
            runID: featureRunID, sampleID: featureSampleID,
            startedAt: instant.addingTimeInterval(1),
            completedAt: instant.addingTimeInterval(2), caseID: definition.id, attempt: 1,
            response: "The actual summary", encodedOutput: nil, encodedOutputTypeName: nil,
            outputMetadata: [:], errorCategory: nil, errorMessage: nil,
            appBundleIdentifier: definition.target.bundleIdentifier, featureID: "summarize",
            featureVersion: "1", checkedAppProductDigest: "app-build", runnerBuildID: "app-build",
            fixtureContractDigest: definition.fixture.digest, subjectInputDigest: "input", digest: ""
        ).sealed()
        let row = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed, evidenceRunID: child.runID,
            evidenceLaneResultID: lane.id, detail: nil, laneResult: lane, featureChild: child
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [row])],
            recordedAt: instant.addingTimeInterval(3)
        )
        let assessment = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result, runs: []
        )
        #expect(assessment.qualification == .passedFull)
        #expect(assessment.passedCount == 1)

        var stale = child
        stale.startedAt = instant.addingTimeInterval(-10)
        stale.completedAt = instant.addingTimeInterval(-9)
        stale = try stale.sealed()
        var staleRow = row
        staleRow.featureChild = stale
        let staleResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [staleRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        let rejected = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: staleResult, runs: []
        )
        #expect(rejected.qualification == .incomplete)
        #expect(rejected.passedCount == 0)

        var detachedRow = row
        detachedRow.laneResult?.observations["feature.response"] = .string("Another response")
        let detachedResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [detachedRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: detachedResult, runs: []
        ).passedCount == 0)

        var unboundInput = child
        unboundInput.subjectInputDigest = nil
        unboundInput = try unboundInput.sealed()
        var unboundRow = row
        unboundRow.featureChild = unboundInput
        let unboundResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [unboundRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: unboundResult, runs: []
        ).passedCount == 0)
    }

    @Test func localFeatureBatchUsesAcceptedNativeEvidenceAndFreezesRerunBackend() throws {
        let projectID = UUID()
        var definition = try caseDefinition(projectID: projectID, name: "Local Feature")
        definition.coverage = .init(appFeature: .required, intentIntegration: .notApplicable,
                                    siri: .notApplicable, siriAttemptCount: 1)
        definition.featureBinding = .init(featureID: "summarize",
                                           interfaceDigest: String(repeating: "a", count: 64),
                                           inputMapping: [], outputProjections: [])
        definition = try definition.frozen()
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Local Feature checks",
            members: [ScenarioCollectionService.member(definition)]
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            featureBackend: .projectLocalTestControl, createdAt: instant
        )
        #expect(manifest.selectedFeatureBackend == .projectLocalTestControl)
        var legacy = manifest
        legacy.featureBackend = nil
        legacy.manifestDigest = try legacy.calculatedDigest()
        let decodedLegacy = try JSONDecoder().decode(
            ScenarioCollectionBatchManifest.self, from: JSONEncoder().encode(legacy)
        )
        #expect(decodedLegacy.featureBackend == nil)
        #expect(decodedLegacy.selectedFeatureBackend == .connectedRunner)
        #expect(decodedLegacy.hasValidDigest)
        let coordinate = try #require(manifest.coordinates.first)
        var run = run(for: definition, coordinate: coordinate,
                      startedAt: instant.addingTimeInterval(1), outcome: .passed)
        run.id = run.invocation.id
        run.invocation.featureBackend = .projectLocalTestControl
        run.fixture = definition.fixture
        run.acceptanceStatus = .accepted
        run.executedTestCount = 1
        run.xctestExitCode = 0
        run.laneResults[0].observations["feature.response"] = .string("A summary")
        run.laneResults[0].observationSources = ["feature.response": .testOnlyIntent]
        let lane = run.laneResults[0]
        let row = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed,
            evidenceRunID: run.id, evidenceLaneResultID: lane.id,
            detail: nil, laneResult: lane
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [row])],
            recordedAt: instant.addingTimeInterval(2)
        )
        var journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: run.invocation,
            scenarioID: definition.id, scenarioVersion: definition.version,
            resultBundlePath: "result", derivedDataPath: "derived", buildLogPath: "build",
            intendedExecutable: "xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil,
            updatedAt: instant.addingTimeInterval(2), recoveryReason: nil,
            evidenceAccepted: true, scope: .init(lane: .appFeature, attempt: 1)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run], journals: [journal]
        ).qualification == .passedFull)
        var nonzero = run
        nonzero.xctestExitCode = 65
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [nonzero], journals: [journal]
        ).passedCount == 0)
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run]
        ).passedCount == 0)
        journal.evidenceAccepted = false
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run], journals: [journal]
        ).passedCount == 0)
        var connected = manifest
        connected.featureBackend = .connectedRunner
        connected.manifestDigest = try connected.calculatedDigest()
        #expect(ScenarioCollectionService.assess(
            manifest: connected, collection: collection, result: result,
            runs: [run], journals: []
        ).passedCount == 0)

        let rerun = try ScenarioCollectionService.freezeFailedRerun(
            collection: collection, definitions: [definition],
            priorManifest: manifest, priorResult: nil, priorRuns: [],
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            createdAt: instant.addingTimeInterval(3)
        )
        #expect(rerun.selectedFeatureBackend == .projectLocalTestControl)
        #expect(rerun.scope == .rerunFailed)
    }

    private func caseDefinition(projectID: UUID, name: String) throws -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.id = UUID()
        definition.name = name
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.goal.requestText = "Open \(name)"
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: 1)
        return try definition.frozen()
    }

    private func run(for definition: ScenarioDefinition, coordinate: ScenarioPlannedCoordinate,
                     startedAt: Date, outcome: ScenarioOutcome) -> ScenarioRun {
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "test", issuedAt: startedAt,
            testIdentity: .init(bundleIdentifier: "tests", className: "Fixture", methodName: "test"),
            harnessVersion: "intent-lab-v2", destinationIdentifier: "test",
            scenarioDigest: definition.definitionDigest, resultBundleIdentity: "test",
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                              executableName: "Fixture", sha256: "app-build"), testProduct: nil
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "test",
            operatingSystem: "test", operatingSystemBuild: nil,
            languageCode: "en-GB", regionCode: "GB", timeZoneIdentifier: "UTC",
            siriConfiguration: nil, siriConfigurationSource: nil, executedAt: startedAt
        )
        let lane = ScenarioLaneResult(
            caseID: coordinate.caseID, attempt: coordinate.repetition,
            lane: coordinate.lane, executionStatus: .completed, outcome: outcome,
            startedAt: startedAt, completedAt: startedAt,
            diagnostic: outcome == .passed ? nil : "Observed failure"
        )
        return ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: startedAt, completedAt: startedAt, environment: environment,
            executionStatus: .completed, outcome: outcome, laneResults: [lane],
            linkedFeatureRunID: nil, importedAt: startedAt,
            xctestExitCode: 0, fixture: definition.fixture, acceptanceStatus: .accepted,
            scenarioSchemaVersion: ScenarioDefinition.stableSchemaVersion,
            testContractDigest: definition.testContractDigest, executedTestCount: 1
        )
    }

    private func acceptedJournal(for run: ScenarioRun) -> ScenarioExecutionJournal {
        .init(
            phase: .stopped, invocation: run.invocation,
            scenarioID: run.scenarioID, scenarioVersion: run.scenarioVersion,
            resultBundlePath: "result", derivedDataPath: "derived", buildLogPath: "build",
            intendedExecutable: "xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: run.completedAt,
            recoveryReason: nil, evidenceAccepted: true,
            scope: .init(lane: run.laneResults[0].lane, attempt: run.laneResults[0].attempt)
        )
    }

    private func execution(manifest: ScenarioCollectionBatchManifest, caseID: UUID,
                           records: [ScenarioExecutionCoordinateRecord]) throws -> ScenarioExecutionRecord {
        let snapshot = manifest.cases.first { $0.id == caseID }!
        let plan = ScenarioExecutionPlan(
            id: snapshot.executionPlanID, definitionID: caseID,
            definitionVersion: snapshot.member.version,
            definitionDigest: snapshot.member.definitionDigest,
            testContractDigest: snapshot.member.testContractDigest,
            profile: .init(id: UUID(), projectPath: "fixture", scheme: "Fixture",
                           testTarget: "FixtureTests", destinationIdentifier: "test",
                           signingSelection: nil,
                           featureBackend: manifest.selectedFeatureBackend),
            appProductDigest: manifest.appProductDigest, testProductDigest: "test-build",
            fixtureContractDigest: snapshot.fixtureContractDigest,
            coordinates: manifest.coordinates.filter { $0.caseID == caseID },
            comparisonPolicy: nil, createdAt: manifest.createdAt
        )
        return try .make(plan: plan, records: records,
                         completedAt: manifest.createdAt.addingTimeInterval(2))
    }
}
