import Foundation
import Testing
@testable import FoundationEvals

struct XcodeRouteReadinessTests {
    @Test func connectionStageFrameworkAndSecurityFailuresStayRouteScoped() {
        let loadFailure = XcodeTestExecutor.connectionEnvironmentFailure(
            testExit: 1, testCount: 0, failureMessages: [],
            logTail: "dlopen(test bundle): Symbol not found in AppIntentsServices.framework; Referenced from: AppIntentsTesting.framework",
            selectedDirectFramework: true
        )
        #expect(loadFailure == .frameworkLoad)
        let securityFailure = XcodeTestExecutor.connectionEnvironmentFailure(
            testExit: 1, testCount: 1,
            failureMessages: ["Error Domain=AppIntentsServicesSecurityErrorDomain Code=803 Unable to run internal tests on a Customer build"],
            logTail: "", selectedDirectFramework: true
        )
        #expect(securityFailure == .security)
        #expect(XcodeTestExecutor.connectionEnvironmentFailure(
            testExit: 0, testCount: 1, failureMessages: [],
            logTail: "A prior AppIntentsTesting Code=803 is in this unrelated log.",
            selectedDirectFramework: true
        ) == nil)
        #expect(XcodeTestExecutor.connectionEnvironmentFailure(
            testExit: 1, testCount: 0,
            failureMessages: ["The fixed connection method was skipped."],
            logTail: "", selectedDirectFramework: true
        ) == nil)

        let base = ScenarioRouteReadiness(
            lane: .intentIntegration, state: .notYetVerified,
            detail: "Connection has not been checked.", checks: [], inspectedAt: nil,
            resultBundlePath: nil, logPath: nil
        )
        let direct = base
        var feature = base
        feature.lane = .appFeature
        var siri = base
        siri.lane = .siri
        for route in [direct, feature, siri] {
            var candidate = route
            XcodeTestExecutor.applyConnectionEnvironmentFailure(
                kind: .frameworkLoad,
                resultBundlePath: "/tmp/Connection.xcresult",
                logPath: "/tmp/xcodebuild.log",
                featureBackend: .projectLocalTestControl,
                to: &candidate
            )
            if route.lane == .siri {
                #expect(candidate.state == .notYetVerified)
            } else {
                #expect(candidate.state == .environmentBlocked)
                #expect(candidate.resultBundlePath == "/tmp/Connection.xcresult")
                #expect(candidate.backendName == "AppIntentsTesting")
            }
        }
        XcodeTestExecutor.applyConnectionEnvironmentFailure(
            kind: .security, resultBundlePath: "/tmp/Connection.xcresult",
            logPath: "/tmp/xcodebuild.log", featureBackend: .connectedRunner,
            to: &feature
        )
        #expect(feature.state == .notYetVerified,
                "A connected-runner Feature route does not inherit a native framework blocker.")
    }

    @MainActor
    @Test func connectedFeatureUsesMatchedRunnerRatherThanNativeFeatureScope() {
        var definition = ScenarioDefinition.starter()
        definition.coverage.appFeature = .required
        let scopeBlock = ScenarioPreflightCheck(
            id: "nativeScope", title: "Native route", state: .blocked,
            detail: "Local Feature control requires its explicit frozen backend."
        )
        let initial = ScenarioRouteReadiness(
            lane: .appFeature, state: .setupRequired, detail: scopeBlock.detail,
            checks: [scopeBlock], inspectedAt: nil,
            resultBundlePath: nil, logPath: nil
        )
        var routes: [ScenarioLane: ScenarioRouteReadiness] = [.appFeature: initial]
        ScenarioCoordinator.applyConnectedFeatureReadiness(
            to: &routes, definition: definition, appDigest: String(repeating: "a", count: 64),
            runnerCheck: { _ in }
        )
        #expect(routes[.appFeature]?.state == .ready)
        #expect(routes[.appFeature]?.backendName == ScenarioFeatureBackend.connectedRunner.rawValue)

        routes[.appFeature] = initial
        ScenarioCoordinator.applyConnectedFeatureReadiness(
            to: &routes, definition: definition, appDigest: nil,
            runnerCheck: { _ in Issue.record("Runner matching must wait for a checked build") }
        )
        #expect(routes[.appFeature]?.state == .notYetVerified)
        #expect(routes[.appFeature]?.detail.contains("Build and check") == true)

        routes[.appFeature] = initial
        ScenarioCoordinator.applyConnectedFeatureReadiness(
            to: &routes, definition: definition, appDigest: String(repeating: "a", count: 64),
            runnerCheck: { _ in throw XcodeTestExecutorError.connectionCheck("Runner missing") }
        )
        #expect(routes[.appFeature]?.state == .setupRequired)
        #expect(routes[.appFeature]?.detail.contains("Runner missing") == true)

        var strict = definition
        strict.schemaVersion = ScenarioDefinition.stableSchemaVersion
        strict.actionPolicyVersion = 1
        strict.actionRequirements = [.init(
            lane: .appFeature, kind: .productionService,
            operationID: "SummarizeNoteService", resolvedParameters: [:]
        )]
        #expect(ScenarioCoordinator.connectedFeatureActionBlocker(definition) == nil)
        routes[.appFeature] = initial
        ScenarioCoordinator.applyConnectedFeatureReadiness(
            to: &routes, definition: strict, appDigest: String(repeating: "a", count: 64),
            runnerCheck: { _ in Issue.record("Strict Feature must block before runner matching") }
        )
        #expect(routes[.appFeature]?.state == .setupRequired)
        #expect(routes[.appFeature]?.detail.contains("typed App Feature action receipt") == true)
        #expect(routes[.appFeature]?.backendName == ScenarioFeatureBackend.connectedRunner.rawValue)
    }

    @Test func selectedSiriScopeDoesNotRequireDirectFrameworkCapabilities() {
        let definition = ScenarioDefinition.starter()
        let siri = ScenarioHarnessCapabilities.required(
            for: definition, scope: .init(lane: .siri, attempt: 1),
            featureBackend: .projectLocalTestControl
        )
        let direct = ScenarioHarnessCapabilities.required(
            for: definition, scope: .init(lane: .intentIntegration, attempt: 1),
            featureBackend: .projectLocalTestControl
        )
        #expect(siri.contains("siri"))
        #expect(!siri.contains("direct-intent-execution"))
        #expect(!siri.contains("local-feature-controls"))
        #expect(direct.contains("direct-intent-execution"))
        #expect(!direct.contains("siri"))
        let full = ScenarioHarnessCapabilities.required(
            for: definition, scope: nil, featureBackend: .projectLocalTestControl
        )
        #expect(full.contains("local-feature-controls"))
    }

    @Test func blockedDirectDoesNotHideReadySiriDiagnostic() {
        let receipt = probeReceipt(routes: [
            .intentIntegration: .init(
                status: .environmentBlocked, operationID: "intentLabReadiness",
                supportType: "AppIntentsTesting", context: "direct-probe-1", observations: nil,
                detail: "AppIntentsTesting did not load."
            ),
            .siri: .init(
                status: .ready, operationID: nil, supportType: "CoreTesting",
                context: "siri-probe-1",
                observations: ["intentlab.readiness.appState": .string("runningForeground")],
                detail: "The Siri driver and fixture support started."
            ),
        ])
        let probe = ScenarioReadinessProbeEvidence(
            receipt: receipt, resultBundlePath: "/tmp/Readiness.xcresult",
            logPath: "/tmp/readiness.log", issue: nil,
            expectedReadinessOperationID: "intentLabReadiness"
        )
        let report = ScenarioPreflightReport(checks: [])
        let direct = XcodeTestExecutor.readiness(lane: .intentIntegration, report: report, probe: probe)
        let siri = XcodeTestExecutor.readiness(lane: .siri, report: report, probe: probe)
        #expect(direct.state == .environmentBlocked)
        #expect(siri.state == .ready)
        #expect(siri.resultBundlePath == probe.resultBundlePath)
    }

    @Test func observedDriverFailureInvalidatesOnlyItsCachedRoute() {
        let receipt = probeReceipt(routes: [
            .intentIntegration: .init(
                status: .ready, operationID: "intentLabReadiness",
                supportType: "appIntentsTestingReadiness", context: "direct-probe-1",
                observations: ["readiness.ready": .boolean(true)], detail: nil
            ),
            .siri: .init(
                status: .ready, operationID: "prepare", supportType: "uiPreparationAndObservation",
                context: "siri-probe-1",
                observations: ["intentlab.readiness.appState": .string("runningForeground")],
                detail: nil
            ),
        ])
        let probe = ScenarioReadinessProbeEvidence(
            receipt: receipt, resultBundlePath: "/tmp/Readiness.xcresult",
            logPath: "/tmp/readiness.log", issue: nil,
            expectedReadinessOperationID: "intentLabReadiness"
        )
        let failed = XcodeTestExecutor.invalidatedProbe(
            probe, lane: .intentIntegration, reason: "AppIntentsTesting failed to load."
        )
        let report = ScenarioPreflightReport(checks: [])
        #expect(XcodeTestExecutor.readiness(
            lane: .intentIntegration, report: report, probe: failed
        ).state == .environmentBlocked)
        #expect(XcodeTestExecutor.readiness(
            lane: .siri, report: report, probe: failed
        ).state == .ready)
        let failedProcess = XcodeTestExecutor.invalidatedProbe(
            probe, lane: nil, reason: "The readiness test process failed."
        )
        #expect(XcodeTestExecutor.readiness(
            lane: .siri, report: report, probe: failedProcess
        ).state == .environmentBlocked)
    }

    @Test func unsignedDirectTransportBlocksLocalFeatureButNotCoreSiri() {
        #expect(!XcodeTestExecutor.matchingSigningTeam(
            appTeam: nil, hostTeam: nil, testTeam: nil
        ))
        #expect(!XcodeTestExecutor.matchingSigningTeam(
            appTeam: "TEAM-A", hostTeam: "TEAM-B", testTeam: "TEAM-A"
        ))
        #expect(XcodeTestExecutor.matchingSigningTeam(
            appTeam: "TEAM-A", hostTeam: "TEAM-A", testTeam: "TEAM-A"
        ))
        let receipt = probeReceipt(routes: [
            .appFeature: .init(
                status: .notYetVerified, operationID: nil, supportType: "appIntentsTestingReadiness",
                context: nil, observations: nil, detail: "Feature support was not exercised."
            ),
            .intentIntegration: .init(
                status: .environmentBlocked, operationID: "intentLabReadiness",
                supportType: "appIntentsTestingReadiness", context: "direct-probe-1",
                observations: nil, detail: "Code=803: the app and UI test bundle need the same signing team."
            ),
            .siri: .init(
                status: .ready, operationID: "prepare", supportType: "uiPreparationAndObservation",
                context: "siri-probe-1",
                observations: ["intentlab.readiness.appState": .string("runningForeground")],
                detail: "Core Siri driver can attempt the route."
            ),
        ])
        let probe = ScenarioReadinessProbeEvidence(
            receipt: receipt, resultBundlePath: "/tmp/Readiness.xcresult",
            logPath: "/tmp/readiness.log", issue: nil,
            expectedReadinessOperationID: "intentLabReadiness"
        )
        let report = ScenarioPreflightReport(checks: [])
        let feature = XcodeTestExecutor.readiness(lane: .appFeature, report: report, probe: probe)
        #expect(feature.state == .environmentBlocked)
        #expect(feature.detail.contains("Code=803"))
        #expect(XcodeTestExecutor.readiness(
            lane: .siri, report: report, probe: probe
        ).state == .ready)
    }

    @Test func localFeatureRequiresSharedTypedTransportProbe() {
        let control = ScenarioReadinessProbeRoute(
            status: .ready, operationID: "intentLabReadiness",
            supportType: "appIntentsTestingReadiness", context: "shared-probe-1",
            observations: ["readiness.ready": .boolean(true)], detail: nil
        )
        let receipt = probeReceipt(routes: [.appFeature: control, .intentIntegration: control])
        let probe = ScenarioReadinessProbeEvidence(
            receipt: receipt, resultBundlePath: "/tmp/Readiness.xcresult",
            logPath: "/tmp/readiness.log", issue: nil,
            expectedReadinessOperationID: "intentLabReadiness"
        )
        #expect(XcodeTestExecutor.readiness(
            lane: .appFeature, report: .init(checks: []), probe: probe
        ).state == .ready)
        var missingDirect = probe
        missingDirect.receipt?.routes[ScenarioLane.intentIntegration.rawValue]?.status = .environmentBlocked
        #expect(XcodeTestExecutor.readiness(
            lane: .appFeature, report: .init(checks: []), probe: missingDirect
        ).state == .environmentBlocked)
    }

    @Test func skippedOrZeroTestNeverCountsAsRuntimeProbe() {
        #expect(!XcodeTestExecutor.probeTestCountIsValid(nil))
        #expect(!XcodeTestExecutor.probeTestCountIsValid(0))
        #expect(!XcodeTestExecutor.probeTestCountIsValid(2))
        #expect(XcodeTestExecutor.probeTestCountIsValid(1))
        let report = ScenarioPreflightReport(checks: [])
        let noProbe = XcodeTestExecutor.readiness(lane: .siri, report: report, probe: nil)
        #expect(noProbe.state == .notYetVerified)
        let missingCheckedProducts = ScenarioPreflightReport(checks: [
            .init(id: "harness", title: "Intent Lab harness", state: .blocked,
                  detail: "Check the selected products again."),
            .init(id: "capability.direct-intent-execution", title: "Direct",
                  state: .blocked, detail: "Compiled capability is unknown."),
        ])
        #expect(XcodeTestExecutor.readiness(
            lane: .intentIntegration, report: missingCheckedProducts, probe: nil
        ).state == .notYetVerified)
    }

    @Test func declaredDirectCapabilityWithoutTypedHarmlessReplyIsUnverified() {
        let report = ScenarioPreflightReport(checks: [])
        let receipt = probeReceipt(routes: [
            .intentIntegration: .init(
                status: .ready, operationID: "intentLabReadiness",
                supportType: "AppIntentsTesting", context: "direct-probe-1",
                observations: nil, detail: nil
            )
        ])
        let probe = ScenarioReadinessProbeEvidence(
            receipt: receipt, resultBundlePath: "/tmp/Readiness.xcresult",
            logPath: "/tmp/readiness.log", issue: nil,
            expectedReadinessOperationID: "intentLabReadiness"
        )
        #expect(XcodeTestExecutor.readiness(
            lane: .intentIntegration, report: report, probe: probe
        ).state == .notYetVerified)
        var typed = probe
        typed.receipt?.routes[ScenarioLane.intentIntegration.rawValue]?.observations = [
            "readiness.ready": .boolean(true)
        ]
        #expect(XcodeTestExecutor.readiness(
            lane: .intentIntegration, report: report, probe: typed
        ).state == .ready)
        typed.receipt?.routes[ScenarioLane.intentIntegration.rawValue]?.observations = [
            "readiness.ready": .boolean(false)
        ]
        #expect(XcodeTestExecutor.readiness(
            lane: .intentIntegration, report: report, probe: typed
        ).state == .notYetVerified)
    }

    @Test func changedIntegrationIdentityRejectsReadinessReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RouteProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "IntentLabReadinessReceipt-test.json"
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let receipt: [String: Any] = [
            "schemaVersion": 1, "testName": "testIntentLabReadiness",
            "testIdentifier": "FixtureUITests.IntentLabScenarioTests/testIntentLabReadiness",
            "testMethodStarted": true, "createdAt": createdAt,
            "targetBundleIdentifier": "dev.example.Fixture",
            "testBundleIdentifier": "dev.example.FixtureUITests",
            "integration": [
                "id": "fixture", "version": "1",
                "digest": String(repeating: "a", count: 64),
            ],
            "routes": ["siri": ["status": "ready", "supportType": "CoreTesting"]],
        ]
        try JSONSerialization.data(withJSONObject: receipt).write(to: root.appending(path: name))
        let manifest: [[String: Any]] = [[
            "testIdentifier": "IntentLabScenarioTests/testIntentLabReadiness()",
            "attachments": [[
                "suggestedHumanReadableName": name,
                "exportedFileName": name,
            ]],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appending(path: "manifest.json"))
        let connection = ScenarioConnectionReceipt(
            schemaVersion: 1,
            integration: .init(id: "fixture", version: "1", digest: String(repeating: "a", count: 64)),
            targetBundleIdentifier: "dev.example.Fixture",
            projectIdentity: "Fixture.xcodeproj", targetIdentity: "FixtureUITests",
            testBundleIdentifier: "dev.example.FixtureUITests", harnessProtocol: "intent-lab-v2",
            runnerPackageVersion: "test", capabilities: ["environment-payload"],
            inspectedAt: Date().addingTimeInterval(-10)
        )
        #expect(try XcodeTestExecutor.readinessProbeReceipt(
            in: root, connection: connection
        ).routes[ScenarioLane.siri.rawValue]?.status == .ready)
        var changed = connection
        changed.targetBundleIdentifier = "dev.example.Other"
        #expect(throws: XcodeTestExecutorError.self) {
            _ = try XcodeTestExecutor.readinessProbeReceipt(in: root, connection: changed)
        }
        changed = connection
        changed.integration.digest = String(repeating: "b", count: 64)
        #expect(throws: XcodeTestExecutorError.self) {
            _ = try XcodeTestExecutor.readinessProbeReceipt(in: root, connection: changed)
        }
        var skipped = receipt
        skipped["testMethodStarted"] = false
        try JSONSerialization.data(withJSONObject: skipped).write(to: root.appending(path: name))
        #expect(throws: XcodeTestExecutorError.self) {
            _ = try XcodeTestExecutor.readinessProbeReceipt(in: root, connection: connection)
        }
    }

    private func probeReceipt(
        routes: [ScenarioLane: ScenarioReadinessProbeRoute]
    ) -> ScenarioReadinessProbeReceipt {
        .init(
            schemaVersion: 1, testName: "testIntentLabReadiness",
            testIdentifier: "FixtureUITests.IntentLabScenarioTests/testIntentLabReadiness",
            testMethodStarted: true, createdAt: Date(),
            targetBundleIdentifier: "dev.example.Fixture",
            testBundleIdentifier: "dev.example.FixtureUITests",
            integration: .init(
                id: "fixture", version: "1", digest: String(repeating: "a", count: 64)
            ),
            routes: Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) })
        )
    }
}
