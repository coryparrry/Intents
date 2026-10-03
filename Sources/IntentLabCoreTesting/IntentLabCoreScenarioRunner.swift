import Foundation
import CryptoKit
import IntentLabContracts
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabScenarioEngine {
    public static let packageVersion = "0.2.0-dev"
    private static var attemptFence = IntentLabAttemptFence()

    /// Exercises only declared readiness support, then retains the result as an
    /// XCTest attachment. The CoreTesting entry point stays usable by Siri-only
    /// consumers; AppIntentsTesting callers may provide the direct readiness probe.
    public static func testIntentLabReadiness(
        testCase: XCTestCase,
        integration: any IntentLabSiriIntegration,
        directReadinessExecutor: (@MainActor (
            String,
            IntentLabIntegrationDeclaration,
            String,
            TimeInterval
        ) throws -> [String: IntentLabValue])? = nil,
        deadlineSeconds: TimeInterval = 30
    ) throws {
        var identity: IntentLabIntegrationIdentity?
        var declaration: IntentLabIntegrationDeclaration?
        var declarationFailure: String?
        do {
            let (_, loadedIdentity, loadedDeclaration) = try loadDeclaration(testCase: testCase)
            identity = loadedIdentity
            declaration = loadedDeclaration
        } catch {
            declarationFailure = error.localizedDescription
        }

        var routes: [String: IntentLabReadinessRoute] = [
            IntentLabReadinessRouteKey.appFeature: IntentLabReadinessRoute(
                status: .notYetVerified,
                supportType: "harmlessFeatureProbe",
                detail: "Feature readiness has not been assessed."
            )
        ]

        if let declaration {
            let directContext = readinessContext(for: IntentLabReadinessRouteKey.intentIntegration)
            var directStatus: IntentLabReadinessStatus = .notYetVerified
            var directObservations: [String: IntentLabValue]?
            var directFailure: String?
            var observersReady = false
            var observerFailure: String?
            if declaration.readinessControl == nil {
                directStatus = .setupRequired
                routes[IntentLabReadinessRouteKey.intentIntegration] = IntentLabReadinessRoute(
                    status: .setupRequired,
                    supportType: "appIntentsTestingReadiness",
                    context: directContext,
                    detail: "Declare a payload-free readiness control to probe the installed app."
                )
            } else if let directReadinessExecutor {
                do {
                    let observations = try directReadinessExecutor(
                        declaration.targetBundleIdentifier,
                        declaration,
                        directContext,
                        deadlineSeconds
                    )
                    directObservations = observations
                    let status = IntentLabReadinessStatusPolicy.direct(
                        controlDeclared: true,
                        executorAvailable: true,
                        observations: observations
                    )
                    directStatus = status
                    if status != .ready {
                        directFailure = "The declared readiness intent did not return readiness.ready=true."
                    }
                    routes[IntentLabReadinessRouteKey.intentIntegration] = IntentLabReadinessRoute(
                        status: status,
                        operationID: declaration.readinessControl?.operationID,
                        supportType: "appIntentsTestingReadiness",
                        context: directContext,
                        observations: observations,
                        detail: status == .ready
                            ? "The harmless test-only readiness intent returned a typed ready value."
                            : "The declared readiness intent did not return readiness.ready=true."
                    )
                } catch {
                    directStatus = .environmentBlocked
                    directFailure = error.localizedDescription
                    routes[IntentLabReadinessRouteKey.intentIntegration] = IntentLabReadinessRoute(
                        status: .environmentBlocked,
                        operationID: declaration.readinessControl?.operationID,
                        supportType: "appIntentsTestingReadiness",
                        context: directContext,
                        detail: error.localizedDescription
                    )
                }
            } else {
                routes[IntentLabReadinessRouteKey.intentIntegration] = IntentLabReadinessRoute(
                    status: IntentLabReadinessStatusPolicy.direct(
                        controlDeclared: true,
                        executorAvailable: false,
                        observations: nil
                    ),
                    operationID: declaration.readinessControl?.operationID,
                    supportType: "appIntentsTestingReadiness",
                    context: directContext,
                    detail: "The declaration includes harmless readiness support, but this runner has no AppIntentsTesting transport."
                )
            }

            let siriContext = readinessContext(for: IntentLabReadinessRouteKey.siri)
            let readinessOperation = declaration.isolation.readinessOperationID
                .flatMap { $0.isEmpty ? nil : $0 }
            do {
                let application: XCUIApplication
                if let readinessOperation {
                    application = try integration.prepare(
                        bundleIdentifier: declaration.targetBundleIdentifier,
                        context: siriContext,
                        operationID: readinessOperation
                    )
                } else {
                    // Launch directly when no harmless preparation is declared;
                    // never guess at an app-owned operation ID.
                    application = XCUIApplication(bundleIdentifier: declaration.targetBundleIdentifier)
                    application.launch()
                }
                defer { application.terminate() }
                guard application.state != .notRunning else {
                    throw IntentLabReadinessProbeError.applicationDidNotLaunch
                }
                var observations = try integration.observe(
                    application: application,
                    declaration: declaration,
                    deadlineSeconds: deadlineSeconds
                )
                guard application.state != .notRunning else {
                    throw IntentLabReadinessProbeError.applicationDidNotLaunch
                }
                observersReady = true
                observations["intentlab.readiness.appState"] = .string(String(describing: application.state))
                let hasDeclaredReadinessOperation = readinessOperation != nil
                routes[IntentLabReadinessRouteKey.siri] = IntentLabReadinessRoute(
                    status: IntentLabReadinessStatusPolicy.siri(
                        readinessOperationDeclared: hasDeclaredReadinessOperation,
                        appLaunched: true,
                        observationCompleted: true
                    ),
                    operationID: readinessOperation,
                    supportType: "uiPreparationAndObservation",
                    context: siriContext,
                    observations: observations,
                    detail: hasDeclaredReadinessOperation
                        ? "The Siri test driver launched the app, completed declared preparation, and observed state. OS Siri settings and request routing remain unverified."
                        : "The app was launched and observed, but no harmless readiness preparation operation is declared."
                )
            } catch {
                observerFailure = error.localizedDescription
                routes[IntentLabReadinessRouteKey.siri] = IntentLabReadinessRoute(
                    status: IntentLabReadinessStatusPolicy.siri(
                        readinessOperationDeclared: readinessOperation != nil,
                        appLaunched: false,
                        observationCompleted: false
                    ),
                    operationID: readinessOperation,
                    supportType: "uiPreparationAndObservation",
                    context: siriContext,
                    detail: error.localizedDescription
                )
            }

            let featureControls = declaration.localFeatureControls ?? []
            let featureCapabilities = ["local-feature-controls", "test-only-intent"]
            let featureCapabilitiesDeclared = featureCapabilities.allSatisfy {
                declaration.capabilities.contains($0)
            }
            let featureCapabilitiesSupported = featureCapabilities.allSatisfy {
                integration.supportedCapabilities.contains($0)
            }
            let featureStatus = IntentLabReadinessStatusPolicy.feature(
                directStatus: directStatus,
                featureControlDeclared: !featureControls.isEmpty,
                capabilitiesDeclared: featureCapabilitiesDeclared,
                capabilitiesSupported: featureCapabilitiesSupported,
                observersReady: observersReady
            )
            routes[IntentLabReadinessRouteKey.appFeature] = IntentLabReadinessRoute(
                status: featureStatus,
                operationID: declaration.readinessControl?.operationID,
                supportType: "appIntentsTestingReadiness+localFeatureControls",
                context: directContext,
                observations: directObservations,
                detail: featureReadinessDetail(
                    status: featureStatus,
                    featureControlCount: featureControls.count,
                    observersReady: observersReady,
                    observerFailure: observerFailure,
                    directStatus: directStatus,
                    directFailure: directFailure
                )
            )
        } else {
            let detail = declarationFailure ?? "The integration declaration is unavailable."
            routes[IntentLabReadinessRouteKey.intentIntegration] = IntentLabReadinessRoute(
                status: .setupRequired,
                supportType: "appIntentsTestingReadiness",
                detail: detail
            )
            routes[IntentLabReadinessRouteKey.siri] = IntentLabReadinessRoute(
                status: .setupRequired,
                supportType: "uiPreparationAndObservation",
                detail: detail
            )
            routes[IntentLabReadinessRouteKey.appFeature] = IntentLabReadinessRoute(
                status: .setupRequired,
                supportType: "harmlessFeatureProbe",
                detail: detail
            )
        }

        let receipt = IntentLabReadinessReceipt(
            schemaVersion: 1,
            testName: "testIntentLabReadiness",
            testIdentifier: "\(NSStringFromClass(type(of: testCase)))/testIntentLabReadiness",
            testMethodStarted: true,
            createdAt: Date(),
            targetBundleIdentifier: declaration?.targetBundleIdentifier,
            testBundleIdentifier: Bundle(for: type(of: testCase)).bundleIdentifier ?? "unknown",
            integration: identity,
            routes: routes
        )
        let data = try JSONEncoder.intentLab.encode(receipt)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "IntentLabReadinessReceipt-\(UUID().uuidString).json"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    /// Connection inspection reads bundled configuration only. It never launches the app.
    public static func checkConnection(testCase: XCTestCase, integration: any IntentLabSiriIntegration) throws {
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
        integration: any IntentLabSiriIntegration,
        scenario scenarioOverride: IntentLabScenario? = nil,
        invocation invocationOverride: IntentLabInvocation? = nil,
        directExecutor: (@MainActor (IntentLabScenario) throws -> [String: IntentLabValue])? = nil,
        supportsQueryOperations: Bool = false,
        featureExecutor: (@MainActor (
            String,
            IntentLabIntegrationDeclaration.FeatureControl,
            [String: IntentLabValue],
            String,
            TimeInterval
        ) throws -> [String: IntentLabValue])? = nil
    ) throws -> IntentLabEvidenceEnvelope {
        try attemptFence.validateNewAttempt()
        let scenario: IntentLabScenario = try scenarioOverride ?? load("IntentLabScenario", testCase: testCase)
        let invocation: IntentLabInvocation = try invocationOverride ?? load("IntentLabInvocation", testCase: testCase)
        try scenario.validateContract(harnessVersion: invocation.harnessVersion)
        let runsDirect = scenario.executionScope == nil
            || scenario.executionScope?.lane == .intentIntegration
        let runsSiri = scenario.executionScope == nil
            || scenario.executionScope?.lane == .siri
        let runsFeature = scenario.executionScope?.lane == .appFeature
        try IntentLabRoutePolicy.validate(
            scenario: scenario,
            directExecutorAvailable: directExecutor != nil,
            queryOperationsAvailable: supportsQueryOperations,
            featureExecutorAvailable: featureExecutor != nil
        )
        var declaration: IntentLabIntegrationDeclaration?
        var localFeatureControl: IntentLabIntegrationDeclaration.FeatureControl?
        var localFeatureParameters: [String: IntentLabValue] = [:]
        if scenario.schemaVersion == 2 {
            let (_, identity, loaded) = try loadDeclaration(testCase: testCase)
            guard scenario.integration == identity, invocation.integration == identity,
                  let requiredCapabilities = invocation.requiredCapabilities,
                  Set(loaded.capabilities).isSubset(of: integration.supportedCapabilities),
                  loaded.targetBundleIdentifier == scenario.target.bundleIdentifier,
                  loaded.preparationOperations.contains(scenario.fixture.preparationOperation),
                  loaded.allowsCleanupOperation(
                    scenario.fixture.cleanupOperation,
                    requiresMutationCleanup: scenario.safety.mutationPolicy == .syntheticMutation
                  ) else {
                throw IntentLabDeclarationError.mismatchedIdentity
            }
            if runsFeature {
                guard let featureBinding = scenario.featureBinding,
                      let featureRequirement = scenario.actionRequirements?.first(where: {
                          $0.lane == .appFeature && $0.kind == .productionService
                      }),
                      invocation.featureBackend == "projectLocalTestControl",
                      invocation.requiredCapabilities?.contains("local-feature-controls") == true,
                      integration.supportedCapabilities.contains("local-feature-controls"),
                      loaded.capabilities.contains("local-feature-controls") else {
                    throw IntentLabDeclarationError.mismatchedIdentity
                }
                var control = try loaded.localFeatureControl(
                    featureID: featureBinding.featureID,
                    interfaceDigest: featureBinding.interfaceDigest,
                    operationID: featureRequirement.operationID
                )
                let parameters = try resolveFeatureParameters(
                    featureBinding.inputMapping,
                    against: control.parameters
                )
                guard featureBinding.outputProjections.allSatisfy({ field in
                    control.outputProjections.contains(where: {
                        $0.id == field.name && $0.type == field.type && $0.path == field.path
                    })
                      }) else { throw IntentLabDeclarationError.mismatchedIdentity }
                let selectedProjectionIDs = Set(featureBinding.outputProjections.map(\.name))
                control.outputProjections = control.outputProjections.filter {
                    selectedProjectionIDs.contains($0.id)
                }
                localFeatureControl = control
                localFeatureParameters = parameters
            } else {
                guard let action = loaded.actions.first(where: {
                    $0.id == scenario.directControl.intentIdentifier
                }), action.parameters.allSatisfy({ declared in
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
            }
            for required in requiredCapabilities where !loaded.capabilities.contains(required) {
                throw IntentLabDeclarationError.missingCapability(required)
            }
            for planned in scenario.observationPlan ?? [] {
                if planned.id == "feature.response" {
                    guard runsFeature,
                          isBoundLocalFeatureResponseObservation(
                            planned,
                            scenario: scenario,
                            control: localFeatureControl
                          ) else {
                        throw IntentLabDeclarationError.mismatchedIdentity
                    }
                    continue
                }
                guard planned.source != .intentResult else { continue }
                guard loaded.observers.contains(where: {
                    $0.id == planned.id && $0.source == planned.source
                        && $0.operationID == planned.operationID && $0.selector == planned.selector
                }) else { throw IntentLabDeclarationError.mismatchedIdentity }
            }
            declaration = loaded
            if !integration.supportsMutatingChecks,
               (scenario.safety.mutationPolicy != .readOnly || loaded.isolation.kind != "readOnly") {
                throw IntentLabExecutionPathError.unsafePreparation
            }
        }
        guard
              invocation.scenarioDigest == scenario.definitionDigest,
              let appProduct = invocation.appProduct,
              let testProduct = invocation.testProduct else {
            throw XCTSkip("The host did not embed a fully bound Intent Lab invocation.")
        }
        var results: [IntentLabLaneResult] = []
        var cleanupFailed = false

        if runsFeature {
            guard let featureExecutor, let control = localFeatureControl,
                  let featureBinding = scenario.featureBinding else {
                throw IntentLabLocalFeatureExecutionError.executorRequired
            }
            let context = "feature-\(invocation.id.uuidString)"
            let featureStart = Date()
            var preparationStarted = false
            let featureAttempt = IntentLabAttemptLifecycle.execute(action: {
                preparationStarted = true
                let application = try integration.prepare(
                    bundleIdentifier: scenario.target.bundleIdentifier,
                    context: context,
                    operationID: scenario.fixture.preparationOperation
                )
                defer { application.terminate() }
                let baseline = try integration.observe(
                    application: application,
                    declaration: declaration,
                    deadlineSeconds: scenario.safety.deadlineSeconds
                )
                let captured = try captureDirectObservations(
                    execute: {
                        let featureValues = try featureExecutor(
                            scenario.target.bundleIdentifier,
                            control,
                            localFeatureParameters,
                            context,
                            scenario.safety.deadlineSeconds
                        )
                        try validateFeatureObservations(
                            featureValues,
                            binding: featureBinding
                        )
                        return featureValues
                    },
                    observe: {
                        try integration.observe(
                            application: application,
                            declaration: declaration,
                            deadlineSeconds: scenario.safety.deadlineSeconds
                        )
                    },
                    receiptContext: scenario.actionRequirements == nil ? nil : context,
                    receiptLane: .appFeature
                )
                let merged = mergeFeatureObservations(
                    featureObservations: captured.observations,
                    appObservations: captured.stateObservations
                )
                let outputKeys = Set(featureBinding.outputProjections.map(\.name))
                    .union(["feature.response"])
                var laneResult = result(
                    for: .appFeature,
                    scenario: scenario,
                    observations: merged.observations,
                    baseline: baseline,
                    integration: integration,
                    declaration: declaration,
                    context: context,
                    startedAt: featureStart,
                    resultKeysOverride: outputKeys,
                    featureOutputKeys: merged.featureOutputKeys
                )
                laneResult = rejectingFeatureObservationCollisions(
                    merged.collisions,
                    in: laneResult
                )
                if let driverError = captured.driverError {
                    guard hasAttributableTerminalAction(
                        captured.stateObservations, context: context, lane: .appFeature
                    ) else {
                        throw driverError
                    }
                    laneResult.outcome = .failed
                    laneResult.diagnostic = appendingDiagnostic(
                        laneResult.diagnostic,
                        "Local feature execution failed: \(driverError.localizedDescription)"
                    )
                }
                if let observationError = captured.observationError {
                    laneResult.diagnostic = appendingDiagnostic(
                        laneResult.diagnostic,
                        "App state could not be read after local feature execution: \(observationError.localizedDescription)"
                    )
                }
                return laneResult
            }, cleanupRequired: {
                scenario.schemaVersion == 2 && preparationStarted
            }, skipCleanupAfter: { error in
                // A timed-out feature intent can still mutate the fixture.
                error is IntentLabDirectIntentTimeout
            }, cleanup: {
                try integration.cleanup(
                    bundleIdentifier: scenario.target.bundleIdentifier,
                    context: context,
                    operationID: scenario.fixture.cleanupOperation
                )
            })

            if case .failure(let error) = featureAttempt.action,
               error is IntentLabDirectIntentTimeout {
                attemptFence.recordUnresolvedDirectTimeout()
                var laneResult = failed(
                    for: .appFeature,
                    scenario: scenario,
                    error: error,
                    startedAt: featureStart
                )
                laneResult.cleanupVerified = cleanupVerification(
                    required: scenario.schemaVersion == 2 && preparationStarted,
                    cleanupError: featureAttempt.cleanupError,
                    cleanupWasSkipped: true
                )
                let checkpoint = evidenceEnvelope(
                    scenario: scenario,
                    invocation: invocation,
                    appProduct: appProduct,
                    testProduct: testProduct,
                    results: [laneResult],
                    declaration: declaration
                )
                try EvidenceAttachmentWriter.attach(checkpoint, to: testCase, checkpoint: true)
                throw error
            }

            let verifiedCleanup = cleanupVerification(
                required: scenario.schemaVersion == 2 && preparationStarted,
                cleanupError: featureAttempt.cleanupError,
                cleanupWasSkipped: false
            )
            var featureLaneResult: IntentLabLaneResult
            switch featureAttempt.action {
            case .success(let laneResult): featureLaneResult = laneResult
            case .failure(let error):
                featureLaneResult = failed(
                    for: .appFeature,
                    scenario: scenario,
                    error: error,
                    startedAt: featureStart
                )
            }
            featureLaneResult.cleanupVerified = verifiedCleanup
            if let cleanupError = featureAttempt.cleanupError {
                cleanupFailed = true
                featureLaneResult = addingCleanupFailure(cleanupError, to: featureLaneResult)
            }
            results.append(featureLaneResult)
        }

        if runsDirect && scenario.coverage.intentIntegration != .notApplicable {
            guard let directExecutor else { throw IntentLabExecutionPathError.directIntentRequired }
            let context = "intent-\(invocation.id.uuidString)"
            let directStart = Date()
            var preparationStarted = false
            let directAttempt = IntentLabAttemptLifecycle.execute(action: {
                preparationStarted = true
                let application = try integration.prepare(
                    bundleIdentifier: scenario.target.bundleIdentifier,
                    context: context,
                    operationID: scenario.fixture.preparationOperation
                )
                defer { application.terminate() }
                let baseline = try integration.observe(
                    application: application,
                    declaration: declaration,
                    deadlineSeconds: scenario.safety.deadlineSeconds
                )
                let captured = try captureDirectObservations(
                    execute: { try directExecutor(scenario) },
                    observe: {
                        try integration.observe(
                            application: application,
                            declaration: declaration,
                            deadlineSeconds: scenario.safety.deadlineSeconds
                        )
                    },
                    receiptContext: scenario.actionRequirements == nil ? nil : context,
                    receiptLane: .intentIntegration
                )
                var observations = captured.observations
                let stateObservations = captured.stateObservations
                if scenario.schemaVersion == 2,
                   stateObservations.keys.contains(where: { observations[$0] != nil }) {
                    throw IntentLabDeclarationError.mismatchedIdentity
                }
                observations.merge(stateObservations) { direct, _ in direct }
                var laneResult = result(
                    for: .intentIntegration, scenario: scenario, observations: observations,
                    baseline: baseline, integration: integration, declaration: declaration,
                    context: context, startedAt: directStart
                )
                if let driverError = captured.driverError {
                    guard hasAttributableTerminalAction(
                        captured.stateObservations, context: context, lane: .intentIntegration
                    ) else {
                        // A framework/load failure before the app entered an intent
                        // is execution evidence, not a completed business failure.
                        throw driverError
                    }
                    laneResult.outcome = .failed
                    laneResult.diagnostic = appendingDiagnostic(
                        laneResult.diagnostic,
                        "Direct intent execution failed: \(driverError.localizedDescription)"
                    )
                }
                if let observationError = captured.observationError {
                    laneResult.diagnostic = appendingDiagnostic(
                        laneResult.diagnostic,
                        "App state could not be read after the direct intent error: \(observationError.localizedDescription)"
                    )
                }
                return laneResult
            }, cleanupRequired: {
                scenario.schemaVersion == 2 && preparationStarted
            }, skipCleanupAfter: { error in
                // A timed-out async intent can still mutate the fixture. Keep the
                // attempt quarantined instead of racing a cleanup against it.
                error is IntentLabDirectIntentTimeout
            }, cleanup: {
                try integration.cleanup(
                    bundleIdentifier: scenario.target.bundleIdentifier,
                    context: context,
                    operationID: scenario.fixture.cleanupOperation
                )
            })
            if case .failure(let error) = directAttempt.action,
               error is IntentLabDirectIntentTimeout {
                attemptFence.recordUnresolvedDirectTimeout()
                var laneResult = failed(
                    for: .intentIntegration, scenario: scenario, error: error, startedAt: directStart
                )
                laneResult.cleanupVerified = cleanupVerification(
                    required: scenario.schemaVersion == 2 && preparationStarted,
                    cleanupError: directAttempt.cleanupError,
                    cleanupWasSkipped: true
                )
                let checkpoint = evidenceEnvelope(
                    scenario: scenario, invocation: invocation,
                    appProduct: appProduct, testProduct: testProduct,
                    results: [laneResult]
                        + (runsSiri ? unobservedSiriAttempts(for: scenario) : []),
                    declaration: declaration
                )
                try EvidenceAttachmentWriter.attach(checkpoint, to: testCase, checkpoint: true)
                throw error
            }
            let verifiedCleanup = cleanupVerification(
                required: scenario.schemaVersion == 2 && preparationStarted,
                cleanupError: directAttempt.cleanupError,
                cleanupWasSkipped: false
            )
            var directLaneResult: IntentLabLaneResult
            switch directAttempt.action {
            case .success(let laneResult): directLaneResult = laneResult
            case .failure(let error):
                directLaneResult = failed(
                    for: .intentIntegration, scenario: scenario, error: error, startedAt: directStart
                )
            }
            directLaneResult.cleanupVerified = verifiedCleanup
            if let cleanupError = directAttempt.cleanupError {
                cleanupFailed = true
                directLaneResult = addingCleanupFailure(cleanupError, to: directLaneResult)
            }
            results.append(directLaneResult)
        }

        // XCTest can terminate this method inside siriService.activate without throwing.
        // Persist completed direct observations before entering that API. Siri attempts
        // remain explicitly unobserved until a final envelope replaces this checkpoint.
        if runsSiri && scenario.coverage.siri != .notApplicable && !cleanupFailed {
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

        if runsSiri && scenario.coverage.siri != .notApplicable && cleanupFailed {
            results += unobservedSiriAttempts(for: scenario)
        }

        if runsSiri && scenario.coverage.siri != .notApplicable && !cleanupFailed {
            let attemptCount = scenario.coverage.siriAttemptCount ?? 3
            let attempts = scenario.executionScope.map { [$0.attempt] } ?? Array(1...attemptCount)
            var sequence = SiriAttemptSequence()
            for attempt in attempts {
                let context = "siri-\(invocation.id.uuidString)-\(attempt)"
                let siriStart = Date()
                var baseline: [String: IntentLabValue]?
                var preparationStarted = false
                var attemptScreenshot: IntentLabArtifactReference?
                let completedAttempt = executeSiriAttempt(action: {
                    try sequence.run {
                        preparationStarted = true
                        let application = try integration.prepare(
                            bundleIdentifier: scenario.target.bundleIdentifier,
                            context: context,
                            operationID: scenario.fixture.preparationOperation
                        )
                        defer {
                            // Preserve the Siri result before cleanup resets the fixture.
                            attemptScreenshot = EvidenceAttachmentWriter.attachScreenshot(to: testCase)
                            application.terminate()
                        }
                        if scenario.executionScope != nil {
                            baseline = try integration.observe(
                                application: application,
                                declaration: declaration,
                                deadlineSeconds: scenario.safety.deadlineSeconds
                            )
                        }
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
                            declaration: declaration,
                            permitsChooserAssistance: scenario.actionRequirements == nil
                        )
                        attemptFence.recordVerifiedSiriCompletion()
                        return completedObservations
                    }
                }, evaluate: { observations in
                    result(
                        for: .siri, scenario: scenario, observations: observations,
                        baseline: baseline, integration: integration, declaration: declaration,
                        context: context, startedAt: siriStart, attempt: attempt,
                        artifacts: [attemptScreenshot ?? EvidenceAttachmentWriter.attachScreenshot(to: testCase)]
                    )
                }, cleanupRequired: {
                    scenario.schemaVersion == 2 && preparationStarted
                }, skipCleanupAfter: { _ in
                    // Siri may still be completing after an unobserved outcome.
                    attemptFence.isQuarantined
                }, cleanup: {
                    try integration.cleanup(
                        bundleIdentifier: scenario.target.bundleIdentifier,
                        context: context,
                        operationID: scenario.fixture.cleanupOperation
                    )
                })
                let screenshot = attemptScreenshot ?? EvidenceAttachmentWriter.attachScreenshot(to: testCase)
                let siriCleanupWasSkipped: Bool
                if case .failure = completedAttempt.action {
                    siriCleanupWasSkipped = attemptFence.isQuarantined
                } else {
                    siriCleanupWasSkipped = false
                }
                let verifiedCleanup = cleanupVerification(
                    required: scenario.schemaVersion == 2 && preparationStarted,
                    cleanupError: completedAttempt.cleanupError,
                    cleanupWasSkipped: siriCleanupWasSkipped
                )
                var siriLaneResult: IntentLabLaneResult
                switch completedAttempt.action {
                case .success(let laneResult):
                    siriLaneResult = laneResult
                case .failure(let error):
                    siriLaneResult = failed(
                        for: .siri,
                        scenario: scenario,
                        error: error,
                        startedAt: siriStart,
                        attempt: attempt,
                        artifacts: [screenshot]
                    )
                }
                siriLaneResult.cleanupVerified = verifiedCleanup
                if let cleanupError = completedAttempt.cleanupError {
                    results.append(addingCleanupFailure(cleanupError, to: siriLaneResult))
                    results += unobservedSiriAttempts(for: scenario).filter { $0.attempt > attempt }
                    break
                }
                results.append(siriLaneResult)
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

    static func executeSiriAttempt(
        action: () throws -> [String: IntentLabValue],
        evaluate: ([String: IntentLabValue]) -> IntentLabLaneResult,
        cleanupRequired: () -> Bool,
        skipCleanupAfter: (Error) -> Bool,
        cleanup: () throws -> Void
    ) -> (action: Result<IntentLabLaneResult, Error>, cleanupError: Error?) {
        // Completion can depend on consumer-owned active context. Freeze the
        // observed result before cleanup clears that context or resets app state.
        IntentLabAttemptLifecycle.execute(
            action: { evaluate(try action()) }, cleanupRequired: cleanupRequired,
            skipCleanupAfter: skipCleanupAfter, cleanup: cleanup
        )
    }

    static func captureDirectObservations(
        execute: () throws -> [String: IntentLabValue],
        observe: () throws -> [String: IntentLabValue],
        receiptContext: String? = nil,
        receiptLane: IntentLabLane? = nil,
        receiptWaitSeconds: TimeInterval = 5,
        receiptPollInterval: TimeInterval = 0.25
    ) throws -> (
        observations: [String: IntentLabValue],
        stateObservations: [String: IntentLabValue],
        driverError: Error?,
        observationError: Error?
    ) {
        var observations: [String: IntentLabValue] = [:]
        var driverError: Error?
        do {
            observations = try execute()
        } catch let error as IntentLabDirectIntentTimeout {
            throw error
        } catch {
            // A terminal intent error can still publish its action receipt.
            // Read app-owned state while this attempt's context is active.
            driverError = error
        }

        do {
            var state = try observe()
            if let receiptContext, let receiptLane {
                let deadline = Date().addingTimeInterval(max(0, receiptWaitSeconds))
                while !hasAttributableTerminalAction(state, context: receiptContext, lane: receiptLane),
                      Date() < deadline {
                    if receiptPollInterval > 0 {
                        Thread.sleep(forTimeInterval: receiptPollInterval)
                    }
                    state = try observe()
                }
            }
            return (observations, state, driverError, nil)
        } catch {
            guard driverError != nil else { throw error }
            return (observations, [:], driverError, error)
        }
    }

    static func hasAttributableTerminalAction(
        _ observations: [String: IntentLabValue], context: String, lane: IntentLabLane
    ) -> Bool {
        guard case .string(let rawJSON) = observations["intentlab.actionReceipts"],
              let bytes = rawJSON.data(using: .utf8), bytes.count <= 65_536,
              let receipts = try? JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: bytes),
              receipts.count <= 16 else { return false }
        return receipts.contains {
            $0.attemptContext == context && $0.lane == lane && $0.isTopLevel
                && ($0.terminalStatus == .succeeded || $0.terminalStatus == .failed)
        }
    }

    static func cleanupVerification(
        required: Bool,
        cleanupError: Error?,
        cleanupWasSkipped: Bool
    ) -> Bool? {
        guard required else { return nil }
        return cleanupError == nil && !cleanupWasSkipped
    }

    static func resolveFeatureParameters(
        _ inputMapping: [IntentLabFeatureBinding.InputMapping],
        against declaredParameters: [IntentLabIntegrationDeclaration.Parameter]
    ) throws -> [String: IntentLabValue] {
        var values: [String: IntentLabValue] = [:]
        for mapping in inputMapping {
            guard let declaration = declaredParameters.first(where: {
                $0.name == mapping.featureInputName
            }), declaration.type.accepts(mapping.value) else {
                throw IntentLabDeclarationError.mismatchedIdentity
            }
            if declaration.required, case .null = mapping.value {
                throw IntentLabDeclarationError.mismatchedIdentity
            }
            values[mapping.featureInputName] = mapping.value
        }
        guard declaredParameters.allSatisfy({ parameter in
            !parameter.required || values[parameter.name] != nil
        }) else {
            throw IntentLabDeclarationError.mismatchedIdentity
        }
        return values
    }

    static func validateFeatureObservations(
        _ observations: [String: IntentLabValue],
        binding: IntentLabFeatureBinding
    ) throws {
        guard binding.outputProjections.allSatisfy({
            $0.name != "feature.response" && $0.name != "intentlab.actionReceipts"
        }) else {
            throw IntentLabLocalFeatureExecutionError.invalidResult
        }
        let allowed = Set(binding.outputProjections.map(\.name)).union(["feature.response"])
        let response = observations["feature.response"]
        guard Set(observations.keys).isSubset(of: allowed),
              let response,
              case .string = response,
              binding.outputProjections.allSatisfy({ observations[$0.name] != nil }) else {
            throw IntentLabLocalFeatureExecutionError.invalidResult
        }
        for field in binding.outputProjections {
            if let value = observations[field.name], !field.type.accepts(value) {
                throw IntentLabLocalFeatureExecutionError.invalidResult
            }
        }
    }

    static func isBoundLocalFeatureResponseObservation(
        _ planned: IntentLabPlannedObservation,
        scenario: IntentLabScenario,
        control: IntentLabIntegrationDeclaration.FeatureControl?
    ) -> Bool {
        guard let control,
              scenario.executionScope?.lane == .appFeature,
              let binding = scenario.featureBinding,
              binding.featureID == control.featureID,
              binding.interfaceDigest == control.interfaceDigest,
              binding.outputProjections.allSatisfy({
                  $0.name != "feature.response" && $0.name != "intentlab.actionReceipts"
              }),
              let requirements = scenario.actionRequirements?.filter({
                  $0.lane == .appFeature && $0.kind == .productionService
              }),
              requirements.count == 1,
              requirements[0].operationID == control.operationID,
              planned.id == "feature.response",
              planned.source == .testOnlyIntent,
              planned.operationID == control.operationID,
              planned.selector == nil else {
            return false
        }
        return true
    }

    static func mergeFeatureObservations(
        featureObservations: [String: IntentLabValue],
        appObservations: [String: IntentLabValue]
    ) -> (
        observations: [String: IntentLabValue],
        featureOutputKeys: Set<String>,
        collisions: Set<String>
    ) {
        let featureKeys = Set(featureObservations.keys)
        let collisions = featureKeys.intersection(appObservations.keys)
        var observations = featureObservations
        for (key, value) in appObservations where !collisions.contains(key) {
            observations[key] = value
        }
        return (observations, featureKeys, collisions)
    }

    static func rejectingFeatureObservationCollisions(
        _ collisions: Set<String>,
        in laneResult: IntentLabLaneResult
    ) -> IntentLabLaneResult {
        guard !collisions.isEmpty else { return laneResult }
        var laneResult = laneResult
        laneResult.outcome = .failed
        laneResult.diagnostic = appendingDiagnostic(
            laneResult.diagnostic,
            "App state reused local feature output keys: \(collisions.sorted().joined(separator: ", "))."
        )
        return laneResult
    }

    static func addingCleanupFailure(
        _ cleanupError: Error,
        to laneResult: IntentLabLaneResult
    ) -> IntentLabLaneResult {
        var laneResult = laneResult
        laneResult.cleanupVerified = false
        laneResult.diagnostic = appendingDiagnostic(
            laneResult.diagnostic,
            "Fixture cleanup failed: \(cleanupError.localizedDescription)"
        )
        return laneResult
    }

    private static func appendingDiagnostic(_ existing: String?, _ additional: String) -> String {
        guard let existing, !existing.isEmpty else { return additional }
        return "\(existing) \(additional)"
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
        let attempts = scenario.executionScope.map { [$0.attempt] }
            ?? Array(1...(scenario.coverage.siriAttemptCount ?? 3))
        return attempts.map { attempt in
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

    static func result(
        for lane: IntentLabLane,
        scenario: IntentLabScenario,
        observations: [String: IntentLabValue],
        baseline: [String: IntentLabValue]?,
        integration: any IntentLabSiriIntegration,
        declaration: IntentLabIntegrationDeclaration?,
        context: String,
        startedAt: Date,
        attempt: Int = 1,
        artifacts: [IntentLabArtifactReference] = [],
        resultKeysOverride: Set<String>? = nil,
        featureOutputKeys: Set<String> = []
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
            if scenario.executionScope != nil {
                return IntentLabAssertionEvaluator.evaluate(
                    assertion, observed: observed, before: baseline?[assertion.observationKey]
                )
            }
            // Unscoped v1/v2 evidence retains its original final-value semantics.
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
        let resultKeys = resultKeysOverride ?? Set(scenario.directControl.outputFields.map(\.name))
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
        let returnedChecked = IntentLabReturnedValueProof.isVerified(assertions: assertions, observations: observations, resultKeys: resultKeys, checks: checks)
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
        if (lane == .intentIntegration || lane == .appFeature) && returnedChecked {
            claims.append(.returnedValueChecked)
        }
        if stateChecked { claims.append(.applicationStateChecked) }
        let missingClaim = scenario.schemaVersion == 2
            && (scenario.requiredClaims ?? []).contains(where: {
                !($0 == .returnedValueChecked && lane == .siri) && !claims.contains($0)
            })
        let requirement = scenario.actionRequirements?.first(where: { $0.lane == lane })
        let rawReceipts: [IntentLabActionReceipt]?
        let receiptIsMalformed: Bool
        if case .string(let json) = observations["intentlab.actionReceipts"],
           let bytes = json.data(using: .utf8), bytes.count <= 65_536 {
            rawReceipts = try? JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: bytes)
            receiptIsMalformed = rawReceipts == nil
        } else {
            rawReceipts = nil
            receiptIsMalformed = observations["intentlab.actionReceipts"] != nil
        }
        let transport = integration.source(for: "intentlab.actionReceipts")
        let receipts = rawReceipts?.map { receipt in
            var observed = receipt
            observed.observationTransport = transport
            return observed
        }
        var actionVerdict = IntentLabAssertionEvaluator.actionVerdict(
            requirement: requirement, receipts: receipts,
            lane: lane, attempt: attempt, context: context
        )
        if requirement != nil && receiptIsMalformed {
            actionVerdict = (.notObserved, .invalidActionEvidence)
        }
        let failureReason = IntentLabAssertionEvaluator.failureReason(
            action: actionVerdict,
            deterministicFailure: deterministicFailure
        )
        if actionVerdict.0 == .failed || deterministicFailure || missingSemantic {
            outcome = .failed
        } else if actionVerdict.0 == .notObserved || missingClaim
                    || (scenario.schemaVersion == 2 && lane == .siri && !stateChecked) {
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
            diagnostic: failureReason?.rawValue, proposedCause: nil, artifacts: artifacts,
            observationSources: Dictionary(uniqueKeysWithValues: observations.keys.map {
                ($0, featureOutputKeys.contains($0)
                    ? IntentLabObservationSource.testOnlyIntent.rawValue
                    : resultKeys.contains($0) && lane == .intentIntegration
                        ? "appIntentsTesting"
                        : $0 == "recognizedRequest" ? "siriRecognizedText" : observationSource($0))
            }),
            claims: scenario.schemaVersion == 2 ? claims : nil,
            beforeObservations: scenario.executionScope == nil ? nil : baseline,
            actionReceipts: receipts, actionFailureReason: failureReason
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
        case is IntentLabDirectIntentTimeout:
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

    private static func readinessContext(for route: String) -> String {
        "intentlab-readiness-\(route)-\(UUID().uuidString)"
    }

    private static func featureReadinessDetail(
        status: IntentLabReadinessStatus,
        featureControlCount: Int,
        observersReady: Bool,
        observerFailure: String?,
        directStatus: IntentLabReadinessStatus,
        directFailure: String?
    ) -> String {
        switch status {
        case .ready:
            return "The payload-free readiness control and app observer probe passed; \(featureControlCount) local Feature control(s) and required capabilities are declared. No business Feature action was run. Host preflight binds the selected Feature control."
        case .setupRequired:
            return "Declare local Feature controls, the required capabilities, and harmless readiness support before testing the Feature route."
        case .environmentBlocked:
            if !observersReady, let observerFailure { return "App observer prerequisites are blocked: \(observerFailure)" }
            if directStatus == .environmentBlocked, let directFailure { return "Shared AppIntentsTesting readiness is blocked: \(directFailure)" }
            return "A required Feature readiness prerequisite is blocked."
        case .notYetVerified:
            if directStatus == .notYetVerified {
                return "The Siri/Core runner has no AppIntentsTesting transport, so local Feature readiness remains unverified. No business Feature action was run."
            }
            return "The Feature route has not been verified. No business Feature action was run."
        }
    }

}

public enum IntentLabReadinessStatus: String, Codable, Equatable {
    case ready
    case setupRequired
    case environmentBlocked
    case notYetVerified
}

enum IntentLabReadinessStatusPolicy {
    static func direct(
        controlDeclared: Bool,
        executorAvailable: Bool,
        observations: [String: IntentLabValue]?
    ) -> IntentLabReadinessStatus {
        guard controlDeclared else { return .setupRequired }
        guard executorAvailable else { return .notYetVerified }
        guard observations?[IntentLabReadinessObservation.ready] == .boolean(true) else { return .environmentBlocked }
        return .ready
    }

    static func siri(
        readinessOperationDeclared: Bool,
        appLaunched: Bool,
        observationCompleted: Bool
    ) -> IntentLabReadinessStatus {
        guard appLaunched && observationCompleted else { return .environmentBlocked }
        guard readinessOperationDeclared else { return .setupRequired }
        // This marks driver readiness, not user Siri configuration or request routing.
        return .ready
    }

    static func feature(
        directStatus: IntentLabReadinessStatus,
        featureControlDeclared: Bool,
        capabilitiesDeclared: Bool,
        capabilitiesSupported: Bool,
        observersReady: Bool
    ) -> IntentLabReadinessStatus {
        if directStatus == .environmentBlocked { return .environmentBlocked }
        guard featureControlDeclared && capabilitiesDeclared else { return .setupRequired }
        guard observersReady else { return .environmentBlocked }
        switch directStatus {
        case .ready:
            return capabilitiesSupported ? .ready : .setupRequired
        case .setupRequired:
            return .setupRequired
        case .notYetVerified:
            return .notYetVerified
        case .environmentBlocked:
            return .environmentBlocked
        }
    }
}

public enum IntentLabReadinessRouteKey {
    public static let appFeature = "appFeature"
    public static let intentIntegration = "intentIntegration"
    public static let siri = "siri"
}

public enum IntentLabReadinessObservation {
    public static let ready = "readiness.ready"
}

public struct IntentLabReadinessRoute: Codable {
    public let status: IntentLabReadinessStatus
    public let operationID: String?
    public let supportType: String?
    public let context: String?
    public let observations: [String: IntentLabValue]?
    public let detail: String?

    public init(
        status: IntentLabReadinessStatus,
        operationID: String? = nil,
        supportType: String? = nil,
        context: String? = nil,
        observations: [String: IntentLabValue]? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.operationID = operationID
        self.supportType = supportType
        self.context = context
        self.observations = observations
        self.detail = detail
    }
}

public struct IntentLabReadinessReceipt: Codable {
    public let schemaVersion: Int
    public let testName: String
    public let testIdentifier: String
    public let testMethodStarted: Bool
    public let createdAt: Date
    public let targetBundleIdentifier: String?
    public let testBundleIdentifier: String
    public let integration: IntentLabIntegrationIdentity?
    public let routes: [String: IntentLabReadinessRoute]

    public init(
        schemaVersion: Int,
        testName: String,
        testIdentifier: String,
        testMethodStarted: Bool,
        createdAt: Date,
        targetBundleIdentifier: String?,
        testBundleIdentifier: String,
        integration: IntentLabIntegrationIdentity?,
        routes: [String: IntentLabReadinessRoute]
    ) {
        self.schemaVersion = schemaVersion
        self.testName = testName
        self.testIdentifier = testIdentifier
        self.testMethodStarted = testMethodStarted
        self.createdAt = createdAt
        self.targetBundleIdentifier = targetBundleIdentifier
        self.testBundleIdentifier = testBundleIdentifier
        self.integration = integration
        self.routes = routes
    }
}

private enum IntentLabReadinessProbeError: LocalizedError {
    case applicationDidNotLaunch

    var errorDescription: String? {
        switch self {
        case .applicationDidNotLaunch:
            "The selected app remained stopped after the declared readiness preparation."
        }
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
