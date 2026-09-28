import XCTest
import AppIntentsTesting

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testUnresolvedSiriAttemptPreventsResetAndActivationOfLaterAttempts() {
        for error in [SiriProbeError.permissionRequired, .outcomeNotObserved, .invocationNotCorrelated] {
            var sequence = SiriAttemptSequence()
            var activeContext = "attempt-1"
            XCTAssertThrowsError(try sequence.run { throw error })
            XCTAssertThrowsError(try sequence.run {
                activeContext = "attempt-2"
                return "A late result must not belong to this attempt"
            }) { skippedError in
                let skipped = failed(for: .siri, scenario: testScenario(), error: skippedError, startedAt: Date(), attempt: 2)
                XCTAssertEqual(skipped.executionStatus, .invalidEvidence)
                XCTAssertEqual(skipped.outcome, .notObserved)
                XCTAssertTrue(skipped.diagnostic?.contains("not started") == true)
            }
            XCTAssertEqual(activeContext, "attempt-1")
        }
    }

    func testCompletedSiriAttemptsAllowTheNextAttempt() throws {
        var sequence = SiriAttemptSequence()
        XCTAssertEqual(try sequence.run { "attempt-1" }, "attempt-1")
        XCTAssertEqual(try sequence.run { "attempt-2" }, "attempt-2")
    }

    func testEnvironmentPayloadRequiresAnAtomicPair() {
        XCTAssertThrowsError(try IntentLabPayloadLoader.environmentData(
            named: "IntentLabScenario",
            environment: [IntentLabPayloadLoader.scenarioKey: Data("{}".utf8).base64EncodedString()]
        ))
    }

    func testEnvironmentPayloadOverridesBundledCompatibilityData() throws {
        var scenario = testScenario()
        scenario.safety.deadlineSeconds = 9
        let invocation = IntentLabInvocation(
            id: UUID(), nonce: "nonce", issuedAt: Date(),
            testIdentity: .init(
                bundleIdentifier: "dev.example.FixtureUITests",
                className: "IntentLabScenarioTests",
                methodName: "testIntentLabScenario"
            ),
            harnessVersion: "intent-lab-v1", destinationIdentifier: "device",
            scenarioDigest: scenario.definitionDigest, resultBundleIdentity: "result",
            appProduct: nil, testProduct: nil
        )
        let encoder = JSONEncoder.intentLab
        let environment = [
            IntentLabPayloadLoader.scenarioKey: try encoder.encode(scenario).base64EncodedString(),
            IntentLabPayloadLoader.invocationKey: try encoder.encode(invocation).base64EncodedString(),
        ]

        let data = try XCTUnwrap(IntentLabPayloadLoader.environmentData(
            named: "IntentLabScenario",
            environment: environment
        ))
        let decoded = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: data)
        XCTAssertEqual(decoded.safety.deadlineSeconds, 9)
    }

    func testHarnessRetainsWrongVisibleResultAsFailureEvidence() throws {
        var scenario = testScenario()
        scenario.assertions = [.init(
            id: UUID(),
            kind: .entityIdentifier,
            observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            required: true,
            applicableLanes: [.siri]
        )]

        let lane = result(
            for: .siri,
            scenario: scenario,
            observations: ["selectedNoteID": .string("garden-001")],
            startedAt: Date()
        )

        XCTAssertEqual(lane.outcome, .failed)
        XCTAssertEqual(lane.observations["selectedNoteID"], .string("garden-001"))
        XCTAssertEqual(lane.assertionResults.first?.observedValue, .string("garden-001"))
        XCTAssertTrue(Self.hasCompleteObservedResults([lane]))
    }

    func testIncompleteOrUnobservedResultsFailTheHarness() {
        let scenario = testScenario()
        let completed = result(for: .intentIntegration, scenario: scenario, observations: [:], startedAt: Date())
        let timedOut = failed(
            for: .siri, scenario: scenario, error: SiriProbeError.outcomeNotObserved,
            startedAt: Date()
        )
        let error = failed(
            for: .intentIntegration, scenario: scenario,
            error: NSError(domain: "IntentLabScenarioTests", code: 1), startedAt: Date()
        )
        var incomplete = completed
        incomplete.executionStatus = .invalidEvidence

        XCTAssertFalse(Self.hasCompleteObservedResults([]))
        XCTAssertFalse(Self.hasCompleteObservedResults([completed, incomplete]))
        XCTAssertFalse(Self.hasCompleteObservedResults([completed, timedOut]))
        XCTAssertFalse(Self.hasCompleteObservedResults([completed, error]))
        XCTAssertFalse(Self.hasCompleteObservedResults(Self.unobservedSiriAttempts(for: scenario)))
    }

    func testSemanticAssertionIsHandedToHostForReview() throws {
        var scenario = testScenario()
        scenario.assertions = [.init(
            id: UUID(),
            kind: .semanticRubric,
            observationKey: "visibleResponse",
            expectedValue: nil,
            required: true,
            applicableLanes: [.siri]
        )]

        let lane = result(
            for: .siri,
            scenario: scenario,
            observations: ["visibleResponse": .string("Opened the packing note")],
            startedAt: Date()
        )

        XCTAssertEqual(lane.outcome, .needsReview)
        XCTAssertEqual(lane.assertionResults.first?.observedValue, .string("Opened the packing note"))
    }

    func testSiriCompletionUsesCorrelationAndRetainsWrongResult() {
        let observations: [String: IntentLabValue] = [
            "invocationContext": .string("siri-attempt-1"),
            "selectedNoteID": .string("garden-001"),
        ]

        XCTAssertEqual(
            SiriProbe.correlatedCompletion(
                observations: observations,
                expectedContext: "siri-attempt-1"
            )?["selectedNoteID"],
            .string("garden-001")
        )
    }

    func testScenarioDeadlineIsDecodedForTheDeviceHarness() throws {
        let json = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "version":1,
          "definitionDigest":"digest",
          "target":{"bundleIdentifier":"dev.example.fixture"},
          "goal":{"requestText":"Open the note","languageCode":"en-GB"},
          "fixture":{"id":"notes","version":"1","digest":"fixture","preparationOperation":"reset","cleanupOperation":"reset"},
          "directControl":{"intentIdentifier":"OpenNoteIntent","parameters":[],"outputFields":[]},
          "assertions":[],
          "coverage":{"appFeature":"optional","intentIntegration":"required","siri":"required","siriAttemptCount":1},
          "safety":{"deadlineSeconds":7.25}
        }
        """
        let scenario = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: Data(json.utf8))
        XCTAssertEqual(SiriProbe.waitTimeout(for: scenario.safety), 7.25)
    }

    func testSiriActivationRecoveryRequiresCurrentActionEvidence() {
        let timeout = "Timed out waiting for Siri to activate"
        let valid: [String: IntentLabValue] = [
            "invocationContext": .string("current"),
            "selectedNoteID": .string("packing-001"),
            "applicationEvent": .string("OpenNoteIntent:packing-001")
        ]
        XCTAssertTrue(SiriProbe.recoverableActivationTimeout(description: timeout, osMajor: 27, observations: valid, expectedContext: "current"))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(description: timeout, osMajor: 27, observations: valid, expectedContext: "previous"))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(description: "Other failure", osMajor: 27, observations: valid, expectedContext: "current"))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(description: timeout, osMajor: 28, observations: valid, expectedContext: "current"))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(description: timeout, osMajor: 27, observations: nil, expectedContext: "current"))
        for key in ["invocationContext", "selectedNoteID", "applicationEvent"] {
            var missing = valid
            missing[key] = .string("none")
            XCTAssertFalse(SiriProbe.recoverableActivationTimeout(description: timeout, osMajor: 27, observations: missing, expectedContext: "current"), key)
        }
    }

    func testSiriChooserExcludesUnderlyingAppText() {
        let text: [(label: String, bounds: CGRect)] = [
            ("Which one?", CGRect(x: 0.1, y: 0.91, width: 0.3, height: 0.02)),
            ("Packing note", CGRect(x: 0.1, y: 0.85, width: 0.3, height: 0.02)),
            ("Packing notes", CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.02)),
            ("Intent Lab Fixture", CGRect(x: 0.1, y: 0.72, width: 0.3, height: 0.02)),
            ("Fixture", CGRect(x: 0.3, y: 0.03, width: 0.1, height: 0.02))
        ]
        let request = "Open the packing note in Intent Lab Fixture"
        XCTAssertNil(SiriProbe.matchingChoice(request: request, choices: text.map(\.label)))
        XCTAssertEqual(SiriProbe.chooserRow(request: request, applicationName: "Intent Lab Fixture", text: text)?.label, "Packing note")
        var symbolPrefixed = text
        symbolPrefixed[3].label = "• Intent Lab Fixture"
        XCTAssertEqual(SiriProbe.chooserRow(request: request, applicationName: "Intent Lab Fixture", text: symbolPrefixed)?.label, "Packing note")
        XCTAssertNil(SiriProbe.chooserRow(request: request, applicationName: "Missing app", text: text))
        XCTAssertNil(SiriProbe.chooserRow(request: request, applicationName: "Intent Lab Fixture", text: Array(text.dropFirst())))
    }

    func testSiriChoiceMatchesWholePhraseWithoutGuessing() {
        XCTAssertEqual(SiriProbe.matchingChoice(request: "Open the packing note in Intent Lab Fixture", choices: ["Packing note", "Packing notes", "Garden note"]), "Packing note")
        XCTAssertEqual(SiriProbe.matchingChoice(request: "Open the packing notes", choices: ["Packing note", "Packing notes"]), "Packing notes")
        XCTAssertNil(SiriProbe.matchingChoice(request: "Open a note", choices: ["Packing note", "Garden note"]))
        XCTAssertNil(SiriProbe.matchingChoice(request: "Packing note or garden note", choices: ["Packing note", "Garden note"]))
    }

    func testSiriPermissionMustClearBeforeCorrelatedCompletion() {
        XCTAssertFalse(SiriProbe.completionReady(promptIsVisible: true, observedContext: "attempt", expectedContext: "attempt"))
        XCTAssertFalse(SiriProbe.completionReady(promptIsVisible: false, observedContext: "previous", expectedContext: "attempt"))
        XCTAssertFalse(SiriProbe.completionReady(promptIsVisible: false, observedContext: nil, expectedContext: "attempt"))
        XCTAssertTrue(SiriProbe.completionReady(promptIsVisible: false, observedContext: "attempt", expectedContext: "attempt"))
    }

    func testCheckpointKeepsEverySiriAttemptUnobserved() {
        var scenario = testScenario()
        scenario.coverage.siriAttemptCount = 3
        let results = Self.unobservedSiriAttempts(for: scenario)

        XCTAssertEqual(results.map(\.attempt), [1, 2, 3])
        XCTAssertTrue(results.allSatisfy {
            $0.lane == .siri && $0.outcome == .notObserved
                && $0.executionStatus == .invalidEvidence && $0.observations.isEmpty
        })
    }

    func testFixtureResetAndObservableReady() {
        let application = XCUIApplication()
        application.launchArguments = ["-intent-lab-reset", "-intent-lab-context", "recovery-check"]
        application.launch()
        let observations = FixtureBridge.observations(from: application)

        XCTAssertEqual(observations["noteStoreMutationCount"], .integer(0))
        XCTAssertEqual(observations["selectedNoteID"], .string("none"))
    }

    func testFixtureEntityResolutionAndIntentExecution() async throws {
        let application = XCUIApplication()
        let context = "direct-resolution-\(UUID().uuidString)"
        application.launchArguments = ["-intent-lab-reset", "-intent-lab-context", context]
        application.launch()
        addTeardownBlock { await MainActor.run { application.terminate() } }
        let definitions = IntentDefinitions(bundleIdentifier: "com.coryparry.IntentLabFixture")
        let note = definitions.entities["NoteEntity"].makeReference(identifier: "packing-001")
        let intent = definitions.intents["OpenNoteIntent"].makeIntent(note: note)
        let result = try await intent.run()
        let selectedID: String = try result.value
        XCTAssertEqual(selectedID, "packing-001")
        let observations = FixtureBridge.observations(from: application)
        XCTAssertEqual(observations["selectedNoteID"], .string("packing-001"))
        XCTAssertEqual(observations["invocationContext"], .string(context))
    }

    func testSiriShortcutOpensPackingNote() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This Siri shortcut check requires a configured physical iPhone.")
        #endif
        let application = XCUIApplication()
        let context = "siri-permission-\(UUID().uuidString)"
        application.launchArguments = ["-intent-lab-reset", "-intent-lab-context", context]
        application.launch()
        addTeardownBlock { await MainActor.run { application.terminate() } }
        defer { _ = EvidenceAttachmentWriter.attachScreenshot(to: self) }
        let observations = try SiriProbe.run(
            request: "Open the packing note in Intent Lab Fixture",
            application: application,
            expectedContext: context,
            safety: .init(deadlineSeconds: 60),
            testCase: self
        )
        XCTAssertEqual(observations["selectedNoteID"], .string("packing-001"))
        XCTAssertEqual(observations["invocationContext"], .string(context))
        XCTAssertNil(observations["siriDisambiguationSelection"])
        XCTAssertEqual(observations["applicationEvent"], .string("OpenNoteIntent:packing-001"))
    }

    func testIntentLabScenario() throws {
        let scenario: IntentLabScenario = try load("IntentLabScenario")
        let invocation: IntentLabInvocation = try load("IntentLabInvocation")
        guard scenario.schemaVersion == 1,
              invocation.harnessVersion == "intent-lab-v1",
              invocation.scenarioDigest == scenario.definitionDigest,
              let appProduct = invocation.appProduct,
              let testProduct = invocation.testProduct else {
            throw XCTSkip("The host did not embed a fully bound Intent Lab invocation.")
        }
        var results: [IntentLabLaneResult] = []

        if scenario.coverage.intentIntegration != .notApplicable {
            let context = "intent-\(invocation.id.uuidString)"
            let application = FixtureBridge.resetAndLaunch(
                bundleIdentifier: scenario.target.bundleIdentifier,
                context: context
            )
            let directStart = Date()
            do {
                var observations = try directObservations(for: scenario)
                observations.merge(FixtureBridge.observations(from: application)) { direct, _ in direct }
                results.append(result(for: .intentIntegration, scenario: scenario, observations: observations, startedAt: directStart))
            } catch {
                // A cancelled async intent may still finish. Do not give that
                // action a later Siri attempt's fixture context.
                if error is DirectIntentTimeout { throw error }
                results.append(failed(for: .intentIntegration, scenario: scenario, error: error, startedAt: directStart))
            }
        }

        // XCTest can terminate this method inside siriService.activate without throwing.
        // Persist completed direct observations before entering that API. Siri attempts
        // remain explicitly unobserved until a final envelope replaces this checkpoint.
        if scenario.coverage.siri != .notApplicable {
            let checkpoint = evidenceEnvelope(
                scenario: scenario,
                invocation: invocation,
                appProduct: appProduct,
                testProduct: testProduct,
                results: results + Self.unobservedSiriAttempts(for: scenario)
            )
            try EvidenceAttachmentWriter.attach(checkpoint, to: self, checkpoint: true)
        }

        if scenario.coverage.siri != .notApplicable {
            let attemptCount = scenario.coverage.siriAttemptCount ?? 3
            var sequence = SiriAttemptSequence()
            for attempt in 1...attemptCount {
                let context = "siri-\(invocation.id.uuidString)-\(attempt)"
                let siriStart = Date()
                do {
                    let observations = try sequence.run {
                        let application = FixtureBridge.resetAndLaunch(
                            bundleIdentifier: scenario.target.bundleIdentifier,
                            context: context
                        )
                        return try SiriProbe.run(
                            request: scenario.goal.requestText,
                            application: application,
                            expectedContext: context,
                            safety: scenario.safety,
                            testCase: self
                        )
                    }
                    let screenshot = EvidenceAttachmentWriter.attachScreenshot(to: self)
                    results.append(result(
                        for: .siri,
                        scenario: scenario,
                        observations: observations,
                        startedAt: siriStart,
                        attempt: attempt,
                        artifacts: [screenshot]
                    ))
                } catch {
                    let screenshot = EvidenceAttachmentWriter.attachScreenshot(to: self)
                    results.append(failed(
                        for: .siri,
                        scenario: scenario,
                        error: error,
                        startedAt: siriStart,
                        attempt: attempt,
                        artifacts: [screenshot]
                    ))
                }
            }
        }

        let envelope = evidenceEnvelope(
            scenario: scenario,
            invocation: invocation,
            appProduct: appProduct,
            testProduct: testProduct,
            results: results
        )
        try EvidenceAttachmentWriter.attach(envelope, to: self)
        XCTAssertTrue(Self.hasCompleteObservedResults(results))
    }

    private static func hasCompleteObservedResults(_ results: [IntentLabLaneResult]) -> Bool {
        // An observed assertion mismatch fails the scenario, not XCTest's evidence capture.
        !results.isEmpty && results.allSatisfy {
            $0.executionStatus == .completed &&
                ($0.outcome == .passed || $0.outcome == .failed || $0.outcome == .needsReview)
        }
    }

    // Keep Siri on XCTest's synchronous invocation stack, where its Objective-C
    // interruption can be recovered before it abandons the test's Swift task.
    private func directObservations(for scenario: IntentLabScenario) throws -> [String: IntentLabValue] {
        let completed = XCTestExpectation(description: "Direct intent completed")
        var result: Result<[String: IntentLabValue], Error>?
        let task = Task { @MainActor in
            do { result = .success(try await IntentProbe.run(scenario)) }
            catch { result = .failure(error) }
            completed.fulfill()
        }
        defer { task.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: scenario.safety.deadlineSeconds) == .completed,
              let result else {
            throw DirectIntentTimeout()
        }
        return try result.get()
    }

    private struct DirectIntentTimeout: LocalizedError {
        var errorDescription: String? { "The direct intent did not finish before the scenario deadline." }
    }

    private func evidenceEnvelope(
        scenario: IntentLabScenario,
        invocation: IntentLabInvocation,
        appProduct: IntentLabProductIdentity,
        testProduct: IntentLabProductIdentity,
        results: [IntentLabLaneResult]
    ) -> IntentLabEvidenceEnvelope {
        let process = ProcessInfo.processInfo
        return IntentLabEvidenceEnvelope(
            invocation: invocation,
            sourceBundleIdentifier: scenario.target.bundleIdentifier,
            observedAppProduct: appProduct,
            observedTestProduct: testProduct,
            environment: .init(
                xcodeVersion: process.environment["XCODE_VERSION_ACTUAL"] ?? "unknown",
                sdkVersion: process.environment["SDK_VERSION"] ?? "unknown",
                deviceModel: process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "physical iPhone",
                operatingSystem: process.operatingSystemVersionString,
                operatingSystemBuild: nil,
                languageCode: Locale.current.language.languageCode?.identifier ?? scenario.goal.languageCode,
                regionCode: Locale.current.region?.identifier ?? "unknown",
                timeZoneIdentifier: TimeZone.current.identifier,
                siriConfiguration: "developer-declared by host setup",
                siriConfigurationSource: "manuallySupplied",
                executedAt: Date()
            ),
            testCount: 1,
            results: results
        )
    }

    static func unobservedSiriAttempts(for scenario: IntentLabScenario, at date: Date = Date()) -> [IntentLabLaneResult] {
        guard scenario.coverage.siri != .notApplicable else { return [] }
        return (1...(scenario.coverage.siriAttemptCount ?? 3)).map { attempt in
            IntentLabLaneResult(
                caseID: scenario.id,
                attempt: attempt,
                lane: .siri,
                executionStatus: .invalidEvidence,
                outcome: .notObserved,
                startedAt: date,
                completedAt: date,
                observations: [:],
                assertionResults: [],
                diagnostic: "XCTest stopped before final Siri evidence was attached.",
                proposedCause: nil,
                artifacts: []
            )
        }
    }

    private func result(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        observations: [String: IntentLabValue],
        startedAt: Date,
        attempt: Int = 1,
        artifacts: [IntentLabArtifactReference] = []
    ) -> IntentLabLaneResult {
        let assertions = scenario.assertions.filter {
            $0.applicableLanes?.contains(lane) ?? (lane != .appFeature)
        }
        let checks = assertions.map { assertion in
            let observed = observations[assertion.observationKey]
            if assertion.kind == .semanticRubric {
                return IntentLabAssertionResult(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: observed,
                    message: observed == nil
                        ? "Required semantic evidence was not captured."
                        : "Semantic evidence requires host assessment."
                )
            }
            return IntentLabAssertionResult(
                assertionID: assertion.id,
                passed: observed == assertion.expectedValue,
                observedValue: observed,
                message: observed == assertion.expectedValue ? "Matched the frozen expectation." : "Observed value did not match."
            )
        }
        let required = assertions.filter(\.required)
        let semanticIDs = Set(required.filter { $0.kind == .semanticRubric }.map(\.id))
        let missingSemantic = required.contains {
            $0.kind == .semanticRubric && observations[$0.observationKey] == nil
        }
        let deterministicFailure = checks.contains { check in
            !semanticIDs.contains(check.assertionID)
                && required.contains(where: { $0.id == check.assertionID })
                && !check.passed
        }
        let outcome: IntentLabOutcome
        if deterministicFailure || missingSemantic {
            outcome = .failed
        } else if !semanticIDs.isEmpty {
            outcome = .needsReview
        } else {
            outcome = .passed
        }
        return .init(
            caseID: scenario.id, attempt: attempt, lane: lane, executionStatus: .completed,
            outcome: outcome, startedAt: startedAt, completedAt: Date(),
            observations: observations, assertionResults: checks,
            diagnostic: nil, proposedCause: nil, artifacts: artifacts,
            observationSources: Dictionary(uniqueKeysWithValues: observations.keys.map {
                ($0, lane == .siri ? "applicationInstrumentation" : "appIntentsTesting")
            })
        )
    }

    private func failed(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        error: Error,
        startedAt: Date,
        attempt: Int = 1,
        artifacts: [IntentLabArtifactReference] = []
    ) -> IntentLabLaneResult {
        let executionStatus: IntentLabExecutionStatus
        switch error {
        case SiriProbeError.priorAttemptUnresolved:
            executionStatus = .invalidEvidence
        case SiriProbeError.outcomeNotObserved:
            executionStatus = .timedOut
        case is SiriProbeError:
            executionStatus = .blockedByEnvironment
        default:
            executionStatus = .completed
        }
        return .init(
            caseID: scenario.id, attempt: attempt, lane: lane,
            executionStatus: executionStatus,
            outcome: .notObserved, startedAt: startedAt, completedAt: Date(), observations: [:],
            assertionResults: [], diagnostic: error.localizedDescription,
            proposedCause: nil, artifacts: artifacts, observationSources: nil
        )
    }

    private func load<Value: Decodable>(_ name: String) throws -> Value {
        if let data = try IntentLabPayloadLoader.environmentData(named: name) {
            return try JSONDecoder.intentLab.decode(Value.self, from: data)
        }
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder.intentLab.decode(Value.self, from: Data(contentsOf: url))
    }

    private func testScenario() -> IntentLabScenario {
        IntentLabScenario(
            id: UUID(),
            version: 1,
            definitionDigest: "test-digest",
            target: .init(bundleIdentifier: "dev.example.fixture"),
            goal: .init(requestText: "Open the packing note", languageCode: "en-GB"),
            fixture: .init(
                id: "notes",
                version: "1",
                digest: "fixture-digest",
                preparationOperation: "reset",
                cleanupOperation: "reset"
            ),
            directControl: .init(intentIdentifier: "OpenNoteIntent", parameters: [], outputFields: []),
            assertions: [],
            coverage: .init(
                appFeature: .optional,
                intentIntegration: .required,
                siri: .required,
                siriAttemptCount: 1
            ),
            safety: .init(deadlineSeconds: 60)
        )
    }
}

private extension IntentLabValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
