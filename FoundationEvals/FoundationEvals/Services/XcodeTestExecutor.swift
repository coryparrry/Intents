import CryptoKit
import Darwin
import Foundation

/// Covers both builds and use of their products, across executor instances.
/// Nonblocking acquisition keeps cancellation responsive when another owner is busy.
final class XcodeBuildWorkspaceLease {
    private let descriptor: Int32

    init(derivedData: URL, fileManager: FileManager = .default) throws {
        let workspace = derivedData.deletingLastPathComponent()
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let lock = workspace.appending(path: ".intentlab-build.lock")
        let descriptor = lock.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            throw XcodeTestExecutorError.connectionCheck("The private build workspace could not be locked.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw XcodeTestExecutorError.connectionCheck(
                "The private build workspace is in use. Wait for its connection check or scenario run to finish."
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private final class SchemeTestableReferenceParser: NSObject, XMLParserDelegate {
    private var inTestAction = false
    private var inTestableReference = false
    private(set) var references: [(targetID: String, container: String)] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "TestAction" { inTestAction = true }
        if elementName == "TestableReference" && inTestAction { inTestableReference = true }
        if elementName == "BuildableReference", inTestableReference,
           let id = attributeDict["BlueprintIdentifier"],
           let container = attributeDict["ReferencedContainer"] {
            references.append((id, container))
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        if elementName == "TestableReference" { inTestableReference = false }
        if elementName == "TestAction" { inTestAction = false }
    }
}

struct XcodeTestConfiguration: Codable, Equatable, Sendable {
    var containerPath: String
    var isWorkspace: Bool
    var scheme: String
    var testTarget: String
    var testBundleIdentifier: String
    var destinationIdentifier: String
    /// Refreshed from xcdevice for the selected identifier, never inferred from its text.
    var destinationPlatform: IntentLabDestinationPlatform? = nil
    var generatedResourceDirectory: String
    var harnessVersion: String? = nil
    var harnessCapabilities: [String]? = nil
    var applicationSigningConfigured: Bool? = nil
    var testSigningConfigured: Bool? = nil
    var configuration: String = "Debug"
    /// Non-nil when the operator explicitly chose a build configuration.
    var configurationOverride: String? = nil
    var xcodebuildPath: String = "/usr/bin/xcodebuild"
    var xcresulttoolPath: String = "/usr/bin/xcrun"
    /// Project path plus Xcode target ID from discovery. Absent in legacy saved setup.
    var selectedTestProductID: String? = nil
    var selectedApplicationProductID: String? = nil
    /// Command-line override only; the Xcode project is not modified.
    var developmentTeam: String? = nil
    /// Explicit opt-in for Xcode to manage development signing assets.
    var allowProvisioningUpdates: Bool? = nil

    var signingArguments: [String] {
        if destinationPlatform == .iOSSimulator {
            return ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM="]
        }
        var arguments: [String] = []
        if allowProvisioningUpdates == true { arguments.append("-allowProvisioningUpdates") }
        if let team = developmentTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty {
            arguments.append("DEVELOPMENT_TEAM=\(team)")
        }
        return arguments
    }
}

enum ScenarioPreflightState: String, Codable, Sendable {
    case ready
    case blocked
    case unknown
}

struct ScenarioPreflightCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var state: ScenarioPreflightState
    var detail: String
}

struct ScenarioPreflightReport: Codable, Equatable, Sendable {
    var checks: [ScenarioPreflightCheck]
    var isReady: Bool { checks.allSatisfy { $0.state == .ready } }
}

enum ScenarioRouteReadinessState: String, Codable, Sendable {
    case ready
    case setupRequired
    case environmentBlocked
    case notYetVerified
}

struct ScenarioRouteReadiness: Codable, Equatable, Sendable {
    var lane: ScenarioLane
    var state: ScenarioRouteReadinessState
    var detail: String
    var checks: [ScenarioPreflightCheck]
    var inspectedAt: Date?
    /// Retained xcresult evidence from the selected test product, when a probe ran.
    var resultBundlePath: String?
    var logPath: String?
    var backendName: String? = nil
    var supportOperationID: String? = nil
    var binding: ScenarioRouteReadinessBinding? = nil
}

struct ScenarioRuntimeProfileIdentity: Codable, Equatable, Sendable {
    var destinationIdentifier: String
    var destinationPlatform: IntentLabDestinationPlatform
    var destinationOSVersion: String
    var xcodeBuild: String
    var sdkBuild: String
}

struct ScenarioRouteReadinessBinding: Codable, Equatable, Sendable {
    var appProduct: ScenarioProductIdentity
    var testHostProduct: ScenarioProductIdentity
    var testProduct: ScenarioProductIdentity
    var runtimeProfile: ScenarioRuntimeProfileIdentity
    var integrationDigest: String
    var buildInputsDigest: String
    var sourceRevision: String
    var productMetadataDigest: String
}

struct ScenarioReadinessProbeRoute: Decodable, Sendable {
    var status: ScenarioRouteReadinessState
    var operationID: String?
    var supportType: String?
    var context: String?
    var observations: [String: ScenarioValue]?
    var detail: String?
}

struct ScenarioReadinessProbeReceipt: Decodable, Sendable {
    struct Integration: Decodable, Sendable {
        var id: String
        var version: String
        var digest: String
    }

    var schemaVersion: Int
    var testName: String
    var testIdentifier: String
    var testMethodStarted: Bool
    var createdAt: Date
    var targetBundleIdentifier: String?
    var testBundleIdentifier: String
    var integration: Integration?
    var routes: [String: ScenarioReadinessProbeRoute]
}

struct ScenarioReadinessProbeEvidence: Sendable {
    var receipt: ScenarioReadinessProbeReceipt?
    var resultBundlePath: String?
    var logPath: String?
    var issue: String?
    var expectedReadinessOperationID: String?
    var failureState: ScenarioRouteReadinessState? = nil
    var globalFailure: Bool = false
}

enum ScenarioConnectionEnvironmentFailure: Equatable, Sendable {
    case frameworkLoad
    case security

    var detail: String {
        switch self {
        case .frameworkLoad:
            "The selected UI-test bundle could not load AppIntentsTesting on this Xcode and runtime profile. Use a compatible toolchain/runtime or select the independent Core Siri test target."
        case .security:
            "AppIntentsTesting rejected this app/test pairing (Code 803). Sign the app and UI-test bundle with the same development team, then check the connection again."
        }
    }
}

struct ScenarioConnectionStageFailure: Sendable {
    var configuration: XcodeTestConfiguration
    var integration: ScenarioIntegrationIdentity
    var targetBundleIdentifier: String
    var products: XCTestRunProductPaths
    var appProduct: ScenarioProductIdentity
    var testHostProduct: ScenarioProductIdentity
    var testProduct: ScenarioProductIdentity
    var buildInputsDigest: String
    var buildGenerationDigest: String
    var productMetadataDigest: String
    var runtimeProfile: ScenarioRuntimeProfileIdentity?
    var kind: ScenarioConnectionEnvironmentFailure
    var resultBundlePath: String?
    var logPath: String
}

enum ScenarioConnectionCancellation: Equatable, Sendable {
    case notRunning
    case beforeDeviceTest
    case recoveryRequired(ScenarioExecutionJournal)
}

struct ScenarioConnectionReceipt: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var integration: ScenarioIntegrationIdentity
    var targetBundleIdentifier: String
    var projectIdentity: String
    var targetIdentity: String
    var testBundleIdentifier: String
    var harnessProtocol: String
    var runnerPackageVersion: String
    var capabilities: [String]
    var inspectedAt: Date
}

struct ScenarioVerifiedConnection: Sendable {
    var receipt: ScenarioConnectionReceipt
    var configuration: XcodeTestConfiguration
    var appProduct: ScenarioProductIdentity
    var testHostProduct: ScenarioProductIdentity
    var testProduct: ScenarioProductIdentity
    var appBundleURL: URL
    var testHostURL: URL
    var testBundleURL: URL
    var testRunURL: URL
    var selectedTestProjectURL: URL
    var buildInputsDigest: String
    var buildGenerationDigest: String
    var sourceRevision: String = ""
    var productMetadataDigest: String
    var runtimeProfile: ScenarioRuntimeProfileIdentity? = nil
    var readinessProbe: ScenarioReadinessProbeEvidence? = nil

    var derivedDataURL: URL {
        testRunURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

enum ScenarioHarnessCapabilities {
    /// Stable v3 definitions still execute through the verified v2 consumer.
    static func usesReusableProtocol(_ definition: ScenarioDefinition) -> Bool {
        definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
            || definition.schemaVersion == ScenarioDefinition.stableSchemaVersion
    }

    static func required(for definition: ScenarioDefinition) -> Set<String> {
        guard usesReusableProtocol(definition) else {
            return ["environment-payload", "fixture-reset", "invocation-correlation", "accessible-result", "direct-intent-output"]
        }
        let includesDirectLane = definition.coverage.intentIntegration != .notApplicable
        var capabilities: Set<String> = ["environment-payload"]
        if definition.actionRequirements != nil { capabilities.insert("action-receipt-v1") }
        if includesDirectLane {
            capabilities.insert("direct-intent-execution")
            if !definition.directControl.outputFields.isEmpty { capabilities.insert("direct-intent-output") }
        }
        let noOpOperations: Set<String> = ["", "none", "noop", "readOnly"]
        if definition.safety.mutationPolicy == .syntheticMutation
            || !noOpOperations.contains(definition.fixture.preparationOperation)
            || !noOpOperations.contains(definition.fixture.cleanupOperation) {
            capabilities.insert("preparation")
        }
        if definition.coverage.siri != .notApplicable {
            capabilities.formUnion(["siri", "siri-completion", "invocation-correlation"])
        }
        for observation in definition.observationPlan ?? [] {
            switch observation.source {
            case .intentResult:
                if includesDirectLane { capabilities.insert("direct-intent-output") }
            case .entityQuery: capabilities.insert("entity-query")
            case .valueQuery: capabilities.insert("value-query")
            case .uiElement: capabilities.insert("accessible-result")
            case .testOnlyIntent: capabilities.insert("test-only-intent")
            }
        }
        return capabilities
    }

    static func required(
        for definition: ScenarioDefinition,
        scope: ScenarioNativeExecutionScope?,
        featureBackend: ScenarioFeatureBackend
    ) -> Set<String> {
        guard let scope else {
            var capabilities = required(for: definition)
            if featureBackend == .projectLocalTestControl
                && definition.coverage.appFeature != .notApplicable {
                capabilities.formUnion(["local-feature-controls", "test-only-intent"])
            }
            return capabilities
        }
        var capabilities: Set<String> = ["environment-payload"]
        if definition.actionRequirements != nil { capabilities.insert("action-receipt-v1") }
        switch scope.lane {
        case .appFeature:
            if featureBackend == .projectLocalTestControl {
                capabilities.formUnion(["local-feature-controls", "test-only-intent"])
            }
        case .intentIntegration:
            capabilities.insert("direct-intent-execution")
            if !definition.directControl.outputFields.isEmpty {
                capabilities.insert("direct-intent-output")
            }
        case .siri:
            capabilities.formUnion(["siri", "siri-completion", "invocation-correlation"])
        }
        let noOpOperations: Set<String> = ["", "none", "noop", "readOnly"]
        if definition.safety.mutationPolicy == .syntheticMutation
            || !noOpOperations.contains(definition.fixture.preparationOperation)
            || !noOpOperations.contains(definition.fixture.cleanupOperation) {
            capabilities.insert("preparation")
        }
        for observation in definition.observationPlan ?? [] where definition.assertions.contains(where: {
            $0.observationKey == observation.id && $0.applies(to: scope.lane)
        }) {
            switch observation.source {
            case .intentResult:
                if scope.lane == .intentIntegration { capabilities.insert("direct-intent-output") }
            case .entityQuery: capabilities.insert("entity-query")
            case .valueQuery: capabilities.insert("value-query")
            case .uiElement: capabilities.insert("accessible-result")
            case .testOnlyIntent: capabilities.insert("test-only-intent")
            }
        }
        return capabilities
    }
}

enum ScenarioDeviceReservation: Codable, Equatable, Sendable {
    case reserved(invocationID: UUID)
    case quarantined(reason: String)
}

struct ScenarioExecutorResult: Sendable {
    var journal: ScenarioExecutionJournal
    var resultBundleURL: URL
    var attachmentDirectory: URL
    var evidenceAttachments: [ScenarioEvidenceAttachment]
    var reportedTestCount: Int?
    var processExitCode: Int32
    var testFailureMessages: [String]
    var measurementImplementation: ScenarioMeasurementImplementation? = nil
}

/// One native lane attempt per XCTest invocation. App Feature is eligible only
/// when the frozen plan explicitly selected the project-local test control.
struct ScenarioNativeExecutionScope: Codable, Equatable, Sendable {
    var lane: ScenarioLane
    var attempt: Int

    func isValid(
        for definition: ScenarioDefinition,
        featureBackend: ScenarioFeatureBackend = .connectedRunner
    ) -> Bool {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion else { return false }
        switch lane {
        case .appFeature:
            return featureBackend == .projectLocalTestControl
                && attempt == 1 && definition.coverage.appFeature != .notApplicable
                && definition.featureBinding != nil
                && definition.actionRequirements?.contains(where: {
                    $0.lane == .appFeature && $0.kind == .productionService
                }) == true
        case .intentIntegration:
            return attempt == 1 && definition.coverage.intentIntegration != .notApplicable
        case .siri:
            let attemptCount = definition.coverage.siriAttemptCount ?? 3
            return definition.coverage.siri != .notApplicable
                && (1...3).contains(attemptCount)
                && (1...attemptCount).contains(attempt)
        }
    }
}

struct ScenarioEvidenceAttachment: Equatable, Sendable {
    var url: URL
    var name: String
    var isCheckpoint: Bool { name.contains("-checkpoint") }
}

enum XcodeTestExecutorError: LocalizedError, Sendable {
    case preflight([ScenarioPreflightCheck])
    case deviceUnavailable(String)
    case activeExecution
    case processLaunch(String)
    case buildFailed(Int32, String)
    case productMissing(String)
    case resourceMismatch(String)
    case testFailed(Int32, String)
    case evidenceMissing
    case cancelled
    case timedOut
    case connectionCheck(String)

    var errorDescription: String? {
        switch self {
        case .preflight(let checks):
            checks.filter { $0.state != .ready }.map(\.detail).joined(separator: " ")
        case .deviceUnavailable(let reason): reason
        case .activeExecution: "Another Intent Lab execution is already active."
        case .processLaunch(let message): "Xcode could not start: \(message)"
        case .buildFailed(let code, let log): "The UI-test bundle failed to build (exit \(code)). \(log)"
        case .productMissing(let message): "The built product could not be verified: \(message)"
        case .resourceMismatch(let message): "The generated test resources are invalid: \(message)"
        case .testFailed(let code, let log): "The UI test failed (exit \(code)). Partial evidence was retained. \(log)"
        case .evidenceMissing: "The result bundle contains no IntentLabEvidence JSON attachment."
        case .cancelled: "The scenario execution was cancelled. Its final device-side outcome is not assumed."
        case .timedOut: "The scenario execution exceeded its deadline. Late evidence remains bound to this timed-out invocation."
        case .connectionCheck(let message): "The integration connection check failed: \(message)"
        }
    }
}

enum XcodeTestDeadlineBudget {
    static let xcodeStartupAndFinalizationSeconds = 60.0
    static let fixtureStartupAndInspectionSeconds = 15.0
    static let siriActivationWaitSeconds = 60.0

    /// ScenarioValidation bounds the configured wait to 1...900 seconds and
    /// the Siri attempt count to 1...3 before an execution reaches this budget.
    static func seconds(
        for definition: ScenarioDefinition,
        scope: ScenarioNativeExecutionScope? = nil
    ) -> Double {
        let scenarioWaitSeconds = definition.safety.deadlineSeconds
        // Local feature controls run only in a scoped native invocation;
        // unscoped feature execution belongs to the connected subject runner.
        let includesFeatureLane = scope?.lane == .appFeature
        let includesDirectLane = scope?.lane == .intentIntegration
            || (scope == nil && definition.coverage.intentIntegration != .notApplicable)
        let siriAttemptCount = scope?.lane == .siri
            ? 1
            : (scope == nil && definition.coverage.siri != .notApplicable
                ? (definition.coverage.siriAttemptCount ?? 3) : 0)
        let fixtureCount = (includesFeatureLane ? 1 : 0) + (includesDirectLane ? 1 : 0) + siriAttemptCount
        // Both local feature and direct lanes bound baseline observation,
        // operation execution, and post-operation observation independently.
        let featureLaneSeconds = includesFeatureLane ? 3 * scenarioWaitSeconds : 0
        let directLaneSeconds = includesDirectLane ? 3 * scenarioWaitSeconds : 0
        let siriSeconds = Double(siriAttemptCount) * (siriActivationWaitSeconds + scenarioWaitSeconds)
        let fixtureSeconds = Double(fixtureCount) * fixtureStartupAndInspectionSeconds

        return xcodeStartupAndFinalizationSeconds + fixtureSeconds + featureLaneSeconds + directLaneSeconds + siriSeconds
    }
}

actor XcodeTestExecutor {
    private struct ActiveExecution {
        var invocationID: UUID
        var destinationIdentifier: String
        var process: Process
        var journal: ScenarioExecutionJournal
    }

    private let workDirectory: URL
    private let persistence: ScenarioPersistence
    private let fileManager: FileManager
    private var active: ActiveExecution?
    private var inFlightJournal: ScenarioExecutionJournal?
    private var awaitingValidationJournal: ScenarioExecutionJournal?
    private var reservations: [String: ScenarioDeviceReservation] = [:]
    private var clearingDestinations: Set<String> = []
    private var cancelledInvocationIDs: Set<UUID> = []
    private var connectionCheckInProgress = false
    private var connectionProcess: Process?
    private var connectionCancellationRequested = false
    private var connectionTestJournal: ScenarioExecutionJournal?
    private var connectionDeviceTestLaunched = false
    private var verifiedConnection: ScenarioVerifiedConnection?
    private var connectionStageFailure: ScenarioConnectionStageFailure?

    init(workDirectory: URL, persistence: ScenarioPersistence, fileManager: FileManager = .default) {
        self.workDirectory = workDirectory
        self.persistence = persistence
        self.fileManager = fileManager
    }

    func reconcileInterruptedJournals() async throws -> [ScenarioExecutionJournal] {
        let journals = try await persistence.loadJournals()
        var recovered: [ScenarioExecutionJournal] = []
        for var journal in journals where [.preparing, .running, .cancelling, .recoveryRequired].contains(journal.phase) {
            removeInvocationTestRuns(derivedDataPath: journal.derivedDataPath)
            if journal.phase != .recoveryRequired {
                journal.phase = .recoveryRequired
                journal.recoveryReason = "The desktop stopped before device-side termination and fixture readiness were established."
                journal.updatedAt = Date()
                try await persistence.saveJournal(journal)
            }
            reservations[journal.invocation.destinationIdentifier] = .quarantined(
                reason: journal.recoveryReason ?? "Recovery is required."
            )
            recovered.append(journal)
        }
        return recovered
    }

    func currentRecoveryJournals() async throws -> [ScenarioExecutionJournal] {
        try await persistence.loadJournals().filter { $0.phase == .recoveryRequired }
    }

    func finishEvidenceValidation(
        journal: ScenarioExecutionJournal,
        accepted: Bool,
        deviceReady: Bool? = nil
    ) async throws {
        var finished = journal
        let destination = journal.invocation.destinationIdentifier
        var canAccept = accepted && !cancelledInvocationIDs.contains(journal.id)
        var canRelease = (deviceReady ?? accepted) && !cancelledInvocationIDs.contains(journal.id)
        finished.phase = canRelease ? .stopped : .recoveryRequired
        finished.recoveryReason = canRelease ? nil
            : "Device execution or fixture readiness has not been proven after evidence capture."
        finished.evidenceAccepted = canAccept
        finished.updatedAt = Date()
        if !canRelease {
            reservations[destination] = .quarantined(reason: finished.recoveryReason!)
        }
        try await persistence.saveJournal(finished)
        // Cancellation can arrive while the journal write is suspended.
        if cancelledInvocationIDs.contains(journal.id) {
            canAccept = false
            canRelease = false
            finished.phase = .recoveryRequired
            finished.recoveryReason = ScenarioExecutionRecoveryPolicy.reason(for: .cancellation)
            finished.evidenceAccepted = false
            finished.updatedAt = Date()
            reservations[destination] = .quarantined(reason: finished.recoveryReason!)
            try await persistence.saveJournal(finished)
        }
        if canRelease { reservations[destination] = nil }
        if awaitingValidationJournal?.id == journal.id { awaitingValidationJournal = nil }
        cancelledInvocationIDs.remove(journal.id)
    }

    private func removeInvocationTestRuns(derivedDataPath: String) {
        let derivedData = URL(filePath: derivedDataPath)
        guard let workspaceLease = try? XcodeBuildWorkspaceLease(derivedData: derivedData, fileManager: fileManager) else { return }
        defer { withExtendedLifetime(workspaceLease) {} }
        removeInvocationTestRuns(derivedData: derivedData)
    }

    private func removeInvocationTestRuns(derivedData: URL) {
        let products = derivedData.appending(path: "Build/Products", directoryHint: .isDirectory)
        guard let files = try? fileManager.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("IntentLab-") && file.pathExtension == "xctestrun" {
            try? fileManager.removeItem(at: file)
        }
    }

    func reservation(for destinationIdentifier: String) -> ScenarioDeviceReservation? {
        reservations[destinationIdentifier]
    }

    func hasActiveExecution() -> Bool {
        active != nil || inFlightJournal != nil || connectionTestJournal != nil
    }

    func connectionDeviceTestIsRunning() -> Bool {
        connectionDeviceTestLaunched && connectionProcess?.isRunning == true
    }

    func persistPreparingJournal(_ journal: ScenarioExecutionJournal) async throws {
        // A malformed prior journal may describe an unresolved device attempt.
        // Do not reserve or launch another attempt until recovery can read every record.
        _ = try await persistence.loadJournals()
        let destination = journal.invocation.destinationIdentifier
        let reservation = ScenarioDeviceReservation.reserved(invocationID: journal.id)
        reservations[destination] = reservation
        inFlightJournal = journal
        do {
            try await persistence.saveJournal(journal)
        } catch {
            if inFlightJournal?.id == journal.id { inFlightJournal = nil }
            if reservations[destination] == reservation {
                reservations[destination] = nil
            }
            throw error
        }
    }

    func beginQuarantineClear(destinationIdentifier: String, fixtureReadinessProven: Bool) throws -> ScenarioDeviceReservation {
        guard fixtureReadinessProven else {
            throw XcodeTestExecutorError.deviceUnavailable(
                "Prove that the prior test session stopped and the fixture is ready before clearing this device quarantine."
            )
        }
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil,
              !connectionCheckInProgress else {
            throw XcodeTestExecutorError.deviceUnavailable(
                "Wait for the cancelled host process to stop before clearing this device quarantine."
            )
        }
        guard let reservation = reservations[destinationIdentifier],
              case .quarantined = reservation else {
            throw XcodeTestExecutorError.deviceUnavailable("The selected device is not quarantined.")
        }
        guard !clearingDestinations.contains(destinationIdentifier) else {
            throw XcodeTestExecutorError.deviceUnavailable("Device quarantine clearing is already in progress.")
        }
        clearingDestinations.insert(destinationIdentifier)
        return reservation
    }

    func endQuarantineClear(destinationIdentifier: String) {
        clearingDestinations.remove(destinationIdentifier)
    }

    func clearQuarantine(destinationIdentifier: String, fixtureReadinessProven: Bool) async throws {
        let reservation = try beginQuarantineClear(
            destinationIdentifier: destinationIdentifier,
            fixtureReadinessProven: fixtureReadinessProven
        )
        defer { endQuarantineClear(destinationIdentifier: destinationIdentifier) }
        let journals = try await persistence.loadJournals()
        for var journal in journals where
            journal.invocation.destinationIdentifier == destinationIdentifier
                && [.preparing, .running, .cancelling, .recoveryRequired].contains(journal.phase) {
            journal.phase = .stopped
            journal.recoveryReason = nil
            journal.updatedAt = Date()
            try await persistence.saveJournal(journal)
        }
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil,
              reservations[destinationIdentifier] == reservation else {
            throw XcodeTestExecutorError.deviceUnavailable("Device recovery state changed while clearing quarantine.")
        }
        reservations[destinationIdentifier] = nil
    }

    func preflight(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        linkedFeatureEvidenceAvailable: Bool = false,
        scope: ScenarioNativeExecutionScope? = nil,
        featureBackend: ScenarioFeatureBackend = .connectedRunner,
        checkedConnection: ScenarioVerifiedConnection? = nil,
        connectionAlreadyChecked: Bool = false
    ) -> ScenarioPreflightReport {
        var checks: [ScenarioPreflightCheck] = []
        func check(_ id: String, _ title: String, _ ready: Bool, _ detail: String) {
            checks.append(.init(id: id, title: title, state: ready ? .ready : .blocked, detail: detail))
        }

        let container = URL(filePath: configuration.containerPath)
        check("trust", "Project trust", projectTrusted,
              projectTrusted ? "The developer approved this project for local build-script execution."
                  : "Approve the selected project before Intents runs its build scripts.")
        check("toolchain", "Xcode toolchain", fileManager.isExecutableFile(atPath: configuration.xcodebuildPath),
              "Expected xcodebuild at \(configuration.xcodebuildPath).")
        check("container", configuration.isWorkspace ? "Workspace" : "Project",
              fileManager.fileExists(atPath: container.path), "Could not find \(container.path).")
        check("scheme", "Scheme", !configuration.scheme.trimmingCharacters(in: .whitespaces).isEmpty,
              "Choose the app-producing scheme.")
        check("testTarget", "UI-test target", !configuration.testTarget.trimmingCharacters(in: .whitespaces).isEmpty,
              "Choose the signed UI-test target containing testIntentLabScenario.")
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition) {
            check("testProductIdentity", "UI-test project and target", configuration.selectedTestProductID != nil,
                  "Choose the owning project and UI-test target; a target name alone is ambiguous in a workspace.")
            check("appProductIdentity", "Application project and target", configuration.selectedApplicationProductID != nil,
                  "Choose the owning project and application target; a bundle ID alone can be ambiguous in a workspace.")
        }
        check("testBundleIdentifier", "Test bundle identity",
              configuration.testBundleIdentifier.contains("."),
              "Enter the UI-test bundle identifier used by the signed test runner.")
        let discoveredCapabilities = Set(configuration.harnessCapabilities ?? [])
        let isReusable = ScenarioHarnessCapabilities.usesReusableProtocol(definition)
        let expectedHarnessVersion = isReusable
            ? ScenarioInvocationIdentity.reusableHarnessVersion
            : ScenarioInvocationIdentity.currentHarnessVersion
        let connection = isReusable
            ? (connectionAlreadyChecked ? checkedConnection
                : currentConnection(definition: definition, configuration: configuration))
            : nil
        check(
            "harness",
            "Intent Lab harness",
            isReusable ? connection != nil : configuration.harnessVersion == expectedHarnessVersion,
            isReusable
                ? "Build and run IntentLabScenarioTests/testIntentLabConnection to verify the \(expectedHarnessVersion) consumer and selected products."
                : "Add INTENT_LAB_HARNESS_VERSION=\(expectedHarnessVersion) to the UI-test target, then include IntentLabScenarioTests/testIntentLabScenario."
        )
        let destination = availableDestination(
            configuration.destinationIdentifier,
            requiresSiri: scope?.lane == .siri
                || (scope == nil && definition.coverage.siri != .notApplicable)
        )
        let macConnectionVerified = isReusable && destination.platform == .macOS && connection != nil
        check("simulatorSigning", "Simulator signing selection",
              Self.signingDestinationMatchesSelection(
                  configuration: configuration, destinationPlatform: destination.platform
              ),
              "Refresh destinations and select an available iOS Simulator before using ad hoc simulator signing.")
        check("signing", "Signing and test execution",
              Self.signingReady(
                  configuration: configuration,
                  destinationPlatform: destination.platform,
                  reusableConnectionVerified: isReusable && connection != nil
              ),
              macConnectionVerified
                  ? "The selected Mac app and UI-test target completed the connection test."
                  : (destination.platform == .iOSSimulator
                      ? "Build and check support on the selected simulator to verify its ad hoc signed test products."
                      : "Select a development team for both targets, or complete the Mac connection test to verify local test execution."))
        if isReusable {
            for capability in ScenarioHarnessCapabilities.required(
                for: definition, scope: scope, featureBackend: featureBackend
            ).sorted() {
                check("capability.\(capability)", capability,
                      connection?.receipt.capabilities.contains(capability) == true,
                      "The compiled integration receipt must confirm \(capability) for this observation plan.")
            }
        } else {
            check("payloadCapability", "Invocation payload", discoveredCapabilities.contains("environment-payload"),
                  "Declare the environment-payload harness capability on the UI-test target.")
            check("fixtureCapability", "Fixture reset", discoveredCapabilities.contains("fixture-reset"),
                  "Provide the -intent-lab-reset launch path and declare fixture-reset.")
            check("correlationCapability", "Invocation correlation", discoveredCapabilities.contains("invocation-correlation"),
                  "Expose the invocation context in the fixture and declare invocation-correlation.")
            check("accessibilityCapability", "Accessible result", discoveredCapabilities.contains("accessible-result"),
                  "Expose the stable Intent Lab accessibility values and declare accessible-result.")
            check("intentOutputCapability", "Intent output", discoveredCapabilities.contains("direct-intent-output"),
                  "Capture direct App Intent output fields and declare direct-intent-output.")
        }
        check("destination", "Execution destination", destination.ready, destination.detail)
        check("siriPlatform", "Siri destination",
              definition.coverage.siri == .notApplicable || destination.platform != .macOS,
              "Siri UI automation requires an iOS destination; Mac supports the other routes.")

        let definitionIssues = ScenarioValidator.issues(in: definition, requireFrozenDigest: true)
        let definitionReady = !definitionIssues.contains { $0.severity == .error }
        check("definition", "Frozen scenario", definitionReady,
              definitionReady ? "The scenario digest and deterministic values are valid."
                  : definitionIssues.filter { $0.severity == .error }.map(\.message).joined(separator: " "))
        if let scope {
            check("nativeScope", "Native route and attempt",
                  scope.isValid(for: definition, featureBackend: featureBackend),
                  "Select one supported route and attempt from a version 3 check. Local Feature control requires its explicit frozen backend.")
        }
        check(
            "featureLane",
            "App feature evidence",
            scope != nil || definition.coverage.appFeature != .required || linkedFeatureEvidenceAvailable,
            scope == nil && definition.coverage.appFeature == .required && !linkedFeatureEvidenceAvailable
                ? "Link a saved production feature run before executing this required lane."
                : "The device harness will preserve the declared Intent and Siri lane requirements."
        )
        if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
           definition.coverage.appFeature != .notApplicable,
           featureBackend == .projectLocalTestControl {
            let capabilities = Set(connection?.receipt.capabilities ?? [])
            check(
                "localFeatureControl", "Project-local Feature control",
                capabilities.contains("local-feature-controls")
                    && capabilities.contains("test-only-intent"),
                "This checked app build must declare local-feature-controls and test-only-intent. The Feature route uses test-only intent transport and cannot run through a different backend without a new plan."
            )
        }

        if connectionCheckInProgress {
            check("connectionCheck", "Connection check", false, "An integration connection check is in progress.")
        }
        if clearingDestinations.contains(configuration.destinationIdentifier) {
            check("reservation", "Device reservation", false, "Device quarantine clearing is in progress.")
        } else if let reservation = reservations[configuration.destinationIdentifier] {
            let detail: String
            switch reservation {
            case .reserved: detail = "The selected device already has an active scenario."
            case .quarantined(let reason): detail = reason
            }
            check("reservation", "Device reservation", false, detail)
        } else {
            check("reservation", "Device reservation", true, "The selected device is available to the executor.")
        }
        return .init(checks: checks)
    }

    func routeReadiness(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        featureBackend: ScenarioFeatureBackend = .connectedRunner
    ) -> [ScenarioLane: ScenarioRouteReadiness] {
        var result: [ScenarioLane: ScenarioRouteReadiness] = [:]
        let connection = ScenarioHarnessCapabilities.usesReusableProtocol(definition)
            ? currentConnection(definition: definition, configuration: configuration) : nil
        let connectionFailure = currentConnectionStageFailure(
            definition: definition, configuration: configuration
        )
        for lane in ScenarioLane.allCases {
            let scope = ScenarioNativeExecutionScope(lane: lane, attempt: 1)
            let report = preflight(
                definition: definition, configuration: configuration,
                projectTrusted: projectTrusted, scope: scope, featureBackend: featureBackend,
                checkedConnection: connection, connectionAlreadyChecked: true
            )
            let probe = connection?.readinessProbe
            var route = Self.readiness(
                lane: lane, report: report, probe: probe,
                included: definition.coverage[lane] != .notApplicable
            )
            if let connection, let profile = connection.runtimeProfile {
                route.binding = .init(
                    appProduct: connection.appProduct,
                    testHostProduct: connection.testHostProduct,
                    testProduct: connection.testProduct,
                    runtimeProfile: profile,
                    integrationDigest: connection.receipt.integration.digest,
                    buildInputsDigest: connection.buildInputsDigest,
                    sourceRevision: connection.sourceRevision,
                    productMetadataDigest: connection.productMetadataDigest
                )
            }
            route.backendName = probe?.receipt?.routes[lane.rawValue]?.supportType
            route.supportOperationID = probe?.receipt?.routes[lane.rawValue]?.operationID
            if let connectionFailure,
               definition.coverage[lane] != .notApplicable {
                Self.applyConnectionEnvironmentFailure(
                    kind: connectionFailure.kind,
                    resultBundlePath: connectionFailure.resultBundlePath,
                    logPath: connectionFailure.logPath,
                    featureBackend: featureBackend,
                    to: &route
                )
            }
            result[lane] = route
        }
        return result
    }

    static func applyConnectionEnvironmentFailure(
        kind: ScenarioConnectionEnvironmentFailure,
        resultBundlePath: String?,
        logPath: String,
        featureBackend: ScenarioFeatureBackend,
        to route: inout ScenarioRouteReadiness
    ) {
        guard route.lane == .intentIntegration
            || (route.lane == .appFeature && featureBackend == .projectLocalTestControl) else {
            return
        }
        route.state = .environmentBlocked
        route.detail = kind.detail
        route.inspectedAt = nil
        route.resultBundlePath = resultBundlePath
        route.logPath = logPath
        route.backendName = "AppIntentsTesting"
    }

    private func currentConnectionStageFailure(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration
    ) -> ScenarioConnectionStageFailure? {
        guard let failure = connectionStageFailure,
              failure.configuration == configuration,
              failure.integration == definition.integration,
              failure.targetBundleIdentifier == definition.target.bundleIdentifier,
              failure.productMetadataDigest == Self.productMetadataDigest(products: failure.products),
              (try? Self.buildGenerationDigest(
                  configuration: configuration, products: failure.products
              )) == failure.buildGenerationDigest,
              (try? Self.productIdentity(
                  bundle: failure.products.appBundleURL,
                  fallbackBundleIdentifier: definition.target.bundleIdentifier
              )) == failure.appProduct,
              (try? Self.productIdentity(
                  bundle: failure.products.testHostURL,
                  fallbackBundleIdentifier: configuration.testBundleIdentifier
              )) == failure.testHostProduct,
              (try? Self.productIdentity(
                  bundle: failure.products.testBundleURL,
                  fallbackBundleIdentifier: configuration.testBundleIdentifier
              )) == failure.testProduct,
              (try? Self.buildInputsDigest(
                  configuration: configuration, products: failure.products
              )) == failure.buildInputsDigest else { return nil }
        if let profile = failure.runtimeProfile,
           Self.runtimeProfile(
               configuration: configuration, appBundleURL: failure.products.appBundleURL
           ) != profile { return nil }
        return failure
    }

    func invalidateRuntimeReadiness(lane: ScenarioLane?, reason: String) {
        guard var connection = verifiedConnection, let probe = connection.readinessProbe else { return }
        connection.readinessProbe = Self.invalidatedProbe(probe, lane: lane, reason: reason)
        verifiedConnection = connection
    }

    static func invalidatedProbe(
        _ original: ScenarioReadinessProbeEvidence,
        lane: ScenarioLane?,
        reason: String
    ) -> ScenarioReadinessProbeEvidence {
        var probe = original
        if let lane, var receipt = probe.receipt, var route = receipt.routes[lane.rawValue] {
            route.status = .environmentBlocked
            route.detail = reason
            receipt.routes[lane.rawValue] = route
            probe.receipt = receipt
        } else {
            probe.receipt = nil
            probe.globalFailure = true
        }
        probe.issue = reason
        probe.failureState = .environmentBlocked
        return probe
    }

    static func readiness(
        lane: ScenarioLane,
        report: ScenarioPreflightReport,
        probe: ScenarioReadinessProbeEvidence?,
        included: Bool = true
    ) -> ScenarioRouteReadiness {
        if !included {
            return .init(lane: lane, state: .notYetVerified,
                         detail: "This route is not included in the current requirement.",
                         checks: report.checks, inspectedAt: nil,
                         resultBundlePath: probe?.resultBundlePath, logPath: probe?.logPath)
        }
        let blockers = report.checks.filter { $0.state != .ready }
        let setupIDs: Set<String> = [
            "trust", "container", "scheme", "testTarget", "testProductIdentity",
            "appProductIdentity", "testBundleIdentifier", "nativeScope", "definition",
            "featureLane"
        ]
        let setup = blockers.filter {
            setupIDs.contains($0.id)
                || (probe != nil && ($0.id.hasPrefix("capability.") || $0.id == "localFeatureControl"))
        }
        let environment = blockers.filter {
            ["toolchain", "destination", "reservation", "connectionCheck"].contains($0.id)
                || ($0.id == "signing" && probe != nil)
        }
        let state: ScenarioRouteReadinessState
        let detail: String
        let inspectedAt: Date?
        if !setup.isEmpty {
            state = .setupRequired
            detail = setup.map(\.detail).joined(separator: " ")
            inspectedAt = nil
        } else if !environment.isEmpty {
            state = .environmentBlocked
            detail = environment.map(\.detail).joined(separator: " ")
            inspectedAt = nil
        } else if !blockers.isEmpty {
            state = .notYetVerified
            detail = blockers.map(\.detail).joined(separator: " ")
            inspectedAt = nil
        } else if probe?.globalFailure == true {
            state = probe?.failureState ?? .environmentBlocked
            detail = probe?.issue ?? "The runtime readiness probe did not complete cleanly."
            inspectedAt = nil
        } else if let route = probe?.receipt?.routes[lane.rawValue] {
            let directDependency = probe?.receipt?.routes[ScenarioLane.intentIntegration.rawValue]
            let inheritedFeatureBlock = lane == .appFeature
                && (directDependency?.status == .environmentBlocked
                    || directDependency?.status == .setupRequired)
            let effectiveStatus = inheritedFeatureBlock
                ? (directDependency?.status ?? .notYetVerified) : route.status
            let effectiveDetail = inheritedFeatureBlock ? directDependency?.detail : route.detail
            let runtimeProofValid = effectiveStatus != .ready || (
                route.context?.isEmpty == false
                    && route.supportType?.isEmpty == false
                    && (lane != .siri || route.observations?["intentlab.readiness.appState"] != nil)
            )
            let transportProofValid = ![ScenarioLane.intentIntegration, .appFeature].contains(lane)
                || effectiveStatus != .ready || (
                probe?.expectedReadinessOperationID?.isEmpty == false
                    && route.operationID == probe?.expectedReadinessOperationID
                    && route.observations?["readiness.ready"] == .boolean(true)
                    && (lane != .appFeature || directDependency?.status == .ready)
            )
            state = runtimeProofValid && transportProofValid ? effectiveStatus : .notYetVerified
            detail = runtimeProofValid && transportProofValid ? (effectiveDetail ?? (effectiveStatus == .ready
                ? "The selected test product exercised this route's readiness support."
                : "The runtime probe did not verify this route."))
                : "The runtime readiness receipt did not prove a fresh support operation and typed observation for this route."
            inspectedAt = probe?.receipt?.createdAt
        } else {
            state = probe?.failureState ?? .notYetVerified
            detail = probe?.issue ?? "Run the connection check to exercise this route on the selected products and destination."
            inspectedAt = nil
        }
        return .init(lane: lane, state: state, detail: detail, checks: report.checks,
                     inspectedAt: inspectedAt, resultBundlePath: probe?.resultBundlePath,
                     logPath: probe?.logPath)
    }

    /// A separate, read-only setup run. Its receipt never becomes scenario evidence.
    /// Execution may keep the checked generation only while every cache
    /// binding remains valid. Explicit support checks still force a new probe.
    func connectionForExecution(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool
    ) async throws -> ScenarioVerifiedConnection {
        guard projectTrusted else {
            throw XcodeTestExecutorError.connectionCheck("Approve this project before running its build scripts.")
        }
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil,
              !connectionCheckInProgress else { throw XcodeTestExecutorError.activeExecution }
        guard reservations[configuration.destinationIdentifier] == nil,
              !clearingDestinations.contains(configuration.destinationIdentifier) else {
            throw XcodeTestExecutorError.deviceUnavailable(
                "This destination requires recovery before another connection check."
            )
        }
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition),
           let connection = currentConnection(definition: definition, configuration: configuration) {
            return connection
        }
        return try await verifyConnection(
            definition: definition, configuration: configuration, projectTrusted: projectTrusted
        )
    }

    func verifyConnection(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool
    ) async throws -> ScenarioVerifiedConnection {
        guard ScenarioHarnessCapabilities.usesReusableProtocol(definition) else {
            throw XcodeTestExecutorError.connectionCheck("A reusable integration is required.")
        }
        guard let integration = definition.integration,
              !integration.id.isEmpty, !integration.version.isEmpty,
              integration.digest.count == 64,
              integration.digest.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }),
              definition.target.bundleIdentifier.contains(".") else {
            throw XcodeTestExecutorError.connectionCheck("Select an app and a valid integration declaration before checking the connection.")
        }
        guard projectTrusted else {
            throw XcodeTestExecutorError.connectionCheck("Approve this project before running its build scripts.")
        }
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil,
              !connectionCheckInProgress else { throw XcodeTestExecutorError.activeExecution }
        guard reservations[configuration.destinationIdentifier] == nil,
              !clearingDestinations.contains(configuration.destinationIdentifier) else {
            throw XcodeTestExecutorError.deviceUnavailable(
                "This destination requires recovery before another connection check."
            )
        }
        guard fileManager.fileExists(atPath: configuration.containerPath),
              fileManager.isExecutableFile(atPath: configuration.xcodebuildPath),
              !configuration.scheme.isEmpty, !configuration.testTarget.isEmpty else {
            throw XcodeTestExecutorError.connectionCheck("Choose a buildable Xcode project, scheme, and UI-test target.")
        }
        let destination = availableDestination(configuration.destinationIdentifier)
        guard destination.ready else { throw XcodeTestExecutorError.deviceUnavailable(destination.detail) }
        guard Self.signingDestinationMatchesSelection(
            configuration: configuration, destinationPlatform: destination.platform
        ) else {
            throw XcodeTestExecutorError.deviceUnavailable(
                "Refresh destinations and select an available iOS Simulator before using ad hoc simulator signing."
            )
        }
        let discovered = try XcodeConnectionDiscoveryService(
            xcodebuildPath: configuration.xcodebuildPath,
            xcdevicePath: configuration.xcresulttoolPath
        ).discoverProject(
            container: URL(filePath: configuration.containerPath), configuration: configuration.configuration,
            signingArguments: configuration.signingArguments
        )
        let sameName = discovered.uiTestBundles.filter { $0.targetName == configuration.testTarget }
        let selected = sameName.first { $0.id == configuration.selectedTestProductID }
        let sameBundle = discovered.applications.filter {
            $0.bundleIdentifier == definition.target.bundleIdentifier
        }
        guard let selected,
              let owningProjectPath = selected.projectPath,
              selected.bundleIdentifier == configuration.testBundleIdentifier,
              sameBundle.count == 1,
              sameBundle.first?.id == configuration.selectedApplicationProductID else {
            throw XcodeTestExecutorError.connectionCheck(
                "The selected project/target identity is missing or an app/test target is ambiguous in this workspace."
            )
        }
        if sameName.count > 1 {
            guard selected.targetID != nil,
                  Self.selectedSchemeContainsTarget(configuration: configuration, product: selected) else {
                throw XcodeTestExecutorError.connectionCheck(
                    "Duplicate UI-test target names require a shared scheme that identifies the selected project and target ID."
                )
            }
        }
        let destination = physicalDestination(
            configuration.destinationIdentifier,
            requiresSiri: definition.coverage.siri != .notApplicable
        )
        guard destination.ready else { throw XcodeTestExecutorError.deviceUnavailable(destination.detail) }
        guard definition.coverage.siri == .notApplicable || destination.platform != .macOS else {
            throw XcodeTestExecutorError.deviceUnavailable("Siri UI automation requires an iOS destination.")
        }

        connectionCheckInProgress = true
        connectionCancellationRequested = false
        connectionTestJournal = nil
        connectionDeviceTestLaunched = false
        verifiedConnection = nil
        connectionStageFailure = nil
        defer {
            connectionCheckInProgress = false
            connectionProcess = nil
            connectionCancellationRequested = false
        }
        let checkID = UUID()
        let directory = workDirectory.appending(path: "Connection-\(checkID.uuidString)", directoryHint: .isDirectory)
        let derivedData = try Self.connectionDerivedDataURL(
            workDirectory: workDirectory, configuration: configuration,
            owningProjectURL: URL(filePath: owningProjectPath)
        )
        let workspaceLease = try XcodeBuildWorkspaceLease(derivedData: derivedData, fileManager: fileManager)
        defer { withExtendedLifetime(workspaceLease) {} }
        removeInvocationTestRuns(derivedData: derivedData)
        let resultBundle = directory.appending(path: "Connection.xcresult", directoryHint: .isDirectory)
        let log = directory.appending(path: "xcodebuild.log")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let buildExit = try await runConnectionCommand(
            configuration: configuration,
            arguments: Self.xcodeArguments(configuration: configuration, derivedData: derivedData) + ["build-for-testing"],
            logURL: log,
            appendLog: false,
            deadline: .seconds(900)
        )
        guard buildExit == 0 else {
            throw XcodeTestExecutorError.connectionCheck("UI-test build failed (exit \(buildExit)). \(tail(of: log))")
        }
        let paths = try XCTestRunInvocationTransport.resolveProducts(
            derivedData: derivedData, testTarget: configuration.testTarget,
            owningProjectURL: URL(filePath: owningProjectPath),
            containerURL: URL(filePath: configuration.containerPath),
            fileManager: fileManager
        )
        let products = try verifyBuiltProducts(definition: definition, configuration: configuration, paths: paths)
        let connectionArguments = Self.testExecutionArguments(
            configuration: configuration, testRunURL: paths.sourceURL,
            resultBundleURL: resultBundle,
            testIdentifier: "IntentLabScenarioTests/testIntentLabConnection"
        )
        let testExit = try await runJournaledConnectionTest(
            definition: definition, configuration: configuration,
            methodName: "testIntentLabConnection", derivedData: derivedData,
            resultBundle: resultBundle,
            arguments: connectionArguments,
            logURL: log, appendLog: true, deadline: .seconds(180)
        )
        let connectionTestCount = resultBundleTestCount(
            configuration: configuration, resultBundle: resultBundle
        )
        guard testExit == 0, connectionTestCount == 1 else {
            let logTail = tail(of: log)
            let kind = Self.connectionEnvironmentFailure(
                testExit: testExit, testCount: connectionTestCount,
                failureMessages: resultBundleFailureMessages(
                    configuration: configuration, resultBundle: resultBundle
                ),
                logTail: logTail,
                selectedDirectFramework: Self.declarationRequiresAppIntentsTesting(
                    in: paths.testBundleURL
                )
            )
            if let kind,
               let inputDigest = try? Self.buildInputsDigest(
                   configuration: configuration, products: paths
               ),
               let testHostProduct = try? Self.productIdentity(
                   bundle: paths.testHostURL,
                   fallbackBundleIdentifier: configuration.testBundleIdentifier
               ), let integration = definition.integration {
                connectionStageFailure = .init(
                    configuration: configuration, integration: integration,
                    targetBundleIdentifier: definition.target.bundleIdentifier,
                    products: paths, appProduct: products.app,
                    testHostProduct: testHostProduct, testProduct: products.test,
                    buildInputsDigest: inputDigest,
                    buildGenerationDigest: try Self.buildGenerationDigest(
                        configuration: configuration, products: paths
                    ),
                    productMetadataDigest: Self.productMetadataDigest(products: paths),
                    runtimeProfile: Self.runtimeProfile(
                        configuration: configuration, appBundleURL: paths.appBundleURL
                    ),
                    kind: kind,
                    resultBundlePath: fileManager.fileExists(atPath: resultBundle.path)
                        ? resultBundle.path : nil,
                    logPath: log.path
                )
            }
            throw XcodeTestExecutorError.connectionCheck(
                "\(kind?.detail ?? "The fixed connection test did not complete once") "
                    + "(exit \(testExit), tests \(connectionTestCount.map { String($0) } ?? "unknown")). "
                    + (fileManager.fileExists(atPath: resultBundle.path)
                        ? "Result bundle: \(resultBundle.path). "
                        : "No result bundle was produced. ")
                    + logTail
            )
        }
        let attachments = directory.appending(path: "Attachments", directoryHint: .isDirectory)
        _ = try exportAttachments(
            configuration: configuration, resultBundle: resultBundle,
            outputDirectory: attachments, invocationID: checkID
        )
        let receipt = try Self.connectionReceipt(in: attachments)
        let fingerprint = try Self.buildInputsFingerprint(configuration: configuration, products: paths)
        let verified = ScenarioVerifiedConnection(
            receipt: receipt, configuration: configuration,
            appProduct: products.app,
            testHostProduct: try Self.productIdentity(
                bundle: paths.testHostURL, fallbackBundleIdentifier: configuration.testBundleIdentifier
            ),
            testProduct: products.test,
            appBundleURL: paths.appBundleURL, testHostURL: paths.testHostURL,
            testBundleURL: paths.testBundleURL,
            testRunURL: paths.sourceURL,
            selectedTestProjectURL: URL(filePath: owningProjectPath),
            buildInputsDigest: fingerprint.digest,
            buildGenerationDigest: try Self.buildGenerationDigest(
                configuration: configuration, products: paths
            ),
            sourceRevision: Self.sourceRevision(
                sourceLocations: fingerprint.sourceLocations, buildInputsDigest: fingerprint.digest
            ),
            productMetadataDigest: Self.productMetadataDigest(products: paths),
            runtimeProfile: Self.runtimeProfile(configuration: configuration, appBundleURL: paths.appBundleURL)
        )
        guard Self.validatedReusableConnection(
            verified, definition: definition, configuration: configuration,
            currentRuntimeProfile: Self.runtimeProfile(
                configuration: configuration, appBundleURL: verified.appBundleURL
            )
        ) != nil else {
            throw XcodeTestExecutorError.connectionCheck(
                "The compiled declaration, capabilities, or app/test identity did not match the selected integration."
            )
        }
        let probeResultBundle = directory.appending(path: "Readiness.xcresult", directoryHint: .isDirectory)
        let probeLog = directory.appending(path: "readiness-xcodebuild.log")
        var probe = ScenarioReadinessProbeEvidence(
            receipt: nil, resultBundlePath: probeResultBundle.path,
            logPath: probeLog.path, issue: nil,
            expectedReadinessOperationID: Self.readinessOperationID(in: paths.testBundleURL),
            failureState: nil
        )
        let requiresAppIntentsTesting = receipt.capabilities.contains("direct-intent-execution")
            || receipt.capabilities.contains("local-feature-controls")
        if requiresAppIntentsTesting {
            let appTeam = Self.signingTeamIdentifier(of: paths.appBundleURL)
            let hostTeam = Self.signingTeamIdentifier(of: paths.testHostURL)
            let testTeam = Self.signingTeamIdentifier(of: paths.testBundleURL)
            let adHocSignaturesValid = configuration.destinationPlatform == .iOSSimulator
                && [paths.appBundleURL, paths.testHostURL, paths.testBundleURL]
                    .allSatisfy(Self.validAdHocSignature)
            guard Self.signingAcceptedForReadiness(
                configuration: configuration,
                runtimePlatform: verified.runtimeProfile?.destinationPlatform,
                appTeam: appTeam, hostTeam: hostTeam, testTeam: testTeam,
                adHocSignaturesValid: adHocSignaturesValid
            ) else {
                probe.failureState = .environmentBlocked
                probe.globalFailure = true
                probe.issue = configuration.destinationPlatform == .iOSSimulator
                    ? "The iOS Simulator app, UI-test runner, and test bundle must each have a valid ad hoc signature. Build and check the selected simulator again."
                    : "AppIntentsTesting requires the selected app, UI-test runner, and test bundle to have valid signatures from the same development team. Configure signing and check the connection again."
                probe.resultBundlePath = nil
                probe.logPath = nil
                var result = verified
                result.readinessProbe = probe
                verifiedConnection = result
                return result
            }
        }
        do {
            let probeExit = try await runJournaledConnectionTest(
                definition: definition, configuration: configuration,
                methodName: "testIntentLabReadiness", derivedData: derivedData,
                resultBundle: probeResultBundle,
                arguments: Self.testExecutionArguments(
                    configuration: configuration, testRunURL: paths.sourceURL,
                    resultBundleURL: probeResultBundle,
                    testIdentifier: "IntentLabScenarioTests/testIntentLabReadiness"
                ),
                logURL: probeLog, appendLog: false, deadline: .seconds(180)
            )
            let count = resultBundleTestCount(configuration: configuration, resultBundle: probeResultBundle)
            guard Self.probeTestCountIsValid(count) else {
                throw XcodeTestExecutorError.connectionCheck(
                    "The readiness test did not execute exactly once (reported \(count.map { String($0) } ?? "unknown") tests)."
                )
            }
            let probeAttachments = directory.appending(path: "ReadinessAttachments", directoryHint: .isDirectory)
            _ = try exportAttachments(
                configuration: configuration, resultBundle: probeResultBundle,
                outputDirectory: probeAttachments, invocationID: checkID
            )
            probe.receipt = try Self.readinessProbeReceipt(in: probeAttachments, connection: receipt)
            if probeExit != 0 {
                probe.issue = "The readiness test reported a failure (exit \(probeExit)); inspect the retained result bundle and log."
                probe.failureState = .environmentBlocked
                probe.globalFailure = true
            }
        } catch {
            if connectionCancellationRequested { throw XcodeTestExecutorError.cancelled }
            let count = resultBundleTestCount(configuration: configuration, resultBundle: probeResultBundle)
            probe.failureState = count == 0 ? .setupRequired : .environmentBlocked
            probe.globalFailure = true
            probe.issue = "The runtime readiness probe did not verify this route: \(error.localizedDescription) \(tail(of: probeLog))"
        }
        var result = verified
        result.readinessProbe = probe
        verifiedConnection = result
        return result
    }

    func currentConnection(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration
    ) -> ScenarioVerifiedConnection? {
        guard let verifiedConnection else { return nil }
        return Self.validatedReusableConnection(
            verifiedConnection, definition: definition, configuration: configuration,
            currentRuntimeProfile: Self.runtimeProfile(
                configuration: configuration, appBundleURL: verifiedConnection.appBundleURL
            )
        )
    }

    /// This is only an incremental build cache key. Source/product/runtime evidence
    /// is recomputed by every connection check and validated again before execution.
    static func connectionDerivedDataURL(
        workDirectory: URL,
        configuration: XcodeTestConfiguration,
        owningProjectURL: URL
    ) throws -> URL {
        var selection = configuration
        selection.containerPath = URL(filePath: selection.containerPath).resolvingSymlinksInPath().path
        selection.generatedResourceDirectory = URL(filePath: selection.generatedResourceDirectory).resolvingSymlinksInPath().path
        selection.xcodebuildPath = URL(filePath: selection.xcodebuildPath).resolvingSymlinksInPath().path
        selection.xcresulttoolPath = URL(filePath: selection.xcresulttoolPath).resolvingSymlinksInPath().path
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode([
            "version": "1",
            "configuration": String(decoding: encoder.encode(selection), as: UTF8.self),
            "owningTestProject": owningProjectURL.resolvingSymlinksInPath().path,
        ])
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return workDirectory.appending(path: "BuildWorkspaces/\(digest)/DerivedData", directoryHint: .isDirectory)
    }

    /// Validate cached products against source files, generated products, and
    /// the current runtime snapshot. Runtime discovery stays lazy so invalid
    /// source or product bindings fail before invoking developer tools.
    static func validatedReusableConnection(
        _ connection: ScenarioVerifiedConnection,
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        currentRuntimeProfile: @autoclosure () -> ScenarioRuntimeProfileIdentity?
    ) -> ScenarioVerifiedConnection? {
        let receipt = connection.receipt
        guard connection.configuration == configuration,
              receipt.schemaVersion == 1,
              Self.receiptMatchesSelection(receipt, configuration: configuration,
                                           selectedProjectURL: connection.selectedTestProjectURL),
              receipt.integration == definition.integration,
              receipt.targetBundleIdentifier == definition.target.bundleIdentifier,
              receipt.testBundleIdentifier == connection.testProduct.bundleIdentifier,
              receipt.testBundleIdentifier == configuration.testBundleIdentifier,
              receipt.harnessProtocol == ScenarioInvocationIdentity.reusableHarnessVersion,
              !receipt.runnerPackageVersion.isEmpty,
              Set(receipt.capabilities).count == receipt.capabilities.count,
              receipt.capabilities.contains("environment-payload"),
              let app = try? Self.productIdentity(
                  bundle: connection.appBundleURL,
                  fallbackBundleIdentifier: definition.target.bundleIdentifier
              ),
              let test = try? Self.productIdentity(
                  bundle: connection.testBundleURL,
                  fallbackBundleIdentifier: configuration.testBundleIdentifier
              ),
              let testHost = try? Self.productIdentity(
                  bundle: connection.testHostURL,
                  fallbackBundleIdentifier: configuration.testBundleIdentifier
              ),
              app == connection.appProduct, test == connection.testProduct,
              testHost == connection.testHostProduct,
              connection.productMetadataDigest == Self.productMetadataDigest(products: .init(
                  sourceURL: connection.testRunURL,
                  appBundleURL: connection.appBundleURL,
                  testHostURL: connection.testHostURL,
                  testBundleURL: connection.testBundleURL
              )),
              (try? Self.buildGenerationDigest(
                  configuration: configuration,
                  products: .init(
                      sourceURL: connection.testRunURL,
                      appBundleURL: connection.appBundleURL,
                      testHostURL: connection.testHostURL,
                      testBundleURL: connection.testBundleURL
                  )
              )) == connection.buildGenerationDigest,
              let inputs = try? Self.buildInputsDigest(
                  configuration: configuration,
                  products: .init(
                      sourceURL: connection.testRunURL,
                      appBundleURL: connection.appBundleURL,
                      testHostURL: connection.testHostURL,
                      testBundleURL: connection.testBundleURL
                  )
              ),
              inputs == connection.buildInputsDigest,
              let runtimeProfile = connection.runtimeProfile,
              runtimeProfile == currentRuntimeProfile(),
              let declaration = try? Data(contentsOf: connection.testBundleURL.appending(path: "IntentLabIntegration.json")),
              SHA256.hash(data: declaration).map({ String(format: "%02x", $0) }).joined()
                == definition.integration?.digest else { return nil }
        return connection
    }

    static func receiptMatchesSelection(
        _ receipt: ScenarioConnectionReceipt,
        configuration: XcodeTestConfiguration,
        selectedProjectURL: URL
    ) -> Bool {
        let project = selectedProjectURL.standardizedFileURL
        guard let selectedID = configuration.selectedTestProductID,
              let separator = selectedID.lastIndex(of: "#"),
              !selectedID[selectedID.index(after: separator)...].isEmpty,
              URL(filePath: String(selectedID[..<separator])).standardizedFileURL.path == project.path,
              receipt.targetIdentity == configuration.testTarget else { return false }
        let declaredProject = receipt.projectIdentity
        guard !declaredProject.isEmpty, !declaredProject.hasPrefix("/") else { return false }
        let container = URL(filePath: configuration.containerPath).standardizedFileURL
        if declaredProject.contains("/") {
            return URL(filePath: declaredProject, relativeTo: container.deletingLastPathComponent())
                .standardizedFileURL.path == project.path
        }
        guard declaredProject == project.lastPathComponent else { return false }
        if configuration.isWorkspace {
            guard let projects = try? XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: container),
                  projects.filter({ $0.lastPathComponent == declaredProject }).count == 1,
                  projects.contains(where: { $0.standardizedFileURL.path == project.path }) else { return false }
        } else if container.path != project.path {
            return false
        }
        return true
    }

    static func connectionReceipt(in directory: URL) throws -> ScenarioConnectionReceipt {
        let manifestURL = directory.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XcodeTestExecutorError.connectionCheck("The connection attachment manifest is invalid.")
        }
        let attachments = entries
            .filter { $0["testIdentifier"] as? String == "IntentLabScenarioTests/testIntentLabConnection()" }
            .flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
            .filter { ($0["suggestedHumanReadableName"] as? String)?.hasPrefix("IntentLabConnectionReceipt-") == true }
        guard attachments.count == 1,
              let filename = attachments[0]["exportedFileName"] as? String,
              filename == URL(filePath: filename).lastPathComponent,
              filename.hasSuffix(".json") else {
            throw XcodeTestExecutorError.connectionCheck("Exactly one final connection receipt is required.")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appending(path: filename).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == root,
              let bytes = try? Data(contentsOf: url), bytes.count <= 64_000 else {
            throw XcodeTestExecutorError.connectionCheck("The connection receipt is missing, oversized, or outside the export directory.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScenarioConnectionReceipt.self, from: bytes)
    }

    static func readinessProbeReceipt(
        in directory: URL,
        connection: ScenarioConnectionReceipt
    ) throws -> ScenarioReadinessProbeReceipt {
        let manifestURL = directory.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XcodeTestExecutorError.connectionCheck("The readiness attachment manifest is invalid.")
        }
        let attachments = entries
            .filter { $0["testIdentifier"] as? String == "IntentLabScenarioTests/testIntentLabReadiness()" }
            .flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
            .filter { ($0["suggestedHumanReadableName"] as? String)?.hasPrefix("IntentLabReadinessReceipt-") == true }
        guard attachments.count == 1,
              let filename = attachments[0]["exportedFileName"] as? String,
              filename == URL(filePath: filename).lastPathComponent,
              filename.hasSuffix(".json") else {
            throw XcodeTestExecutorError.connectionCheck("Exactly one final readiness receipt is required.")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appending(path: filename).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == root,
              let bytes = try? Data(contentsOf: url), bytes.count <= 64_000 else {
            throw XcodeTestExecutorError.connectionCheck(
                "The readiness receipt is missing, oversized, or outside the export directory."
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(ScenarioReadinessProbeReceipt.self, from: bytes)
        guard receipt.schemaVersion == 1,
              receipt.testName == "testIntentLabReadiness",
              receipt.testMethodStarted,
              receipt.testIdentifier.hasSuffix("IntentLabScenarioTests/testIntentLabReadiness")
                || receipt.testIdentifier.hasSuffix("IntentLabScenarioTests/testIntentLabReadiness()"),
              receipt.targetBundleIdentifier == connection.targetBundleIdentifier,
              receipt.testBundleIdentifier == connection.testBundleIdentifier,
              receipt.integration?.id == connection.integration.id,
              receipt.integration?.version == connection.integration.version,
              receipt.integration?.digest == connection.integration.digest,
              receipt.createdAt >= connection.inspectedAt.addingTimeInterval(-5),
              receipt.createdAt <= connection.inspectedAt.addingTimeInterval(600),
              receipt.routes.count <= ScenarioLane.allCases.count,
              receipt.routes.keys.allSatisfy({ ScenarioLane(rawValue: $0) != nil }) else {
            throw XcodeTestExecutorError.connectionCheck(
                "The runtime readiness receipt does not match the selected integration or test method."
            )
        }
        return receipt
    }

    static func probeTestCountIsValid(_ count: Int?) -> Bool { count == 1 }

    static func connectionEnvironmentFailure(
        testExit: Int32,
        testCount: Int?,
        failureMessages: [String],
        logTail: String,
        selectedDirectFramework: Bool
    ) -> ScenarioConnectionEnvironmentFailure? {
        guard testExit != 0 || testCount != 1 else { return nil }
        let evidence = (failureMessages.joined(separator: "\n") + "\n" + logTail).lowercased()
        let frameworkNamed = evidence.contains("appintentstesting")
            || (selectedDirectFramework && evidence.contains("appintentsservices"))
        let loadFailure = [
            "symbol not found", "library not loaded", "framework not found",
            "failed to load", "couldn't be loaded", "could not be loaded", "dlopen("
        ].contains { evidence.contains($0) }
        if frameworkNamed && loadFailure { return .frameworkLoad }

        let securityDomain = evidence.contains("appintentsservicessecurityerrordomain")
        let customerBuild = evidence.contains("customer build")
        let code803 = evidence.contains("code=803") || evidence.contains("code 803")
        if (selectedDirectFramework || frameworkNamed || securityDomain)
            && (securityDomain || customerBuild || selectedDirectFramework)
            && code803 {
            return .security
        }
        return nil
    }

    private static func declarationRequiresAppIntentsTesting(in testBundleURL: URL) -> Bool {
        let url = testBundleURL.appending(path: "IntentLabIntegration.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = object["capabilities"] as? [String] else { return false }
        return capabilities.contains("direct-intent-execution")
            || capabilities.contains("local-feature-controls")
    }

    private static func readinessOperationID(in testBundleURL: URL) -> String? {
        let url = testBundleURL.appending(path: "IntentLabIntegration.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let control = object["readinessControl"] as? [String: Any],
              let operationID = control["operationID"] as? String,
              !operationID.isEmpty else { return nil }
        return operationID
    }

    /// Derive Xcode build-setting values from the built test bundle's generated
    /// metadata, then forward them to the XCTest process. Inheriting the host's
    /// environment would describe the app running the UI, not the selected SDK.
    static func executionBuildEnvironment(
        testBundleURL: URL,
        destinationPlatform: IntentLabDestinationPlatform?
    ) -> [String: String]? {
        let infoURL = testBundleURL.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let sdkName = info["DTSDKName"] as? String,
              let sdkRange = sdkName.range(of: #"\d+(?:\.\d+)*$"#, options: .regularExpression),
              let platformName = info["DTPlatformName"] as? String else { return nil }
        let xcodeVersion = (info["DTXcode"] as? String)
            ?? (info["DTXcode"] as? NSNumber)?.stringValue
        guard let xcodeVersion, !xcodeVersion.isEmpty,
              xcodeVersion.lowercased() != "unknown" else { return nil }
        let sdkPlatform: String
        if sdkName.hasPrefix("iphonesimulator") {
            sdkPlatform = "iphonesimulator"
        } else if sdkName.hasPrefix("iphoneos") {
            sdkPlatform = "iphoneos"
        } else if sdkName.hasPrefix("macosx") {
            sdkPlatform = "macosx"
        } else {
            return nil
        }
        guard platformName == sdkPlatform else { return nil }
        if let destinationPlatform {
            let expectedPlatform: String
            switch destinationPlatform {
            case .iOS: expectedPlatform = "iphoneos"
            case .iOSSimulator: expectedPlatform = "iphonesimulator"
            case .macOS: expectedPlatform = "macosx"
            }
            guard sdkPlatform == expectedPlatform else { return nil }
        }
        return [
            "XCODE_VERSION_ACTUAL": xcodeVersion,
            "SDK_VERSION": String(sdkName[sdkRange]),
        ]
    }

    private static func runtimeProfile(
        configuration: XcodeTestConfiguration,
        appBundleURL: URL
    ) -> ScenarioRuntimeProfileIdentity? {
        guard let destination = try? XcodeConnectionDiscoveryService().discoverDevices()
                .first(where: { $0.identifier == configuration.destinationIdentifier && $0.available }),
              let destinationOSVersion = Self.destinationOSVersion(
                  for: destination,
                  simulatorListing: destination.platform == .iOSSimulator
                    && destination.operatingSystemVersion == nil
                    ? commandData(configuration.xcresulttoolPath,
                        ["simctl", "list", "devices", "--json"])
                    : nil
              ),
              !destinationOSVersion.isEmpty,
              let infoData = try? Data(contentsOf: appBundleURL.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(
                  from: infoData, format: nil
              ) as? [String: Any],
              let builtXcode = info["DTXcodeBuild"] as? String, !builtXcode.isEmpty,
              let builtSDK = info["DTSDKBuild"] as? String, !builtSDK.isEmpty,
              let runningXcode = commandOutput(configuration.xcodebuildPath, ["-version"]),
              let sdk = commandOutput(configuration.xcresulttoolPath, [
                  "--sdk", destination.platform == .macOS ? "macosx"
                    : (destination.platform == .iOSSimulator ? "iphonesimulator" : "iphoneos"),
                  "--show-sdk-build-version"
              ]) else { return nil }
        return .init(
            destinationIdentifier: destination.identifier,
            destinationPlatform: destination.platform,
            destinationOSVersion: destinationOSVersion,
            xcodeBuild: "\(runningXcode) / built \(builtXcode)",
            sdkBuild: "\(sdk) / built \(builtSDK)"
        )
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count < 16_000 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func destinationOSVersion(
        for destination: IntentLabDeviceDestination,
        simulatorListing: Data?
    ) -> String? {
        if let version = destination.operatingSystemVersion, !version.isEmpty { return version }
        switch destination.platform {
        case .macOS: return ProcessInfo.processInfo.operatingSystemVersionString
        case .iOS: return nil
        case .iOSSimulator:
            return simulatorOSVersion(identifier: destination.identifier, listing: simulatorListing)
        }
    }

    static func simulatorOSVersion(identifier: String, listing: Data?) -> String? {
        guard let listing,
              let root = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return nil }
        for (runtime, entries) in devices {
            guard entries.contains(where: {
                $0["udid"] as? String == identifier && $0["state"] as? String == "Booted"
            }), let marker = runtime.range(of: "iOS-", options: .backwards) else { continue }
            let components = runtime[marker.upperBound...].split(separator: "-")
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { continue }
            return components.joined(separator: ".")
        }
        return nil
    }

    private static func commandData(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && data.count <= 1_000_000 ? data : nil
    }

    private static func signingTeamIdentifier(of bundle: URL) -> String? {
        let verify = Process()
        verify.executableURL = URL(filePath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        do { try verify.run() } catch { return nil }
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { return nil }

        let inspect = Process()
        inspect.executableURL = URL(filePath: "/usr/bin/codesign")
        inspect.arguments = ["-dv", "--verbose=4", bundle.path]
        let output = Pipe()
        inspect.standardOutput = FileHandle.nullDevice
        inspect.standardError = output
        do { try inspect.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        inspect.waitUntilExit()
        guard inspect.terminationStatus == 0, data.count < 16_000 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let value = lines.first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = value.dropFirst("TeamIdentifier=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return team.isEmpty || team == "not set" ? nil : team
    }

    private static func validAdHocSignature(of bundle: URL) -> Bool {
        let verify = Process()
        verify.executableURL = URL(filePath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        do { try verify.run() } catch { return false }
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { return false }

        let inspect = Process()
        inspect.executableURL = URL(filePath: "/usr/bin/codesign")
        inspect.arguments = ["-dv", "--verbose=4", bundle.path]
        inspect.standardOutput = FileHandle.nullDevice
        let output = Pipe()
        inspect.standardError = output
        do { try inspect.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        inspect.waitUntilExit()
        guard inspect.terminationStatus == 0, data.count < 16_000 else { return false }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .contains("Signature=adhoc")
    }

    static func signingAcceptedForReadiness(
        configuration: XcodeTestConfiguration,
        runtimePlatform: IntentLabDestinationPlatform?,
        appTeam: String?, hostTeam: String?, testTeam: String?,
        adHocSignaturesValid: Bool
    ) -> Bool {
        if configuration.destinationPlatform == .iOSSimulator {
            return runtimePlatform == .iOSSimulator && adHocSignaturesValid
        }
        return matchingSigningTeam(appTeam: appTeam, hostTeam: hostTeam, testTeam: testTeam)
    }

    static func matchingSigningTeam(
        appTeam: String?, hostTeam: String?, testTeam: String?
    ) -> Bool {
        guard let appTeam, let hostTeam, let testTeam,
              !appTeam.isEmpty, appTeam == hostTeam, appTeam == testTeam else { return false }
        return true
    }

    static func selectedSchemeContainsTarget(
        configuration: XcodeTestConfiguration,
        product: XcodeDiscoveredProduct,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let projectPath = product.projectPath, let targetID = product.targetID,
              configuration.scheme == URL(filePath: configuration.scheme).lastPathComponent,
              !configuration.scheme.isEmpty else { return false }
        let container = URL(filePath: configuration.containerPath).standardizedFileURL
        let project = URL(filePath: projectPath).standardizedFileURL
        let workspaceScheme = container.appending(path: "xcshareddata/xcschemes/\(configuration.scheme).xcscheme")
        let projectScheme = project.appending(path: "xcshareddata/xcschemes/\(configuration.scheme).xcscheme")
        let scheme = configuration.isWorkspace && fileManager.fileExists(atPath: workspaceScheme.path)
            ? workspaceScheme : projectScheme
        guard let data = try? Data(contentsOf: scheme) else { return false }
        let parser = XMLParser(data: data)
        let collector = SchemeTestableReferenceParser()
        parser.delegate = collector
        guard parser.parse() else { return false }
        let base = (scheme == workspaceScheme ? container : project).deletingLastPathComponent()
        return collector.references.contains { reference in
            guard reference.targetID == targetID,
                  reference.container.hasPrefix("container:") else { return false }
            let relative = String(reference.container.dropFirst("container:".count))
            return URL(filePath: relative, relativeTo: base).standardizedFileURL.path == project.path
        }
    }

    static func buildInputsDigest(
        configuration: XcodeTestConfiguration,
        products: XCTestRunProductPaths,
        fileManager: FileManager = .default
    ) throws -> String {
        try buildInputsFingerprint(configuration: configuration, products: products,
                                   fileManager: fileManager).digest
    }

    static func buildInputsFingerprint(
        configuration: XcodeTestConfiguration,
        products: XCTestRunProductPaths,
        fileManager: FileManager = .default
    ) throws -> (digest: String, sourceLocations: Set<URL>) {
        let container = URL(filePath: configuration.containerPath)
        var files: [String: URL] = [:]
        let projects: [URL]
        if configuration.isWorkspace {
            guard let discovered = try? XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: container),
                  !discovered.isEmpty else {
                throw XcodeTestExecutorError.resourceMismatch(
                    "The selected workspace has no resolvable project sources to fingerprint."
                )
            }
            projects = discovered
        } else {
            projects = [container]
        }
        let workspaceFiles = [
            ("workspace/contents.xcworkspacedata", container.appending(path: "contents.xcworkspacedata")),
            ("workspace/xcshareddata/swiftpm/Package.resolved", container.appending(path: "xcshareddata/swiftpm/Package.resolved")),
            ("workspace/Package.resolved", container.deletingLastPathComponent().appending(path: "Package.resolved")),
        ]
        for (key, file) in workspaceFiles { files[key] = file }
        let containerBase = container.deletingLastPathComponent().standardizedFileURL
        for project in projects {
            let projectLabel = Self.relativePath(of: project, from: containerBase)
            let prefix = "project/\(projectLabel)"
            files["\(prefix)/project.pbxproj"] = project.appending(path: "project.pbxproj")
            files["\(prefix)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"] =
                project.appending(path: "project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        }
        for schemeContainer in (configuration.isWorkspace ? [container] + projects : projects) {
            let schemes = schemeContainer.appending(path: "xcshareddata/xcschemes", directoryHint: .isDirectory)
            if let entries = try? fileManager.contentsOfDirectory(at: schemes, includingPropertiesForKeys: nil) {
                let base = schemeContainer == container ? "workspace" : "project/\(Self.relativePath(of: schemeContainer, from: containerBase))"
                for entry in entries where entry.pathExtension == "xcscheme" {
                    files["\(base)/xcshareddata/xcschemes/\(entry.lastPathComponent)"] = entry
                }
            }
        }
        var hasher = SHA256()
        for (key, file) in files.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(key.utf8))
            if let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) {
                hasher.update(data: data)
            } else {
                hasher.update(data: Data("<missing>".utf8))
            }
        }
        let projectSources = try hashProjectSources(projects: projects, container: container,
                                                    xcodebuildPath: configuration.xcodebuildPath, into: &hasher,
                                                    fileManager: fileManager)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let existingConfiguration = files.compactMap { key, value -> URL? in
            guard key.hasPrefix("workspace/") || key.hasPrefix("project/"),
                  fileManager.fileExists(atPath: value.path) else { return nil }
            return value
        }
        let sourceLocations = projectSources.union([container]).union(existingConfiguration)
        return (digest, sourceLocations)
    }

    /// Generated products and the selected compiler are checked independently
    /// from source identity. Their locations intentionally bind this cache to
    /// one DerivedData generation while source digests remain portable.
    static func buildGenerationDigest(
        configuration: XcodeTestConfiguration,
        products: XCTestRunProductPaths,
        fileManager: FileManager = .default
    ) throws -> String {
        var hasher = SHA256()
        let productPaths: [(String, URL)] = [
            ("test-run", products.sourceURL),
            ("app", products.appBundleURL),
            ("test-host", products.testHostURL),
            ("test-bundle", products.testBundleURL),
        ]
        for (label, url) in productPaths {
            hasher.update(data: Data(label.utf8))
            hasher.update(data: Data(url.standardizedFileURL.path.utf8))
        }
        hasher.update(data: Data(productMetadataDigest(products: products).utf8))
        if let data = try? Data(contentsOf: products.sourceURL, options: [.mappedIfSafe]) {
            hasher.update(data: data)
        } else {
            hasher.update(data: Data("<missing-test-run>".utf8))
        }
        let toolPath = URL(filePath: configuration.xcodebuildPath).resolvingSymlinksInPath().path
        hasher.update(data: Data(toolPath.utf8))
        if let attributes = try? fileManager.attributesOfItem(atPath: toolPath) {
            let stamp = "\(attributes[.modificationDate] ?? "unknown"):\(attributes[.size] ?? "unknown")"
            hasher.update(data: Data(stamp.utf8))
        } else {
            hasher.update(data: Data("<missing-xcodebuild>".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        let source = url.standardizedFileURL.pathComponents
        let root = base.standardizedFileURL.pathComponents
        let sharedCount = zip(source, root).prefix { pair in pair.0 == pair.1 }.count
        let parts = Array(repeating: "..", count: root.count - sharedCount)
            + Array(source.dropFirst(sharedCount))
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// A Git label is only meaningful for a clean checkout. Keep the
    /// independently checked build-input digest as the explicit fallback for
    /// dirty or non-Git projects; never present it as a commit revision.
    static func sourceRevision(sourceLocations: Set<URL>, buildInputsDigest: String) -> String {
        let fallback = "inputs-sha256:\(buildInputsDigest)"
        guard let first = sourceLocations.first else { return fallback }
        var firstIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &firstIsDirectory) else {
            return fallback
        }
        let gitDirectory = firstIsDirectory.boolValue ? first.path : first.deletingLastPathComponent().path
        func git(in directory: String, _ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let root = git(in: gitDirectory,
                             ["rev-parse", "--show-toplevel"]), !root.isEmpty,
              sourceLocations.allSatisfy({ location in
                  let path = location.standardizedFileURL.resolvingSymlinksInPath().path
                  let canonicalRoot = URL(filePath: root).resolvingSymlinksInPath().path
                  return path == canonicalRoot || path.hasPrefix(canonicalRoot + "/")
              }),
              let status = git(in: root, ["status", "--porcelain", "--untracked-files=all"]),
              status.isEmpty,
              let trackedOutput = git(in: root, ["ls-files", "-z", "--cached", "--full-name"]),
              !trackedOutput.isEmpty,
              let revision = git(in: root, ["rev-parse", "HEAD"]),
              revision.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            return fallback
        }
        let canonicalRoot = URL(filePath: root).resolvingSymlinksInPath().path
        let tracked = Set(trackedOutput.split(separator: "\0").map(String.init))
        for location in sourceLocations {
            let path = location.standardizedFileURL.resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return fallback
            }
            if !isDirectory.boolValue, !tracked.contains(String(path.dropFirst(canonicalRoot.count + 1))) {
                return fallback
            }
        }
        return "git:\(revision)"
    }

    /// Ask SwiftPM for evaluated membership: manifest syntax and target layout
    /// are executable Swift and cannot be reliably inferred from folder names.
    static func localPackageDeveloperDirectory(xcodebuildPath: String) -> String? {
        let executable = URL(filePath: xcodebuildPath).resolvingSymlinksInPath()
        let bin = executable.deletingLastPathComponent()
        let usr = bin.deletingLastPathComponent()
        let developer = usr.deletingLastPathComponent()
        guard executable.lastPathComponent == "xcodebuild", bin.lastPathComponent == "bin",
              usr.lastPathComponent == "usr", developer.lastPathComponent == "Developer" else { return nil }
        return developer.path
    }

    private static func localPackageBuildInputs(
        at root: URL, xcodebuildPath: String, fileManager: FileManager
    ) throws -> Set<URL> {
        let scratch = fileManager.temporaryDirectory.appending(path: "intent-lab-package-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        var inputs = Set<URL>()
        var visited = Set<String>()

        func metadata(_ command: [String], package: URL) throws -> [String: Any] {
            let output = scratch.appending(path: "metadata.json")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["swift", "package", "--disable-automatic-resolution", "--package-path", package.path,
                                 "--scratch-path", scratch.appending(path: "build").path,
                                 "--cache-path", scratch.appending(path: "cache").path,
                                 "--config-path", scratch.appending(path: "config").path,
                                 "--security-path", scratch.appending(path: "security").path] + command
            var environment = ProcessInfo.processInfo.environment
            environment["CLANG_MODULE_CACHE_PATH"] = scratch.appending(path: "module-cache").path
            if let developer = localPackageDeveloperDirectory(xcodebuildPath: xcodebuildPath) {
                environment["DEVELOPER_DIR"] = developer
            }
            process.environment = environment
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 30) == .success else {
                process.terminate()
                throw XcodeTestExecutorError.resourceMismatch(
                    "SwiftPM could not resolve local package build inputs within the connection-check deadline."
                )
            }
            let size = (try fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            guard process.terminationStatus == 0, size <= 8 * 1_024 * 1_024,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any] else {
                throw XcodeTestExecutorError.resourceMismatch(
                    "SwiftPM could not resolve local package build inputs. Check the package and selected developer tools."
                )
            }
            return value
        }

        func visit(_ package: URL) throws {
            let package = URL(filePath: package.standardizedFileURL.resolvingSymlinksInPath().path,
                              directoryHint: .isDirectory)
            guard visited.insert(package.path).inserted else { return }
            let description = try metadata(["describe", "--type", "json"], package: package)
            let manifest = try metadata(["dump-package"], package: package)
            guard let targets = description["targets"] as? [[String: Any]],
                  let declarations = manifest["targets"] as? [[String: Any]],
                  let dependencies = description["dependencies"] as? [[String: Any]] else {
                throw XcodeTestExecutorError.resourceMismatch("SwiftPM returned unsupported local package membership metadata.")
            }
            for entry in try fileManager.contentsOfDirectory(at: package, includingPropertiesForKeys: nil) {
                let name = entry.lastPathComponent
                if name == "Package.swift" || name == "Package.resolved"
                    || (name.hasPrefix("Package@swift-") && entry.pathExtension == "swift") {
                    inputs.insert(entry)
                }
            }
            for target in targets {
                guard let name = target["name"] as? String,
                      let declaration = declarations.first(where: { $0["name"] as? String == name }) else {
                    throw XcodeTestExecutorError.resourceMismatch("SwiftPM returned incomplete target membership metadata.")
                }
                if declaration["type"] as? String == "binary" {
                    // Remote artifacts are pinned by the checksum in Package.swift;
                    // local artifacts must include their actual packaged bytes.
                    if let path = declaration["path"] as? String {
                        inputs.insert(URL(filePath: path, relativeTo: package).standardizedFileURL)
                    }
                    continue
                }
                guard let path = target["path"] as? String,
                      let sources = target["sources"] as? [String] else {
                    throw XcodeTestExecutorError.resourceMismatch("SwiftPM returned unsupported target source membership.")
                }
                let targetRoot = URL(filePath: path, directoryHint: .isDirectory,
                                     relativeTo: package).standardizedFileURL
                for source in sources {
                    inputs.insert(URL(filePath: source, relativeTo: targetRoot).standardizedFileURL)
                }
                for resource in target["resources"] as? [[String: Any]] ?? [] {
                    guard let path = resource["path"] as? String else {
                        throw XcodeTestExecutorError.resourceMismatch("SwiftPM returned an unresolved package resource.")
                    }
                    inputs.insert(URL(filePath: path, relativeTo: targetRoot).standardizedFileURL)
                }
                // SwiftPM's source list omits Clang headers and module maps.
                // Honor its evaluated excludes while including those build inputs.
                if target["module_type"] as? String == "ClangTarget"
                    || target["module_type"] as? String == "SystemLibraryTarget" {
                    let excluded = (declaration["exclude"] as? [String] ?? []).map {
                        URL(filePath: $0, relativeTo: targetRoot).standardizedFileURL.path
                    }
                    var enumerationError: Error?
                    guard let enumerator = fileManager.enumerator(at: targetRoot,
                        includingPropertiesForKeys: [.isDirectoryKey], errorHandler: { _, error in
                            enumerationError = error
                            return false
                        }) else {
                        throw XcodeTestExecutorError.resourceMismatch("Local package headers could not be inspected.")
                    }
                    for case let file as URL in enumerator {
                        let path = file.standardizedFileURL.path
                        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                            enumerator.skipDescendants()
                            continue
                        }
                        if ["h", "hh", "hpp", "hxx", "inc", "modulemap"].contains(file.pathExtension.lowercased()) {
                            inputs.insert(file)
                        }
                    }
                    if let enumerationError { throw enumerationError }
                }
            }
            for dependency in dependencies where dependency["type"] as? String == "fileSystem" {
                guard let path = dependency["path"] as? String else {
                    throw XcodeTestExecutorError.resourceMismatch("SwiftPM returned an unresolved local package dependency.")
                }
                try visit(URL(filePath: path, relativeTo: package).standardizedFileURL)
            }
        }
        try visit(root)
        return inputs
    }

    private static func hashProjectSources(
        projects: [URL], container: URL, xcodebuildPath: String, into hasher: inout SHA256,
        fileManager: FileManager
    ) throws -> Set<URL> {
        let ignoredSourceTrees: Set<String> = ["SDKROOT", "BUILT_PRODUCTS_DIR", "DEVELOPER_DIR"]
        var files: [String: URL] = [:]
        var sourceLocations = Set(projects)
        for project in projects {
            let projectFile = project.appending(path: "project.pbxproj")
            guard let data = try? Data(contentsOf: projectFile),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let objects = plist["objects"] as? [String: [String: Any]],
                  let projectObject = objects.values.first(where: { $0["isa"] as? String == "PBXProject" }),
                  let mainGroupID = projectObject["mainGroup"] as? String,
                  objects[mainGroupID] != nil else {
                throw XcodeTestExecutorError.resourceMismatch(
                    "The selected project has unsupported or unreadable source membership metadata."
                )
            }
            let projectRoot = project.deletingLastPathComponent().standardizedFileURL
            let projectLabel = Self.relativePath(of: project, from: container.deletingLastPathComponent())
            let prefix = "source/\(projectLabel)"
            var visitedGroups: Set<String> = []
            var visitedDirectories: Set<String> = []
            var buildPhaseFileReferences: Set<String> = []
            for phase in objects.values where (phase["isa"] as? String)?.hasSuffix("BuildPhase") == true {
                for buildFileID in phase["files"] as? [String] ?? [] {
                    guard let buildFile = objects[buildFileID] else { continue }
                    if let reference = buildFile["fileRef"] as? String {
                        buildPhaseFileReferences.insert(reference)
                    }
                }
            }

            func resolvedPath(
                _ object: [String: Any], inheritedBase: URL, isGroup: Bool
            ) throws -> URL? {
                let sourceTree = object["sourceTree"] as? String ?? "<group>"
                if ignoredSourceTrees.contains(sourceTree) { return nil }
                // Groups with no path are logical navigator containers. Their
                // display names (including localized variant names) do not add
                // a filesystem component to their children's paths.
                let path = (object["path"] as? String)
                    ?? (isGroup ? nil : object["name"] as? String)
                let base: URL
                switch sourceTree {
                case "<group>": base = inheritedBase
                case "SOURCE_ROOT": base = projectRoot
                case "<absolute>":
                    guard let path else { return nil }
                    return URL(filePath: path, directoryHint: isGroup ? .isDirectory : .inferFromPath).standardizedFileURL
                default:
                    if isGroup || path != nil {
                        throw XcodeTestExecutorError.resourceMismatch(
                            "The selected project uses an unsupported source tree for a local source."
                        )
                    }
                    return nil
                }
                guard let path, !path.isEmpty else { return base }
                let result = URL(filePath: path, directoryHint: isGroup ? .isDirectory : .inferFromPath,
                                 relativeTo: base).standardizedFileURL
                return result
            }

            func addFile(_ file: URL, labelPrefix: String, includeDirectory: Bool = true) throws {
                guard fileManager.fileExists(atPath: file.path) else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "A referenced project source could not be found."
                    )
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "A referenced project source could not be inspected."
                    )
                }
                if isDirectory.boolValue {
                    // A directory shown in the navigator is not necessarily a
                    // build input. Folder references are resources only when a
                    // build phase actually consumes them.
                    guard includeDirectory else { return }
                    try collectDirectory(file, labelPrefix: labelPrefix)
                } else {
                    files["\(labelPrefix)/\(Self.relativePath(of: file, from: projectRoot))"] = file
                    sourceLocations.insert(file.resolvingSymlinksInPath())
                    guard files.count <= 100_000 else {
                        throw XcodeTestExecutorError.resourceMismatch(
                            "The selected project has too many source and resource files to fingerprint."
                        )
                    }
                }
            }

            func collectDirectory(_ directory: URL, labelPrefix: String) throws {
                let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
                guard visitedDirectories.insert(resolvedDirectory.path).inserted else { return }
                sourceLocations.insert(resolvedDirectory)
                let entries = try fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
                )
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
                    if isDirectory.boolValue {
                        // This directory is already an explicit build input.
                        // Names such as build or DerivedData can be legitimate
                        // nested resources and must not hide consumed content.
                        try collectDirectory(entry, labelPrefix: labelPrefix)
                    } else {
                        files["\(labelPrefix)/\(Self.relativePath(of: entry, from: projectRoot))"] = entry
                        sourceLocations.insert(entry.resolvingSymlinksInPath())
                        guard files.count <= 100_000 else {
                            throw XcodeTestExecutorError.resourceMismatch(
                                "The selected project has too many source and resource files to fingerprint."
                            )
                        }
                    }
                }
            }

            func visitGroup(_ id: String, inheritedBase: URL) throws {
                guard visitedGroups.insert(id).inserted else { return }
                guard let object = objects[id], let kind = object["isa"] as? String else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The selected project has incomplete source membership metadata."
                    )
                }
                let groupKinds: Set<String> = ["PBXGroup", "PBXVariantGroup"]
                guard groupKinds.contains(kind) else {
                    if kind == "PBXFileReference" {
                        guard let path = try resolvedPath(object, inheritedBase: inheritedBase, isGroup: false) else { return }
                        try addFile(
                            path, labelPrefix: prefix,
                            includeDirectory: buildPhaseFileReferences.contains(id)
                        )
                        return
                    }
                    if kind == "PBXFileSystemSynchronizedRootGroup" {
                        guard let path = try resolvedPath(object, inheritedBase: inheritedBase, isGroup: true) else { return }
                        try addFile(path, labelPrefix: prefix)
                        return
                    }
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The selected project has unsupported source membership metadata."
                    )
                }
                guard let groupURL = try resolvedPath(object, inheritedBase: inheritedBase, isGroup: true) else { return }
                let children = object["children"] as? [String] ?? []
                for child in children { try visitGroup(child, inheritedBase: groupURL) }
            }

            try visitGroup(mainGroupID, inheritedBase: projectRoot)

            // Xcode 16 synchronized groups are often attached directly to targets
            // rather than to the navigator's main group.
            let synchronizedGroupIDs = Set(objects.values
                .filter { $0["isa"] as? String == "PBXNativeTarget" }
                .flatMap { $0["fileSystemSynchronizedGroups"] as? [String] ?? [] })
            for id in synchronizedGroupIDs where !visitedGroups.contains(id) {
                try visitGroup(id, inheritedBase: projectRoot)
            }

            // Build phases may consume references that are not displayed in
            // the navigator. Resolve root/absolute references directly; an
            // orphaned group-relative reference has no trustworthy base.
            for id in buildPhaseFileReferences where !visitedGroups.contains(id) {
                guard let object = objects[id] else {
                    throw XcodeTestExecutorError.resourceMismatch("A build phase references missing source membership metadata.")
                }
                let tree = object["sourceTree"] as? String ?? "<group>"
                guard tree == "SOURCE_ROOT" || tree == "<absolute>" || ignoredSourceTrees.contains(tree) else {
                    throw XcodeTestExecutorError.resourceMismatch("A build phase source has no resolvable owning group.")
                }
                try visitGroup(id, inheritedBase: projectRoot)
            }

            for object in objects.values where object["isa"] as? String == "XCLocalSwiftPackageReference" {
                guard let relativePath = object["relativePath"] as? String,
                      !relativePath.isEmpty else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The selected project has a local package reference with no resolvable path."
                    )
                }
                let packageRoot = URL(filePath: relativePath, relativeTo: projectRoot).standardizedFileURL
                for input in try Self.localPackageBuildInputs(at: packageRoot, xcodebuildPath: xcodebuildPath, fileManager: fileManager) {
                    try addFile(input, labelPrefix: "\(prefix)/local-package")
                }
            }
        }
        var remainingContentBytes: Int64 = 256 * 1_024 * 1_024
        for (key, file) in files.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(key.utf8))
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            let size = attributes[.size] as? NSNumber ?? 0
            if size.int64Value <= 64 * 1_024 * 1_024,
               size.int64Value <= remainingContentBytes {
                hasher.update(data: try Data(contentsOf: file, options: [.mappedIfSafe]))
                remainingContentBytes -= size.int64Value
            } else {
                // Bound hashing for large trees while retaining a write-time change signal.
                hasher.update(data: Data("\(size):\(attributes[.modificationDate] ?? "unknown")".utf8))
            }
        }
        return sourceLocations
    }

    static func productMetadataDigest(products: XCTestRunProductPaths) -> String {
        var hasher = SHA256()
        for bundle in [products.appBundleURL, products.testHostURL, products.testBundleURL] {
            for name in ["Info.plist", "_CodeSignature/CodeResources", "embedded.mobileprovision"] {
                hasher.update(data: Data(name.utf8))
                if let data = try? Data(contentsOf: bundle.appending(path: name), options: [.mappedIfSafe]) {
                    hasher.update(data: data)
                } else {
                    hasher.update(data: Data("<missing>".utf8))
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func reusableRunProducts(
        connection: ScenarioVerifiedConnection,
        configuration: XcodeTestConfiguration,
        fileManager: FileManager = .default
    ) throws -> XCTestRunProductPaths {
        let paths = try XCTestRunInvocationTransport.resolveProducts(
            derivedData: connection.derivedDataURL,
            testTarget: configuration.testTarget,
            owningProjectURL: connection.selectedTestProjectURL,
            containerURL: URL(filePath: configuration.containerPath),
            fileManager: fileManager
        )
        guard paths.sourceURL == connection.testRunURL,
              paths.appBundleURL == connection.appBundleURL,
              paths.testHostURL == connection.testHostURL,
              paths.testBundleURL == connection.testBundleURL else {
            throw XcodeTestExecutorError.resourceMismatch(
                "The checked app or test runner no longer matches the selected Xcode products. Check the connection again."
            )
        }
        return paths
    }

    func runJournaledConnectionTest(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        methodName: String,
        derivedData: URL,
        resultBundle: URL,
        arguments: [String],
        logURL: URL,
        appendLog: Bool,
        deadline: Duration
    ) async throws -> Int32 {
        guard !connectionCancellationRequested else { throw XcodeTestExecutorError.cancelled }
        guard connectionTestJournal == nil,
              reservations[configuration.destinationIdentifier] == nil else {
            throw XcodeTestExecutorError.activeExecution
        }
        let id = UUID()
        var invocation = ScenarioInvocationIdentity(
            id: id, nonce: randomNonce(), issuedAt: Date(),
            testIdentity: .init(
                bundleIdentifier: configuration.testBundleIdentifier,
                className: "IntentLabScenarioTests", methodName: methodName
            ),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: configuration.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: resultBundle.lastPathComponent,
            appProduct: nil, testProduct: nil
        )
        invocation.integration = definition.integration
        var journal = ScenarioExecutionJournal(
            phase: .preparing, invocation: invocation,
            scenarioID: definition.id, scenarioVersion: definition.version,
            resultBundlePath: resultBundle.path, derivedDataPath: derivedData.path,
            buildLogPath: logURL.path, intendedExecutable: configuration.xcodebuildPath,
            intendedArguments: arguments, processIdentifier: nil,
            processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
        let destination = configuration.destinationIdentifier
        let reservation = ScenarioDeviceReservation.reserved(invocationID: id)
        connectionTestJournal = journal
        connectionDeviceTestLaunched = false
        reservations[destination] = reservation
        do {
            try await persistence.saveJournal(journal)
        } catch {
            connectionTestJournal = nil
            if reservations[destination] == reservation { reservations[destination] = nil }
            throw error
        }
        do {
            let code = try await runConnectionCommand(
                configuration: configuration, arguments: arguments, logURL: logURL,
                appendLog: appendLog, deadline: deadline
            )
            if connectionCancellationRequested { throw XcodeTestExecutorError.cancelled }
            journal = connectionTestJournal ?? journal
            journal.phase = .stopped
            journal.updatedAt = Date()
            try await persistence.saveJournal(journal)
            if connectionCancellationRequested { throw XcodeTestExecutorError.cancelled }
            connectionTestJournal = nil
            connectionDeviceTestLaunched = false
            if reservations[destination] == reservation { reservations[destination] = nil }
            return code
        } catch {
            journal = connectionTestJournal ?? journal
            let requiresRecovery = connectionDeviceTestLaunched
            journal.phase = requiresRecovery ? .recoveryRequired : .stopped
            journal.recoveryReason = requiresRecovery
                ? "The \(methodName) device test was interrupted; prove test termination and fixture readiness before using this destination."
                : nil
            journal.updatedAt = Date()
            if requiresRecovery {
                reservations[destination] = .quarantined(reason: journal.recoveryReason!)
            } else if reservations[destination] == reservation {
                reservations[destination] = nil
            }
            connectionTestJournal = nil
            connectionDeviceTestLaunched = false
            // The preparing journal was durable before launch; reconciliation
            // still quarantines the device if this final write fails.
            try? await persistence.saveJournal(journal)
            throw error
        }
    }

    private func runConnectionCommand(
        configuration: XcodeTestConfiguration,
        arguments: [String],
        logURL: URL,
        appendLog: Bool,
        deadline: Duration
    ) async throws -> Int32 {
        guard !connectionCancellationRequested else { throw XcodeTestExecutorError.cancelled }
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        if appendLog { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(filePath: configuration.xcodebuildPath)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        enum Outcome: Sendable { case exited(Int32), deadline }
        let (stream, continuation) = AsyncStream.makeStream(of: Outcome.self)
        process.terminationHandler = { terminated in
            continuation.yield(.exited(terminated.terminationStatus))
            continuation.finish()
        }
        try process.run()
        connectionProcess = process
        if var journal = connectionTestJournal {
            connectionDeviceTestLaunched = true
            journal.phase = .running
            journal.processIdentifier = process.processIdentifier
            journal.processStartedAt = Date()
            journal.updatedAt = Date()
            connectionTestJournal = journal
        }
        defer {
            if connectionProcess === process { connectionProcess = nil }
        }
        let timeout = Task { @concurrent in
            do {
                try await Task.sleep(for: deadline)
                continuation.yield(.deadline)
                continuation.finish()
            } catch { }
        }
        let outcome = await stream.first { _ in true }
        timeout.cancel()
        guard case .some(.exited(let code)) = outcome else {
            process.interrupt()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if connectionCancellationRequested || Task.isCancelled { throw XcodeTestExecutorError.cancelled }
            throw XcodeTestExecutorError.connectionCheck("Xcode timed out during the read-only setup check.")
        }
        if connectionCancellationRequested || Task.isCancelled { throw XcodeTestExecutorError.cancelled }
        return code
    }

    /// Cancels setup; a launched device test remains quarantined until manual recovery.
    func cancelConnectionCheck() async -> ScenarioConnectionCancellation {
        guard connectionCheckInProgress || connectionTestJournal != nil else { return .notRunning }
        connectionCancellationRequested = true
        if let connectionProcess, connectionProcess.isRunning {
            connectionProcess.terminate()
        }
        guard connectionDeviceTestLaunched, var journal = connectionTestJournal else {
            return .beforeDeviceTest
        }
        journal.phase = .recoveryRequired
        journal.recoveryReason = "The \(journal.invocation.testIdentity.methodName) device test was cancelled; prove test termination and fixture readiness before using this destination."
        journal.updatedAt = Date()
        connectionTestJournal = journal
        reservations[journal.invocation.destinationIdentifier] = .quarantined(
            reason: journal.recoveryReason!
        )
        // The preparing journal is already durable. If this write fails, launch
        // recovery will still find and quarantine that unfinished journal.
        try? await persistence.saveJournal(journal)
        return .recoveryRequired(journal)
    }

    func execute(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        linkedFeatureEvidenceAvailable: Bool = false,
        scope: ScenarioNativeExecutionScope? = nil,
        featureBackend: ScenarioFeatureBackend = .connectedRunner
    ) async throws -> ScenarioExecutorResult {
        try Task.checkCancellation()
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil,
              !connectionCheckInProgress else {
            throw XcodeTestExecutorError.activeExecution
        }
        let report = preflight(
            definition: definition,
            configuration: configuration,
            projectTrusted: projectTrusted,
            linkedFeatureEvidenceAvailable: linkedFeatureEvidenceAvailable,
            scope: scope,
            featureBackend: featureBackend
        )
        guard report.isReady else { throw XcodeTestExecutorError.preflight(report.checks) }
        let usesReusableProtocol = ScenarioHarnessCapabilities.usesReusableProtocol(definition)
        if usesReusableProtocol && definition.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            let routes = routeReadiness(
                definition: definition, configuration: configuration,
                projectTrusted: projectTrusted, featureBackend: featureBackend
            )
            let required: [ScenarioLane] = scope.map { [$0.lane] } ?? ScenarioLane.allCases.filter {
                definition.coverage[$0] == .required
                    && ($0 != .appFeature || featureBackend == .projectLocalTestControl)
            }
            let blocked = required.compactMap { lane -> ScenarioPreflightCheck? in
                guard let route = routes[lane], route.state != .ready else { return nil }
                return .init(id: "readiness.\(lane.rawValue)", title: "\(lane.title) runtime readiness",
                             state: .blocked, detail: route.detail)
            }
            guard blocked.isEmpty else { throw XcodeTestExecutorError.preflight(blocked) }
        }
        let selectedConnection = usesReusableProtocol
            ? currentConnection(definition: definition, configuration: configuration) : nil
        guard !usesReusableProtocol || selectedConnection != nil else {
            throw XcodeTestExecutorError.resourceMismatch(
                "The checked app or integration changed before the run. Check the connection again."
            )
        }

        let invocationID = UUID()
        let invocationDirectory = workDirectory.appending(path: invocationID.uuidString, directoryHint: .isDirectory)
        let derivedData = selectedConnection?.derivedDataURL
            ?? invocationDirectory.appending(path: "DerivedData", directoryHint: .isDirectory)
        let workspaceLease = try XcodeBuildWorkspaceLease(derivedData: derivedData, fileManager: fileManager)
        defer { withExtendedLifetime(workspaceLease) {} }
        removeInvocationTestRuns(derivedData: derivedData)
        let resultBundle = invocationDirectory.appending(path: "IntentLab.xcresult", directoryHint: .isDirectory)
        let attachments = invocationDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
        let buildLog = invocationDirectory.appending(path: "xcodebuild.log")
        try fileManager.createDirectory(at: invocationDirectory, withIntermediateDirectories: true)

        let testIdentity = ScenarioTestIdentity(
            bundleIdentifier: configuration.testBundleIdentifier,
            className: "IntentLabScenarioTests",
            methodName: "testIntentLabScenario"
        )
        var invocation = ScenarioInvocationIdentity(
            id: invocationID,
            nonce: randomNonce(),
            issuedAt: Date(),
            testIdentity: testIdentity,
            harnessVersion: ScenarioHarnessCapabilities.usesReusableProtocol(definition)
                ? ScenarioInvocationIdentity.reusableHarnessVersion
                : ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: configuration.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: resultBundle.lastPathComponent,
            appProduct: nil,
            testProduct: nil
        )
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition) {
            invocation.integration = definition.integration
            invocation.requiredCapabilities = ScenarioHarnessCapabilities.required(
                for: definition, scope: scope, featureBackend: featureBackend
            ).sorted()
        }
        if scope?.lane == .appFeature {
            invocation.featureBackend = featureBackend
        }
        let commonArguments = Self.xcodeArguments(
            configuration: configuration,
            derivedData: derivedData
        )
        var journal = ScenarioExecutionJournal(
            phase: .preparing,
            invocation: invocation,
            scenarioID: definition.id,
            scenarioVersion: definition.version,
            resultBundlePath: resultBundle.path,
            derivedDataPath: derivedData.path,
            buildLogPath: buildLog.path,
            intendedExecutable: configuration.xcodebuildPath,
            intendedArguments: commonArguments + ["test-without-building"],
            processIdentifier: nil,
            processStartedAt: nil,
            updatedAt: Date(),
            recoveryReason: nil,
            scope: scope
        )
        defer {
            inFlightJournal = nil
            if awaitingValidationJournal?.id != invocationID {
                cancelledInvocationIDs.remove(invocationID)
            }
        }
        try await persistPreparingJournal(journal)
        var deviceTestLaunched = false
        var invocationTestRunURL: URL?
        defer {
            if let invocationTestRunURL {
                try? fileManager.removeItem(at: invocationTestRunURL)
            }
        }

        do {
            let productPaths: XCTestRunProductPaths
            if let selectedConnection {
                guard let connection = currentConnection(definition: definition, configuration: configuration),
                      connection.testRunURL == selectedConnection.testRunURL else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The checked app, test runner, or integration declaration changed. Check the connection again."
                    )
                }
                productPaths = try Self.reusableRunProducts(
                    connection: connection, configuration: configuration, fileManager: fileManager
                )
            } else {
                let buildExit = try await runProcess(
                    executable: configuration.xcodebuildPath,
                    arguments: commonArguments + ["build-for-testing"],
                    logURL: buildLog,
                    invocationID: invocationID,
                    destinationIdentifier: configuration.destinationIdentifier,
                    journal: journal,
                    appendLog: false,
                    deadline: .seconds(900)
                )
                try throwIfCancelled(invocationID)
                guard buildExit == 0 else {
                    journal.phase = .stopped
                    journal.updatedAt = Date()
                    try await persistence.saveJournal(journal)
                    reservations[configuration.destinationIdentifier] = nil
                    throw XcodeTestExecutorError.buildFailed(buildExit, tail(of: buildLog))
                }
                productPaths = try XCTestRunInvocationTransport.resolveProducts(
                    derivedData: derivedData,
                    testTarget: configuration.testTarget,
                    fileManager: fileManager
                )
            }
            try throwIfCancelled(invocationID)
            let products = try verifyBuiltProducts(
                definition: definition,
                configuration: configuration,
                paths: productPaths
            )
            let measurement = definition.schemaVersion == ScenarioDefinition.stableSchemaVersion
                ? Self.measurementImplementation(testProduct: products.test)
                : nil
            if ScenarioHarnessCapabilities.usesReusableProtocol(definition) {
                guard let connection = currentConnection(definition: definition, configuration: configuration),
                      connection.appProduct == products.app,
                      connection.testProduct == products.test,
                      (try? Self.productIdentity(
                          bundle: productPaths.testHostURL,
                          fallbackBundleIdentifier: configuration.testBundleIdentifier
                      )) == connection.testHostProduct,
                      connection.productMetadataDigest == Self.productMetadataDigest(products: productPaths) else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The built app, test runner, or integration declaration changed after the connection check. Check the connection again."
                    )
                }
            }
            var boundInvocation = invocation
            boundInvocation.appProduct = products.app
            boundInvocation.testProduct = products.test
            let buildEnvironment = Self.executionBuildEnvironment(
                testBundleURL: productPaths.testBundleURL,
                destinationPlatform: configuration.destinationPlatform
            )
            if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
               buildEnvironment == nil {
                throw XcodeTestExecutorError.resourceMismatch(
                    "The built test product does not identify its selected Xcode and destination SDK. Rebuild the connection with a supported Xcode project."
                )
            }
            let materializedTestRunURL = try XCTestRunInvocationTransport.materialize(
                products: productPaths,
                testTarget: configuration.testTarget,
                definition: definition,
                invocation: boundInvocation,
                scope: scope,
                featureBackend: featureBackend,
                buildEnvironment: buildEnvironment ?? [:],
                fileManager: fileManager
            )
            invocationTestRunURL = materializedTestRunURL
            journal.invocation = boundInvocation
            journal.phase = .running
            journal.updatedAt = Date()
            inFlightJournal = journal
            try await persistence.saveJournal(journal)

            let testArguments = Self.testExecutionArguments(
                configuration: configuration, testRunURL: materializedTestRunURL,
                resultBundleURL: resultBundle,
                testIdentifier: "\(testIdentity.className)/\(testIdentity.methodName)"
            )
            journal.intendedArguments = testArguments
            journal.updatedAt = Date()
            inFlightJournal = journal
            try await persistence.saveJournal(journal)
            deviceTestLaunched = true
            let testDeadline = Duration.seconds(XcodeTestDeadlineBudget.seconds(for: definition, scope: scope))
            let testExit = try await runProcess(
                executable: configuration.xcodebuildPath,
                arguments: testArguments,
                logURL: buildLog,
                invocationID: invocationID,
                destinationIdentifier: configuration.destinationIdentifier,
                journal: journal,
                appendLog: true,
                deadline: testDeadline
            )
            if testExit != 0 {
                invalidateRuntimeReadiness(
                    lane: scope?.lane,
                    reason: "The selected route's driver reported a failed test execution. Check its retained result bundle before retrying."
                )
            }
            guard !cancelledInvocationIDs.contains(invocationID) else {
                throw XcodeTestExecutorError.cancelled
            }

            // Keep the persisted journal running until the host validates the evidence.
            journal.phase = .stopped
            journal.updatedAt = Date()
            let evidenceAttachments = try exportAttachments(
                configuration: configuration,
                resultBundle: resultBundle,
                outputDirectory: attachments,
                invocationID: invocationID
            )
            let testCount = resultBundleTestCount(configuration: configuration, resultBundle: resultBundle)
            guard !evidenceAttachments.isEmpty else { throw XcodeTestExecutorError.evidenceMissing }
            guard !cancelledInvocationIDs.contains(invocationID) else {
                throw XcodeTestExecutorError.cancelled
            }
            active = nil
            awaitingValidationJournal = journal
            return .init(
                journal: journal,
                resultBundleURL: resultBundle,
                attachmentDirectory: attachments,
                evidenceAttachments: evidenceAttachments,
                reportedTestCount: testCount,
                processExitCode: testExit,
                testFailureMessages: resultBundleFailureMessages(configuration: configuration, resultBundle: resultBundle),
                measurementImplementation: measurement
            )
        } catch {
            if deviceTestLaunched {
                invalidateRuntimeReadiness(
                    lane: scope?.lane,
                    reason: "The selected route's driver did not complete cleanly: \(error.localizedDescription)"
                )
            }
            active = nil
            let failure = cancelledInvocationIDs.contains(invocationID)
                ? ScenarioRecoveryFailure.cancellation : recoveryFailure(for: error)
            if ScenarioExecutionRecoveryPolicy.requiresQuarantine(
                deviceTestLaunched: deviceTestLaunched,
                failure: failure
            ) || failure == .cancellation {
                journal.phase = .recoveryRequired
                journal.recoveryReason = ScenarioExecutionRecoveryPolicy.reason(for: failure)
                reservations[configuration.destinationIdentifier] = .quarantined(
                    reason: journal.recoveryReason ?? "Device recovery is required."
                )
            } else if journal.phase != .recoveryRequired {
                journal.phase = .stopped
                reservations[configuration.destinationIdentifier] = nil
            }
            journal.updatedAt = Date()
            try? await persistence.saveJournal(journal)
            throw error
        }
    }

    func cancelActiveExecution(grace: Duration = .seconds(5)) async -> ScenarioExecutionJournal? {
        guard var journal = active?.journal ?? inFlightJournal ?? awaitingValidationJournal else { return nil }
        let invocationID = journal.id
        let destination = journal.invocation.destinationIdentifier
        cancelledInvocationIDs.insert(invocationID)
        journal.phase = .recoveryRequired
        journal.recoveryReason = "Cancellation was requested; confirm device-side termination and fixture readiness."
        journal.evidenceAccepted = false
        journal.updatedAt = Date()
        if inFlightJournal?.id == invocationID { inFlightJournal = journal }
        if awaitingValidationJournal?.id == invocationID { awaitingValidationJournal = journal }
        reservations[destination] = .quarantined(reason: journal.recoveryReason!)
        if let process = active?.process, active?.invocationID == invocationID {
            process.interrupt()
            try? await Task.sleep(for: grace)
            if process.isRunning { process.terminate() }
        }
        try? await persistence.saveJournal(journal)
        return journal
    }

    private func throwIfCancelled(_ invocationID: UUID) throws {
        if Task.isCancelled || cancelledInvocationIDs.contains(invocationID) {
            throw XcodeTestExecutorError.cancelled
        }
    }

    private func availableDestination(
        _ identifier: String,
        requiresSiri: Bool = false
    ) -> (ready: Bool, detail: String, platform: IntentLabDestinationPlatform?) {
        let requested = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return (false, "Choose an available Mac, iOS Simulator, or paired physical iPhone.", nil)
        }
        let devices: [IntentLabDeviceDestination]
        do {
            devices = try XcodeConnectionDiscoveryService().discoverDevices()
        } catch {
            return (false, "Xcode device discovery failed: \(error.localizedDescription)", nil)
        }
        return Self.destinationStatus(identifier: requested, devices: devices, requiresSiri: requiresSiri)
    }

    static func testExecutionArguments(
        configuration: XcodeTestConfiguration, testRunURL: URL,
        resultBundleURL: URL, testIdentifier: String
    ) -> [String] {
        // Keep failed captures bounded. Xcode's verbose sysdiagnose collection
        // can stall finalization after XCTest has already reported its failure.
        // The result bundle and execution log still retain the test evidence.
        [
            "test-without-building", "-xctestrun", testRunURL.path,
            "-destination", "id=\(configuration.destinationIdentifier)",
            "-resultBundlePath", resultBundleURL.path,
            "-collect-test-diagnostics", "never",
            "-only-testing:\(configuration.testTarget)/\(testIdentifier)",
        ] + configuration.signingArguments
    }

    static func destinationStatus(
        identifier: String,
        devices: [IntentLabDeviceDestination],
        requiresSiri: Bool = false
    ) -> (ready: Bool, detail: String, platform: IntentLabDestinationPlatform?) {
        guard let device = devices.first(where: { $0.identifier == identifier }) else {
            return (false, "Xcode did not report the selected destination as available.", nil)
        }
        guard device.available else {
            return (false, "\(device.name) is unavailable in Xcode.", device.platform)
        }
        guard !requiresSiri || device.platform == .iOS else {
            return (false, "Siri checks require an available physical iPhone; select one before checking the connection or running this test.", device.platform)
        }
        if requiresSiri {
            let version = device.operatingSystemVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version,
                  version.range(of: #"^[0-9]+(?:\.[0-9]+){0,2}(?: \([A-Za-z0-9]+\))?$"#, options: .regularExpression) != nil,
                  let majorText = version.split(whereSeparator: { $0 == "." || $0 == " " }).first,
                  let major = Int(majorText), major >= 27 else {
                return (false, "Siri checks require a physical iPhone with iOS 27 or later reported by Xcode. Refresh destinations and select a supported version before running this test.", device.platform)
            }
        }
        let detail: String
        switch device.platform {
        case .macOS: detail = "\(device.name) is available as the local Mac test destination."
        case .iOSSimulator: detail = "\(device.name) is available as an iOS Simulator test destination."
        case .iOS: detail = "\(device.name) is reported by Xcode as an available physical iPhone."
        }
        return (true, detail, device.platform)
    }

    static func signingReady(
        configuration: XcodeTestConfiguration,
        destinationPlatform: IntentLabDestinationPlatform?,
        reusableConnectionVerified: Bool
    ) -> Bool {
        if configuration.destinationPlatform == .iOSSimulator {
            return destinationPlatform == .iOSSimulator && reusableConnectionVerified
        }
        return (configuration.applicationSigningConfigured == true
            && configuration.testSigningConfigured == true)
            || (destinationPlatform == .macOS && reusableConnectionVerified)
    }

    static func signingDestinationMatchesSelection(
        configuration: XcodeTestConfiguration,
        destinationPlatform: IntentLabDestinationPlatform?
    ) -> Bool {
        configuration.destinationPlatform != .iOSSimulator || destinationPlatform == .iOSSimulator
    }

    static func xcodeArguments(
        configuration: XcodeTestConfiguration,
        derivedData: URL
    ) -> [String] {
        [
            configuration.isWorkspace ? "-workspace" : "-project", configuration.containerPath,
            "-scheme", configuration.scheme,
            "-configuration", configuration.configuration,
            "-destination", "id=\(configuration.destinationIdentifier)",
            "-derivedDataPath", derivedData.path
        ] + configuration.signingArguments
    }

    func runProcess(
        executable: String,
        arguments: [String],
        logURL: URL,
        invocationID: UUID,
        destinationIdentifier: String,
        journal: ScenarioExecutionJournal,
        appendLog: Bool,
        deadline: Duration? = nil,
        onProcessLaunched: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> Int32 {
        try throwIfCancelled(invocationID)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        if appendLog { try logHandle.seekToEnd() } else { try logHandle.truncate(atOffset: 0) }
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        enum ProcessOutcome: Sendable {
            case exited(Int32)
            case deadline
        }
        let (outcomes, continuation) = AsyncStream.makeStream(of: ProcessOutcome.self)
        process.terminationHandler = { terminated in
            continuation.yield(.exited(terminated.terminationStatus))
            continuation.finish()
        }
        var runningJournal = journal
        runningJournal.processStartedAt = Date()
        do {
            try process.run()
        } catch {
            continuation.finish()
            throw XcodeTestExecutorError.processLaunch(error.localizedDescription)
        }
        runningJournal.processIdentifier = process.processIdentifier
        onProcessLaunched?(process.processIdentifier)
        runningJournal.updatedAt = Date()
        active = .init(
            invocationID: invocationID,
            destinationIdentifier: destinationIdentifier,
            process: process,
            journal: runningJournal
        )
        defer {
            if active?.invocationID == invocationID,
               active?.process === process {
                active = nil
            }
        }
        do {
            try await persistence.saveJournal(runningJournal)
        } catch {
            // A launched child must be stopped before the executor can release its
            // active-process tracking, even when the journal write itself failed.
            process.interrupt()
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        let timeoutTask = deadline.map { deadline in
            Task { @concurrent in
                do {
                    try await Task.sleep(for: deadline)
                    continuation.yield(.deadline)
                    continuation.finish()
                } catch { }
            }
        }
        let outcome = await outcomes.first { _ in true }
        timeoutTask?.cancel()
        guard case .some(.exited(let code)) = outcome else {
            process.interrupt()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw XcodeTestExecutorError.timedOut
        }
        if Task.isCancelled || cancelledInvocationIDs.contains(invocationID) {
            throw XcodeTestExecutorError.cancelled
        }
        return code
    }

    private func recoveryFailure(for error: Error) -> ScenarioRecoveryFailure {
        switch error {
        case XcodeTestExecutorError.buildFailed:
            .buildFailure
        case XcodeTestExecutorError.cancelled:
            .cancellation
        case XcodeTestExecutorError.timedOut:
            .timeout
        case XcodeTestExecutorError.evidenceMissing:
            .incompleteResultBundle
        case XcodeTestExecutorError.resourceMismatch,
             XcodeTestExecutorError.productMissing:
            .invalidEvidence
        default:
            .unexpected
        }
    }

    private func verifyBuiltProducts(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        paths: XCTestRunProductPaths
    ) throws -> (app: ScenarioProductIdentity, test: ScenarioProductIdentity) {
        guard fileManager.fileExists(atPath: paths.appBundleURL.path),
              bundleIdentifier(at: paths.appBundleURL) == definition.target.bundleIdentifier else {
            throw XcodeTestExecutorError.productMissing("no built app has bundle ID \(definition.target.bundleIdentifier)")
        }
        guard fileManager.fileExists(atPath: paths.testBundleURL.path) else {
            throw XcodeTestExecutorError.productMissing("the \(configuration.testTarget) test bundle was not built")
        }
        if ScenarioHarnessCapabilities.usesReusableProtocol(definition),
           bundleIdentifier(at: paths.testBundleURL) != configuration.testBundleIdentifier {
            throw XcodeTestExecutorError.productMissing(
                "the built UI-test bundle does not match the selected target's bundle identifier"
            )
        }
        return (
            try Self.productIdentity(bundle: paths.appBundleURL, fallbackBundleIdentifier: definition.target.bundleIdentifier),
            try Self.productIdentity(bundle: paths.testBundleURL, fallbackBundleIdentifier: configuration.testBundleIdentifier)
        )
    }

    static func productIdentity(bundle: URL, fallbackBundleIdentifier: String) throws -> ScenarioProductIdentity {
        let info = NSDictionary(contentsOf: bundle.appending(path: "Info.plist")) as? [String: Any]
        let executableName = info?["CFBundleExecutable"] as? String ?? bundle.deletingPathExtension().lastPathComponent
        let executable = bundle.appending(path: executableName)
        guard let data = try? Data(contentsOf: executable, options: [.mappedIfSafe]) else {
            throw XcodeTestExecutorError.productMissing("could not fingerprint \(bundle.lastPathComponent)")
        }
        return .init(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String ?? fallbackBundleIdentifier,
            executableName: executableName,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    /// Deliberately conservative: unrelated UI-test code changes also change
    /// the observer identity. The digest never comes from declaration labels.
    static func measurementImplementation(
        testProduct: ScenarioProductIdentity,
        hostBundle: Bundle = .main
    ) -> ScenarioMeasurementImplementation? {
        guard hostBundle.bundleIdentifier == "com.coryparry.FoundationEvals",
              let hostExecutable = hostBundle.executableURL,
              let bytes = try? Data(contentsOf: hostExecutable, options: [.mappedIfSafe]),
              !bytes.isEmpty,
              !testProduct.sha256.isEmpty else { return nil }
        let hostDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(
            observerID: "ui-test-executable:\(testProduct.bundleIdentifier):\(testProduct.executableName)",
            observerDigest: testProduct.sha256,
            evaluatorID: "host-executable:com.coryparry.FoundationEvals:\(hostExecutable.lastPathComponent)",
            evaluatorDigest: hostDigest
        )
    }

    private func bundleIdentifier(at bundle: URL) -> String? {
        (NSDictionary(contentsOf: bundle.appending(path: "Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    private func exportAttachments(
        configuration: XcodeTestConfiguration,
        resultBundle: URL,
        outputDirectory: URL,
        invocationID: UUID
    ) throws -> [ScenarioEvidenceAttachment] {
        if fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.removeItem(at: outputDirectory)
        }
        let process = Process()
        process.executableURL = URL(filePath: configuration.xcresulttoolPath)
        process.arguments = [
            "xcresulttool", "export", "attachments",
            "--path", resultBundle.path,
            "--output-path", outputDirectory.path,
            "--filter", "*IntentLab*"
        ]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self)
            throw XcodeTestExecutorError.resourceMismatch("xcresulttool could not export attachments: \(detail)")
        }
        let manifest = try Data(contentsOf: outputDirectory.appending(path: "manifest.json"))
        try Self.restoreArtifactFilenames(in: manifest, root: outputDirectory)
        return Self.evidenceAttachments(in: manifest, root: outputDirectory, invocationID: invocationID)
    }

    static func restoreArtifactFilenames(in manifest: Data, root: URL) throws {
        let entries = try JSONSerialization.jsonObject(with: manifest) as? [[String: Any]] ?? []
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var restored: Set<String> = []
        for entry in entries where entry["testIdentifier"] as? String == "IntentLabScenarioTests/testIntentLabScenario()" {
            for item in entry["attachments"] as? [[String: Any]] ?? [] {
                guard let name = item["suggestedHumanReadableName"] as? String,
                      name.hasPrefix("IntentLabArtifact-"),
                      let id = UUID(uuidString: String(name.dropFirst("IntentLabArtifact-".count).prefix(36))),
                      let filename = item["exportedFileName"] as? String,
                      filename == URL(filePath: filename).lastPathComponent,
                      filename.hasSuffix(".png") else { continue }
                let source = root.appending(path: filename).resolvingSymlinksInPath()
                guard source.deletingLastPathComponent() == root else {
                    throw XcodeTestExecutorError.resourceMismatch("An exported artifact escapes the attachment directory.")
                }
                let canonicalName = "IntentLabArtifact-\(id.uuidString).png"
                guard restored.insert(canonicalName).inserted else {
                    throw XcodeTestExecutorError.resourceMismatch("Duplicate exported artifact identity.")
                }
                let destination = root.appending(path: canonicalName)
                if source != destination {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }
        }
    }

    static func evidenceAttachments(in manifest: Data, root: URL, invocationID: UUID) -> [ScenarioEvidenceAttachment] {
        guard let entries = (try? JSONSerialization.jsonObject(with: manifest)) as? [[String: Any]] else { return [] }
        let prefix = "IntentLabEvidence-\(invocationID.uuidString)"
        let attachments = entries
            .filter { $0["testIdentifier"] as? String == "IntentLabScenarioTests/testIntentLabScenario()" }
            .flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
            .compactMap { item -> ScenarioEvidenceAttachment? in
                guard let filename = item["exportedFileName"] as? String,
                      let name = item["suggestedHumanReadableName"] as? String,
                      name.hasPrefix(prefix),
                      filename == URL(filePath: filename).lastPathComponent,
                      filename.hasSuffix(".json") else { return nil }
                let url = root.appending(path: filename)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return .init(url: url, name: name)
            }
        let finals = attachments.filter { !$0.isCheckpoint }
        return finals.isEmpty ? attachments : finals
    }

    private func resultBundleFailureMessages(configuration: XcodeTestConfiguration, resultBundle: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: configuration.xcresulttoolPath)
        process.arguments = ["xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path, "--compact"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: output) else {
            return []
        }
        return Self.failureMessages(in: object)
    }

    static func failureMessages(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            let message = dictionary["nodeType"] as? String == "Failure Message"
                ? dictionary["name"] as? String : nil
            return (message.map { [String($0.prefix(500))] } ?? [])
                + dictionary.values.flatMap { failureMessages(in: $0) }
        }
        if let array = object as? [Any] {
            return array.flatMap { failureMessages(in: $0) }
        }
        return []
    }

    private func resultBundleTestCount(configuration: XcodeTestConfiguration, resultBundle: URL) -> Int? {
        let process = Process()
        process.executableURL = URL(filePath: configuration.xcresulttoolPath)
        process.arguments = ["xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path, "--compact"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: output) else {
            return nil
        }
        return findInteger(keys: ["totalTestCount", "testsCount", "testCount"], in: object)
    }

    private func findInteger(keys: Set<String>, in object: Any) -> Int? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keys.contains(key) {
                if let number = value as? NSNumber { return number.intValue }
            }
            for value in dictionary.values {
                if let found = findInteger(keys: keys, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findInteger(keys: keys, in: value) { return found }
            }
        }
        return nil
    }

    private func tail(of url: URL, maximumBytes: Int = 8_000) -> String {
        guard let data = try? Data(contentsOf: url) else { return "See the retained build log." }
        return String(decoding: data.suffix(maximumBytes), as: UTF8.self)
            .split(separator: "\n").suffix(20).joined(separator: "\n")
    }

    private func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
