import AppIntentsTesting
import Foundation
import CryptoKit
import IntentLabContracts
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabScenarioRunner {
    public static let packageVersion = "0.2.0-dev"
    private static var attemptFence = IntentLabAttemptFence()

    /// Connection inspection reads bundled configuration only. It never launches the app.
    public static func checkConnection(testCase: XCTestCase, integration: any IntentLabIntegration) throws {
        let (_, identity, declaration) = try loadDeclaration(testCase: testCase)
        for capability in declaration.capabilities where !integration.supportedCapabilities.contains(capability) {
            throw IntentLabDeclarationError.missingCapability(capability)
        }
        let receipt = IntentLabConnectionReceipt(
            schemaVersion: 1,
            integration: identity,
            targetBundleIdentifier: declaration.targetBundleIdentifier,
            projectIdentity: declaration.projectIdentity,
            targetIdentity: declaration.targetIdentity,
            testBundleIdentifier: Bundle(for: type(of: testCase)).bundleIdentifier ?? "unknown",
            harnessProtocol: "intent-lab-v2",
            runnerPackageVersion: packageVersion,
            capabilities: declaration.capabilities.sorted(),
            inspectedAt: Date()
        )
        let data = try JSONEncoder.intentLab.encode(receipt)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "IntentLabConnectionReceipt-\(UUID().uuidString).json"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    @discardableResult
    public static func run(
        testCase: XCTestCase,
        integration: any IntentLabIntegration,
        scenario scenarioOverride: IntentLabScenario? = nil,
        invocation invocationOverride: IntentLabInvocation? = nil
    ) throws -> IntentLabEvidenceEnvelope {
        try attemptFence.validateNewAttempt()
        let scenario: IntentLabScenario = try scenarioOverride ?? load("IntentLabScenario", testCase: testCase)
        let invocation: IntentLabInvocation = try invocationOverride ?? load("IntentLabInvocation", testCase: testCase)
        try scenario.validateContract(harnessVersion: invocation.harnessVersion)
        var declaration: IntentLabIntegrationDeclaration?
        if scenario.schemaVersion == 2 {
            let (_, identity, loaded) = try loadDeclaration(testCase: testCase)
            guard scenario.integration == identity, invocation.integration == identity,
                  let requiredCapabilities = invocation.requiredCapabilities,
                  Set(loaded.capabilities).isSubset(of: integration.supportedCapabilities),
                  loaded.targetBundleIdentifier == scenario.target.bundleIdentifier,
                  let action = loaded.actions.first(where: { $0.id == scenario.directControl.intentIdentifier }),
                  loaded.preparationOperations.contains(scenario.fixture.preparationOperation) else {
                throw IntentLabDeclarationError.mismatchedIdentity
            }
            guard action.parameters.allSatisfy({ declared in
                !declared.required || scenario.directControl.parameters.contains(where: { parameter in
                    guard parameter.name == declared.name else { return false }
                    switch parameter.presence {
                    case .missing, .value(.null): return false
                    case .value: return true
                    }
                })
            }), scenario.directControl.parameters.allSatisfy({ parameter in
                action.parameters.contains(where: { declared in
                    guard declared.name == parameter.name,
                          declared.type == parameter.type,
                          declared.required == !parameter.isOptional else { return false }
                    switch parameter.presence {
                    case .missing: return !declared.required
                    case .value(.null): return parameter.isOptional
                    case .value(let value): return declared.type.accepts(value)
                    }
                })
            }), scenario.directControl.outputFields.allSatisfy({ field in
                loaded.resultProjections.contains(where: {
                    $0.id == field.name && $0.type == field.type && $0.path == field.path
                })
            }) else { throw IntentLabDeclarationError.mismatchedIdentity }
            for required in requiredCapabilities where !loaded.capabilities.contains(required) {
                throw IntentLabDeclarationError.missingCapability(required)
            }
            for planned in scenario.observationPlan ?? [] where planned.source != .intentResult {
                guard loaded.observers.contains(where: {
                    $0.id == planned.id && $0.source == planned.source
                        && $0.operationID == planned.operationID && $0.selector == planned.selector
                }) else { throw IntentLabDeclarationError.mismatchedIdentity }
            }
            declaration = loaded
            if integration is IntentLabBasicIntegration,
               (scenario.safety.mutationPolicy != .readOnly || loaded.isolation.kind != "readOnly") {
                throw IntentLabIntegrationError.unsupportedPreparation("mutating Basic check without isolated preparation")
            }
        }
        guard
              invocation.scenarioDigest == scenario.definitionDigest,
              let appProduct = invocation.appProduct,
              let testProduct = invocation.testProduct else {
            throw XCTSkip("The host did not embed a fully bound Intent Lab invocation.")
        }
        var results: [IntentLabLaneResult] = []

        if scenario.coverage.intentIntegration != .notApplicable {
            let context = "intent-\(invocation.id.uuidString)"
            let directStart = Date()
            var directApplication: XCUIApplication?
            do {
                let application = try integration.prepare(
                    bundleIdentifier: scenario.target.bundleIdentifier,
                    context: context,
                    operationID: scenario.fixture.preparationOperation
                )
                directApplication = application
                let baseline = try integration.observe(
                    application: application,
                    declaration: declaration,
                    deadlineSeconds: scenario.safety.deadlineSeconds
                )
                var observations = try directObservations(for: scenario)
                let stateObservations = try integration.observe(
                    application: application,
                    declaration: declaration,
                    deadlineSeconds: scenario.safety.deadlineSeconds
                )
                if scenario.schemaVersion == 2,
                   stateObservations.keys.contains(where: { observations[$0] != nil }) {
                    throw IntentLabDeclarationError.mismatchedIdentity
                }
                observations.merge(stateObservations) { direct, _ in direct }
                results.append(result(for: .intentIntegration, scenario: scenario, observations: observations, baseline: baseline, integration: integration, declaration: declaration, context: context, startedAt: directStart))
                application.terminate()
                directApplication = nil
            } catch {
                // A cancelled async intent may still finish. Do not give that
                // action a later Siri attempt's fixture context.
                directApplication?.terminate()
                if error is DirectIntentTimeout {
                    attemptFence.recordUnresolvedDirectTimeout()
                    let checkpoint = evidenceEnvelope(
                        scenario: scenario, invocation: invocation,
                        appProduct: appProduct, testProduct: testProduct,
                        results: [failed(for: .intentIntegration, scenario: scenario, error: error, startedAt: directStart)]
                            + unobservedSiriAttempts(for: scenario),
                        declaration: declaration
                    )
                    try EvidenceAttachmentWriter.attach(checkpoint, to: testCase, checkpoint: true)
                    throw error
                }
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
                results: results + unobservedSiriAttempts(for: scenario),
                declaration: declaration
            )
            try EvidenceAttachmentWriter.attach(checkpoint, to: testCase, checkpoint: true)
        }

        if scenario.coverage.siri != .notApplicable {
            let attemptCount = scenario.coverage.siriAttemptCount ?? 3
            var sequence = SiriAttemptSequence()
            for attempt in 1...attemptCount {
                let context = "siri-\(invocation.id.uuidString)-\(attempt)"
                let siriStart = Date()
                do {
                    let observations = try sequence.run {
                        let application = try integration.prepare(
                            bundleIdentifier: scenario.target.bundleIdentifier,
                            context: context,
                            operationID: scenario.fixture.preparationOperation
                        )
                        guard !scenario.goal.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw SiriProbeError.missingRequest
                        }
                        try attemptFence.beginSiriAttempt()
                        let completedObservations = try SiriProbe.run(
                            request: scenario.goal.requestText,
                            application: application,
                            expectedContext: context,
                            safety: scenario.safety,
                            testCase: testCase,
                            integration: integration,
                            declaration: declaration
                        )
                        attemptFence.recordVerifiedSiriCompletion()
                        return completedObservations
                    }
                    let screenshot = EvidenceAttachmentWriter.attachScreenshot(to: testCase)
                    results.append(result(
                        for: .siri,
                        scenario: scenario,
                        observations: observations,
                        baseline: nil,
                        integration: integration,
                        declaration: declaration,
                        context: context,
                        startedAt: siriStart,
                        attempt: attempt,
                        artifacts: [screenshot]
                    ))
                } catch {
                    let screenshot = EvidenceAttachmentWriter.attachScreenshot(to: testCase)
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
            results: results,
            declaration: declaration
        )
        try EvidenceAttachmentWriter.attach(envelope, to: testCase)
        return envelope
    }

    // Keep Siri on XCTest's synchronous invocation stack, where its Objective-C
    // interruption can be recovered before it abandons the test's Swift task.
    private static func directObservations(for scenario: IntentLabScenario) throws -> [String: IntentLabValue] {
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

    private static func evidenceEnvelope(
        scenario: IntentLabScenario,
        invocation: IntentLabInvocation,
        appProduct: IntentLabProductIdentity,
        testProduct: IntentLabProductIdentity,
        results: [IntentLabLaneResult],
        declaration: IntentLabIntegrationDeclaration?
    ) -> IntentLabEvidenceEnvelope {
        let process = ProcessInfo.processInfo
        return IntentLabEvidenceEnvelope(
            schemaVersion: scenario.schemaVersion ?? 1,
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
            results: results,
            integration: scenario.schemaVersion == 2 ? scenario.integration : nil,
            runnerPackageVersion: scenario.schemaVersion == 2 ? packageVersion : nil,
            negotiatedCapabilities: declaration?.capabilities.sorted()
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

    private static func result(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        observations: [String: IntentLabValue],
        baseline: [String: IntentLabValue]?,
        integration: any IntentLabIntegration,
        declaration: IntentLabIntegrationDeclaration?,
        context: String,
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
                passed: observed != nil && observed == assertion.expectedValue,
                observedValue: observed,
                message: observed != nil && observed == assertion.expectedValue ? "Matched the frozen expectation." : "Observed value did not match."
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
        let planned = scenario.observationPlan ?? []
        let resultKeys = Set(scenario.directControl.outputFields.map(\.name))
        let observationSource: (String) -> String = { key in
            if let observer = declaration?.observers.first(where: { $0.id == key }),
               (observer.source == .entityQuery || observer.source == .valueQuery),
               (declaration?.queryOperations ?? []).contains(where: {
                   $0.id == observer.operationID && $0.source == observer.source
               }) {
                return observer.source.rawValue
            }
            return integration.source(for: key)
        }
        let returnedChecked = assertions.contains {
            $0.kind == .returnedField && observations[$0.observationKey] != nil
                && resultKeys.contains($0.observationKey)
        }
        let stateChecked = assertions.contains { assertion in
            guard assertion.required, let observed = observations[assertion.observationKey],
                  let plan = planned.first(where: { $0.id == assertion.observationKey }),
                  plan.source != .intentResult,
                  let observer = declaration?.observers.first(where: { $0.id == plan.id }),
                  observer.type.accepts(observed) else { return false }
            let freshCompletion = integration.completed(observations: observations, context: context)
                || (lane == .intentIntegration && baseline?[assertion.observationKey] != nil
                    && (baseline?[assertion.observationKey] != observed || assertion.kind == .noMutation))
            guard freshCompletion else { return false }
            let actual = observationSource(assertion.observationKey)
            let expected = plan.source == .uiElement ? "accessibleUI" : plan.source.rawValue
            return actual == expected
        }
        var claims: [IntentLabProofClaim] = [.executionCompleted]
        if lane == .intentIntegration && returnedChecked { claims.append(.returnedValueChecked) }
        if stateChecked { claims.append(.applicationStateChecked) }
        let missingClaim = scenario.schemaVersion == 2
            && (scenario.requiredClaims ?? []).contains(where: {
                !($0 == .returnedValueChecked && lane == .siri) && !claims.contains($0)
            })
        if deterministicFailure || missingSemantic {
            outcome = .failed
        } else if missingClaim || (scenario.schemaVersion == 2 && lane == .siri && !stateChecked) {
            outcome = .notObserved
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
                ($0, resultKeys.contains($0) && lane == .intentIntegration
                    ? "appIntentsTesting"
                    : $0 == "recognizedRequest" ? "siriRecognizedText" : observationSource($0))
            }),
            claims: scenario.schemaVersion == 2 ? claims : nil
        )
    }

    private static func failed(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        error: Error,
        startedAt: Date,
        attempt: Int = 1,
        artifacts: [IntentLabArtifactReference] = []
    ) -> IntentLabLaneResult {
        let executionStatus: IntentLabExecutionStatus
        switch error {
        case is DirectIntentTimeout:
            executionStatus = .timedOut
        case SiriProbeError.priorAttemptUnresolved:
            executionStatus = .invalidEvidence
        case SiriProbeError.outcomeNotObserved:
            executionStatus = .timedOut
        case is SiriProbeError:
            executionStatus = .blockedByEnvironment
        default:
            executionStatus = .invalidEvidence
        }
        return .init(
            caseID: scenario.id, attempt: attempt, lane: lane,
            executionStatus: executionStatus,
            outcome: .notObserved, startedAt: startedAt, completedAt: Date(), observations: [:],
            assertionResults: [], diagnostic: error.localizedDescription,
            proposedCause: nil, artifacts: artifacts, observationSources: nil
        )
    }

    private static func load<Value: Decodable>(_ name: String, testCase: XCTestCase) throws -> Value {
        if let data = try IntentLabPayloadLoader.environmentData(named: name) {
            return try JSONDecoder.intentLab.decode(Value.self, from: data)
        }
        let bundle = Bundle(for: type(of: testCase))
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder.intentLab.decode(Value.self, from: Data(contentsOf: url))
    }

    private static func loadDeclaration(testCase: XCTestCase) throws -> (Data, IntentLabIntegrationIdentity, IntentLabIntegrationDeclaration) {
        let bundle = Bundle(for: type(of: testCase))
        guard let url = bundle.url(forResource: "IntentLabIntegration", withExtension: "json") else {
            throw IntentLabDeclarationError.missing
        }
        let data = try Data(contentsOf: url)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        try declaration.validate()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = IntentLabIntegrationIdentity(id: declaration.id, version: declaration.version, digest: digest)
        return (data, identity, declaration)
    }

}

private struct IntentLabConnectionReceipt: Encodable {
    var schemaVersion: Int
    var integration: IntentLabIntegrationIdentity
    var targetBundleIdentifier: String
    var projectIdentity: String
    var targetIdentity: String
    var testBundleIdentifier: String
    var harnessProtocol: String
    var runnerPackageVersion: String
    var capabilities: [String]
    var inspectedAt: Date
}
