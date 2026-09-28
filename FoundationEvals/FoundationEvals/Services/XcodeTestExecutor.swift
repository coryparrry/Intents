import CryptoKit
import Foundation

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
    var generatedResourceDirectory: String
    var harnessVersion: String? = nil
    var harnessCapabilities: [String]? = nil
    var applicationSigningConfigured: Bool? = nil
    var testSigningConfigured: Bool? = nil
    var configuration: String = "Debug"
    var xcodebuildPath: String = "/usr/bin/xcodebuild"
    var xcresulttoolPath: String = "/usr/bin/xcrun"
    /// Project path plus Xcode target ID from discovery. Absent in legacy saved setup.
    var selectedTestProductID: String? = nil
    var selectedApplicationProductID: String? = nil
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
    var testProduct: ScenarioProductIdentity
    var appBundleURL: URL
    var testBundleURL: URL
    var testRunURL: URL
    var selectedTestProjectURL: URL
    var buildInputsDigest: String
    var productMetadataDigest: String
}

enum ScenarioHarnessCapabilities {
    static func required(for definition: ScenarioDefinition) -> Set<String> {
        guard definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion else {
            return ["environment-payload", "fixture-reset", "invocation-correlation", "accessible-result", "direct-intent-output"]
        }
        var capabilities: Set<String> = ["environment-payload", "direct-intent-execution"]
        if !definition.directControl.outputFields.isEmpty { capabilities.insert("direct-intent-output") }
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
            case .intentResult: capabilities.insert("direct-intent-output")
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
    static func seconds(for definition: ScenarioDefinition) -> Double {
        let scenarioWaitSeconds = definition.safety.deadlineSeconds
        let includesDirectLane = definition.coverage.intentIntegration != .notApplicable
        let siriAttemptCount = definition.coverage.siri == .notApplicable
            ? 0
            : (definition.coverage.siriAttemptCount ?? 3)
        let fixtureCount = (includesDirectLane ? 1 : 0) + siriAttemptCount
        // Baseline observation, direct intent execution, and post-intent
        // observation each have their own bounded wait in the device runner.
        let directLaneSeconds = includesDirectLane ? 3 * scenarioWaitSeconds : 0
        let siriSeconds = Double(siriAttemptCount) * (siriActivationWaitSeconds + scenarioWaitSeconds)
        let fixtureSeconds = Double(fixtureCount) * fixtureStartupAndInspectionSeconds

        return xcodeStartupAndFinalizationSeconds + fixtureSeconds + directLaneSeconds + siriSeconds
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
    private var reservations: [String: ScenarioDeviceReservation] = [:]
    private var clearingDestinations: Set<String> = []
    private var cancelledInvocationIDs: Set<UUID> = []
    private var connectionCheckInProgress = false
    private var verifiedConnection: ScenarioVerifiedConnection?

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

    func finishEvidenceValidation(journal: ScenarioExecutionJournal, accepted: Bool) async throws {
        var finished = journal
        let destination = journal.invocation.destinationIdentifier
        finished.phase = accepted ? .stopped : .recoveryRequired
        finished.recoveryReason = accepted ? nil : ScenarioExecutionRecoveryPolicy.reason(for: .invalidEvidence)
        finished.updatedAt = Date()
        if !accepted {
            reservations[destination] = .quarantined(reason: finished.recoveryReason!)
        }
        try await persistence.saveJournal(finished)
        if accepted { reservations[destination] = nil }
    }

    private func removeInvocationTestRuns(derivedDataPath: String) {
        let products = URL(filePath: derivedDataPath).appending(path: "Build/Products", directoryHint: .isDirectory)
        guard let files = try? fileManager.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("IntentLab-") && file.pathExtension == "xctestrun" {
            try? fileManager.removeItem(at: file)
        }
    }

    func reservation(for destinationIdentifier: String) -> ScenarioDeviceReservation? {
        reservations[destinationIdentifier]
    }

    func hasActiveExecution() -> Bool {
        active != nil
    }

    func persistPreparingJournal(_ journal: ScenarioExecutionJournal) async throws {
        // A malformed prior journal may describe an unresolved device attempt.
        // Do not reserve or launch another attempt until recovery can read every record.
        _ = try await persistence.loadJournals()
        let destination = journal.invocation.destinationIdentifier
        let reservation = ScenarioDeviceReservation.reserved(invocationID: journal.id)
        reservations[destination] = reservation
        do {
            try await persistence.saveJournal(journal)
        } catch {
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
        guard active == nil else {
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
        guard active == nil, reservations[destinationIdentifier] == reservation else {
            throw XcodeTestExecutorError.deviceUnavailable("Device recovery state changed while clearing quarantine.")
        }
        reservations[destinationIdentifier] = nil
    }

    func preflight(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        linkedFeatureEvidenceAvailable: Bool = false
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
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            check("testProductIdentity", "UI-test project and target", configuration.selectedTestProductID != nil,
                  "Choose the owning project and UI-test target; a target name alone is ambiguous in a workspace.")
            check("appProductIdentity", "Application project and target", configuration.selectedApplicationProductID != nil,
                  "Choose the owning project and application target; a bundle ID alone can be ambiguous in a workspace.")
        }
        check("testBundleIdentifier", "Test bundle identity",
              configuration.testBundleIdentifier.contains("."),
              "Enter the UI-test bundle identifier used by the signed test runner.")
        let discoveredCapabilities = Set(configuration.harnessCapabilities ?? [])
        let isReusable = definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
        let expectedHarnessVersion = isReusable
            ? ScenarioInvocationIdentity.reusableHarnessVersion
            : ScenarioInvocationIdentity.currentHarnessVersion
        let connection = isReusable ? currentConnection(definition: definition, configuration: configuration) : nil
        check(
            "harness",
            "Intent Lab harness",
            isReusable ? connection != nil : configuration.harnessVersion == expectedHarnessVersion,
            isReusable
                ? "Build and run IntentLabScenarioTests/testIntentLabConnection to verify the \(expectedHarnessVersion) consumer and selected products."
                : "Add INTENT_LAB_HARNESS_VERSION=\(expectedHarnessVersion) to the UI-test target, then include IntentLabScenarioTests/testIntentLabScenario."
        )
        let destination = physicalDestination(
            configuration.destinationIdentifier,
            requiresSiri: definition.coverage.siri != .notApplicable
        )
        let macConnectionVerified = isReusable && destination.platform == .macOS && connection != nil
        check("signing", "Signing and test execution",
              Self.signingReady(
                  configuration: configuration,
                  destinationPlatform: destination.platform,
                  reusableConnectionVerified: isReusable && connection != nil
              ),
              macConnectionVerified
                  ? "The selected Mac app and UI-test target completed the connection test."
                  : "Select a development team for both targets, or complete the Mac connection test to verify local test execution.")
        if isReusable {
            for capability in ScenarioHarnessCapabilities.required(for: definition).sorted() {
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

        let definitionIssues = ScenarioValidator.issues(in: definition, requireFrozenDigest: true)
        let definitionReady = !definitionIssues.contains { $0.severity == .error }
        check("definition", "Frozen scenario", definitionReady,
              definitionReady ? "The scenario digest and deterministic values are valid."
                  : definitionIssues.filter { $0.severity == .error }.map(\.message).joined(separator: " "))
        check(
            "featureLane",
            "App feature evidence",
            definition.coverage.appFeature != .required || linkedFeatureEvidenceAvailable,
            definition.coverage.appFeature == .required && !linkedFeatureEvidenceAvailable
                ? "Link a saved production feature run before executing this required lane."
                : "The device harness will preserve the declared Intent and Siri lane requirements."
        )

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

    /// A separate, read-only setup run. Its receipt never becomes scenario evidence.
    func verifyConnection(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool
    ) async throws -> ScenarioVerifiedConnection {
        guard definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion else {
            throw XcodeTestExecutorError.connectionCheck("A version 2 integration is required.")
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
        guard active == nil, !connectionCheckInProgress else { throw XcodeTestExecutorError.activeExecution }
        guard fileManager.fileExists(atPath: configuration.containerPath),
              fileManager.isExecutableFile(atPath: configuration.xcodebuildPath),
              !configuration.scheme.isEmpty, !configuration.testTarget.isEmpty else {
            throw XcodeTestExecutorError.connectionCheck("Choose a buildable Xcode project, scheme, and UI-test target.")
        }
        let discovered = try XcodeConnectionDiscoveryService(
            xcodebuildPath: configuration.xcodebuildPath,
            xcdevicePath: configuration.xcresulttoolPath
        ).discoverProject(container: URL(filePath: configuration.containerPath), configuration: configuration.configuration)
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

        connectionCheckInProgress = true
        verifiedConnection = nil
        defer { connectionCheckInProgress = false }
        let checkID = UUID()
        let directory = workDirectory.appending(path: "Connection-\(checkID.uuidString)", directoryHint: .isDirectory)
        let derivedData = directory.appending(path: "DerivedData", directoryHint: .isDirectory)
        let resultBundle = directory.appending(path: "Connection.xcresult", directoryHint: .isDirectory)
        let log = directory.appending(path: "xcodebuild.log")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let buildExit = try await runConnectionCommand(
            configuration: configuration,
            arguments: xcodeArguments(configuration: configuration, derivedData: derivedData) + ["build-for-testing"],
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
        let testExit = try await runConnectionCommand(
            configuration: configuration,
            arguments: [
                "test-without-building", "-xctestrun", paths.sourceURL.path,
                "-destination", "id=\(configuration.destinationIdentifier)",
                "-resultBundlePath", resultBundle.path,
                "-only-testing:\(configuration.testTarget)/IntentLabScenarioTests/testIntentLabConnection",
            ],
            logURL: log,
            appendLog: true,
            deadline: .seconds(180)
        )
        guard testExit == 0, resultBundleTestCount(configuration: configuration, resultBundle: resultBundle) == 1 else {
            throw XcodeTestExecutorError.connectionCheck(
                "The fixed connection test did not complete once (exit \(testExit)). \(tail(of: log))"
            )
        }
        let attachments = directory.appending(path: "Attachments", directoryHint: .isDirectory)
        _ = try exportAttachments(
            configuration: configuration, resultBundle: resultBundle,
            outputDirectory: attachments, invocationID: checkID
        )
        let receipt = try Self.connectionReceipt(in: attachments)
        let verified = ScenarioVerifiedConnection(
            receipt: receipt, configuration: configuration,
            appProduct: products.app, testProduct: products.test,
            appBundleURL: paths.appBundleURL, testBundleURL: paths.testBundleURL,
            testRunURL: paths.sourceURL,
            selectedTestProjectURL: URL(filePath: owningProjectPath),
            buildInputsDigest: try Self.buildInputsDigest(configuration: configuration, products: paths),
            productMetadataDigest: Self.productMetadataDigest(products: paths)
        )
        guard connectionMatches(verified, definition: definition, configuration: configuration) else {
            throw XcodeTestExecutorError.connectionCheck(
                "The compiled declaration, capabilities, or app/test identity did not match the selected integration."
            )
        }
        verifiedConnection = verified
        return verified
    }

    private func currentConnection(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration
    ) -> ScenarioVerifiedConnection? {
        guard let verifiedConnection,
              connectionMatches(verifiedConnection, definition: definition, configuration: configuration) else {
            return nil
        }
        return verifiedConnection
    }

    private func connectionMatches(
        _ connection: ScenarioVerifiedConnection,
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration
    ) -> Bool {
        let receipt = connection.receipt
        guard connection.configuration == configuration,
              receipt.schemaVersion == 1,
              Self.receiptMatchesSelection(
                  receipt, configuration: configuration,
                  selectedProjectURL: connection.selectedTestProjectURL
              ),
              receipt.integration == definition.integration,
              receipt.targetBundleIdentifier == definition.target.bundleIdentifier,
              receipt.testBundleIdentifier == connection.testProduct.bundleIdentifier,
              receipt.testBundleIdentifier == configuration.testBundleIdentifier,
              receipt.harnessProtocol == ScenarioInvocationIdentity.reusableHarnessVersion,
              !receipt.runnerPackageVersion.isEmpty,
              Set(receipt.capabilities).count == receipt.capabilities.count,
              ScenarioHarnessCapabilities.required(for: definition).isSubset(of: Set(receipt.capabilities)),
              let app = try? productIdentity(
                  bundle: connection.appBundleURL,
                  fallbackBundleIdentifier: definition.target.bundleIdentifier
              ),
              let test = try? productIdentity(
                  bundle: connection.testBundleURL,
                  fallbackBundleIdentifier: configuration.testBundleIdentifier
              ),
              app == connection.appProduct, test == connection.testProduct,
              connection.productMetadataDigest == Self.productMetadataDigest(products: .init(
                  sourceURL: connection.testRunURL,
                  appBundleURL: connection.appBundleURL,
                  testHostURL: connection.testBundleURL.deletingLastPathComponent(),
                  testBundleURL: connection.testBundleURL
              )),
              let inputs = try? Self.buildInputsDigest(
                  configuration: configuration,
                  products: .init(
                      sourceURL: connection.testRunURL,
                      appBundleURL: connection.appBundleURL,
                      testHostURL: connection.testBundleURL.deletingLastPathComponent(),
                      testBundleURL: connection.testBundleURL
                  )
              ),
              inputs == connection.buildInputsDigest,
              let declaration = try? Data(contentsOf: connection.testBundleURL.appending(path: "IntentLabIntegration.json")),
              SHA256.hash(data: declaration).map({ String(format: "%02x", $0) }).joined()
                == definition.integration?.digest else { return false }
        return true
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
        let container = URL(filePath: configuration.containerPath)
        var files = [
            products.sourceURL,
            products.appBundleURL.appending(path: "Info.plist"),
            products.appBundleURL.appending(path: "_CodeSignature/CodeResources"),
            products.appBundleURL.appending(path: "embedded.mobileprovision"),
            products.testBundleURL.appending(path: "Info.plist"),
            products.testBundleURL.appending(path: "_CodeSignature/CodeResources"),
            products.testBundleURL.appending(path: "embedded.mobileprovision"),
            container.appending(path: "contents.xcworkspacedata"),
            container.appending(path: "xcshareddata/swiftpm/Package.resolved"),
            container.deletingLastPathComponent().appending(path: "Package.resolved"),
        ]
        let projects = configuration.isWorkspace
            ? (try? XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: container)) ?? []
            : [container]
        for project in projects {
            files.append(project.appending(path: "project.pbxproj"))
            files.append(project.appending(path: "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        }
        for schemeContainer in (configuration.isWorkspace ? [container] + projects : projects) {
            let schemes = schemeContainer.appending(path: "xcshareddata/xcschemes", directoryHint: .isDirectory)
            if let entries = try? fileManager.contentsOfDirectory(at: schemes, includingPropertiesForKeys: nil) {
                files.append(contentsOf: entries.filter { $0.pathExtension == "xcscheme" })
            }
        }
        var hasher = SHA256()
        for file in Set(files).sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.standardizedFileURL.path.utf8))
            if let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) {
                hasher.update(data: data)
            } else {
                hasher.update(data: Data("<missing>".utf8))
            }
        }
        try hashProjectSources(projects: projects, into: &hasher, fileManager: fileManager)
        let toolPath = URL(filePath: configuration.xcodebuildPath).resolvingSymlinksInPath().path
        hasher.update(data: Data(toolPath.utf8))
        if let attributes = try? fileManager.attributesOfItem(atPath: toolPath) {
            let stamp = "\(attributes[.modificationDate] ?? "unknown"):\(attributes[.size] ?? "unknown")"
            hasher.update(data: Data(stamp.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashProjectSources(
        projects: [URL], into hasher: inout SHA256, fileManager: FileManager
    ) throws {
        let generatedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", "DerivedData",
            "node_modules", "xcuserdata"
        ]
        var roots = projects.map { $0.deletingLastPathComponent() }
        var referencedFiles: [URL] = []
        for project in projects {
            let projectFile = project.appending(path: "project.pbxproj")
            guard let data = try? Data(contentsOf: projectFile),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let objects = plist["objects"] as? [String: [String: Any]] else { continue }
            for object in objects.values where object["isa"] as? String == "XCLocalSwiftPackageReference" {
                guard let relativePath = object["relativePath"] as? String,
                      !relativePath.isEmpty else { continue }
                roots.append(URL(filePath: relativePath, relativeTo: project.deletingLastPathComponent()))
            }
            for object in objects.values {
                guard let path = object["path"] as? String,
                      path.hasPrefix("../") || path.hasPrefix("/"),
                      let kind = object["isa"] as? String,
                      kind == "PBXFileReference" || kind == "PBXGroup" || kind == "PBXVariantGroup" else {
                    continue
                }
                let reference = URL(filePath: path, relativeTo: project.deletingLastPathComponent())
                    .standardizedFileURL
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: reference.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue { roots.append(reference) }
                else { referencedFiles.append(reference) }
            }
        }
        var visitedDirectories: Set<String> = []
        var sourceFiles = Set(referencedFiles)
        while let directory = roots.popLast() {
            let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard visitedDirectories.insert(resolved.path).inserted else { continue }
            for entry in try fileManager.contentsOfDirectory(
                at: resolved, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
            ) {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    if !generatedDirectories.contains(entry.lastPathComponent),
                       entry.pathExtension != "xcresult" {
                        roots.append(entry)
                    }
                } else if values.isRegularFile == true {
                    sourceFiles.insert(entry.standardizedFileURL)
                    guard sourceFiles.count <= 100_000 else {
                        throw XcodeTestExecutorError.resourceMismatch(
                            "The selected project has too many source and resource files to fingerprint."
                        )
                    }
                }
            }
        }
        let sourceExtensions: Set<String> = [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "metal", "plist", "json",
            "xcconfig", "entitlements", "modulemap", "intentdefinition", "storyboard", "xib",
            "strings", "stringsdict", "xml", "yml", "yaml", "rb", "sh", "py", "js", "ts", "tsx", "jsx"
        ]
        var remainingContentBytes: Int64 = 256 * 1_024 * 1_024
        for file in sourceFiles.sorted(by: {
            let firstIsSource = sourceExtensions.contains($0.pathExtension.lowercased())
            let secondIsSource = sourceExtensions.contains($1.pathExtension.lowercased())
            return firstIsSource == secondIsSource ? $0.path < $1.path : firstIsSource
        }) {
            hasher.update(data: Data(file.path.utf8))
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
    }

    static func productMetadataDigest(products: XCTestRunProductPaths) -> String {
        var hasher = SHA256()
        for bundle in [products.appBundleURL, products.testBundleURL] {
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

    private func runConnectionCommand(
        configuration: XcodeTestConfiguration,
        arguments: [String],
        logURL: URL,
        appendLog: Bool,
        deadline: Duration
    ) async throws -> Int32 {
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
            throw XcodeTestExecutorError.connectionCheck("Xcode timed out during the read-only setup check.")
        }
        if Task.isCancelled { throw XcodeTestExecutorError.cancelled }
        return code
    }

    func execute(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        linkedFeatureEvidenceAvailable: Bool = false
    ) async throws -> ScenarioExecutorResult {
        guard active == nil, !connectionCheckInProgress else { throw XcodeTestExecutorError.activeExecution }
        let report = preflight(
            definition: definition,
            configuration: configuration,
            projectTrusted: projectTrusted,
            linkedFeatureEvidenceAvailable: linkedFeatureEvidenceAvailable
        )
        guard report.isReady else { throw XcodeTestExecutorError.preflight(report.checks) }
        let selectedConnection = definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
            ? currentConnection(definition: definition, configuration: configuration) : nil
        guard definition.schemaVersion != ScenarioDefinition.reusableSchemaVersion || selectedConnection != nil else {
            throw XcodeTestExecutorError.resourceMismatch(
                "The checked app or integration changed before the run. Check the connection again."
            )
        }

        let invocationID = UUID()
        let invocationDirectory = workDirectory.appending(path: invocationID.uuidString, directoryHint: .isDirectory)
        // Reusable checks run the exact products qualified by the connection test.
        // A second build in another DerivedData directory changes debug binaries and
        // generated App Intents metadata even when the source is unchanged.
        let derivedData = selectedConnection.map {
            $0.testRunURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        } ?? invocationDirectory.appending(path: "DerivedData", directoryHint: .isDirectory)
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
            harnessVersion: definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                ? ScenarioInvocationIdentity.reusableHarnessVersion
                : ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: configuration.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: resultBundle.lastPathComponent,
            appProduct: nil,
            testProduct: nil
        )
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            invocation.integration = definition.integration
            invocation.requiredCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        }
        let commonArguments = xcodeArguments(
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
            recoveryReason: nil
        )
        try await persistPreparingJournal(journal)
        var deviceTestLaunched = false
        var invocationTestRunURL: URL?
        defer {
            if let invocationTestRunURL {
                try? fileManager.removeItem(at: invocationTestRunURL)
            }
        }

        do {
            if selectedConnection == nil {
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
                guard buildExit == 0 else {
                    journal.phase = .stopped
                    journal.updatedAt = Date()
                    try await persistence.saveJournal(journal)
                    reservations[configuration.destinationIdentifier] = nil
                    throw XcodeTestExecutorError.buildFailed(buildExit, tail(of: buildLog))
                }
            }

            let productPaths = try XCTestRunInvocationTransport.resolveProducts(
                derivedData: derivedData,
                testTarget: configuration.testTarget,
                owningProjectURL: selectedConnection?.selectedTestProjectURL,
                containerURL: selectedConnection == nil ? nil : URL(filePath: configuration.containerPath),
                fileManager: fileManager
            )
            let products = try verifyBuiltProducts(
                definition: definition,
                configuration: configuration,
                paths: productPaths
            )
            if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                guard let connection = currentConnection(definition: definition, configuration: configuration),
                      productPaths.sourceURL == connection.testRunURL,
                      connection.appProduct == products.app,
                      connection.testProduct == products.test,
                      connection.productMetadataDigest == Self.productMetadataDigest(products: productPaths) else {
                    throw XcodeTestExecutorError.resourceMismatch(
                        "The built app, test runner, or integration declaration changed after the connection check. Check the connection again."
                    )
                }
            }
            var boundInvocation = invocation
            boundInvocation.appProduct = products.app
            boundInvocation.testProduct = products.test
            let materializedTestRunURL = try XCTestRunInvocationTransport.materialize(
                products: productPaths,
                testTarget: configuration.testTarget,
                definition: definition,
                invocation: boundInvocation,
                fileManager: fileManager
            )
            invocationTestRunURL = materializedTestRunURL
            journal.invocation = boundInvocation
            journal.phase = .running
            journal.updatedAt = Date()
            try await persistence.saveJournal(journal)

            let testArguments = [
                "test-without-building",
                "-xctestrun", materializedTestRunURL.path,
                "-destination", "id=\(configuration.destinationIdentifier)",
                "-resultBundlePath", resultBundle.path,
                "-only-testing:\(configuration.testTarget)/\(testIdentity.className)/\(testIdentity.methodName)",
            ]
            journal.intendedArguments = testArguments
            journal.updatedAt = Date()
            try await persistence.saveJournal(journal)
            deviceTestLaunched = true
            let testDeadline = Duration.seconds(XcodeTestDeadlineBudget.seconds(for: definition))
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
            return .init(
                journal: journal,
                resultBundleURL: resultBundle,
                attachmentDirectory: attachments,
                evidenceAttachments: evidenceAttachments,
                reportedTestCount: testCount,
                processExitCode: testExit,
                testFailureMessages: resultBundleFailureMessages(configuration: configuration, resultBundle: resultBundle)
            )
        } catch {
            active = nil
            cancelledInvocationIDs.remove(invocationID)
            let failure = recoveryFailure(for: error)
            if ScenarioExecutionRecoveryPolicy.requiresQuarantine(
                deviceTestLaunched: deviceTestLaunched,
                failure: failure
            ) {
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
        guard var execution = active else { return nil }
        cancelledInvocationIDs.insert(execution.invocationID)
        execution.journal.phase = .cancelling
        execution.journal.updatedAt = Date()
        active = execution
        try? await persistence.saveJournal(execution.journal)
        execution.process.interrupt()
        try? await Task.sleep(for: grace)
        if execution.process.isRunning { execution.process.terminate() }
        execution.journal.phase = .recoveryRequired
        execution.journal.recoveryReason = "Cancellation was requested; confirm device-side termination and fixture readiness."
        execution.journal.updatedAt = Date()
        try? await persistence.saveJournal(execution.journal)
        reservations[execution.destinationIdentifier] = .quarantined(
            reason: execution.journal.recoveryReason ?? "Device recovery is required."
        )
        return execution.journal
    }

    private func physicalDestination(
        _ identifier: String,
        requiresSiri: Bool
    ) -> (ready: Bool, detail: String, platform: IntentLabDestinationPlatform?) {
        let requested = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return (false, "Choose an available Mac or paired physical iPhone.", nil)
        }
        let devices: [IntentLabDeviceDestination]
        do {
            devices = try XcodeConnectionDiscoveryService().discoverDevices()
        } catch {
            return (false, "Xcode device discovery failed: \(error.localizedDescription)", nil)
        }
        return Self.destinationStatus(identifier: requested, devices: devices, requiresSiri: requiresSiri)
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
        let detail = device.platform == .macOS
            ? "\(device.name) is available as the local Mac test destination."
            : "\(device.name) is reported by Xcode as an available physical iPhone."
        return (true, detail, device.platform)
    }

    static func signingReady(
        configuration: XcodeTestConfiguration,
        destinationPlatform: IntentLabDestinationPlatform?,
        reusableConnectionVerified: Bool
    ) -> Bool {
        (configuration.applicationSigningConfigured == true
            && configuration.testSigningConfigured == true)
            || (destinationPlatform == .macOS && reusableConnectionVerified)
    }

    private func xcodeArguments(
        configuration: XcodeTestConfiguration,
        derivedData: URL
    ) -> [String] {
        [
            configuration.isWorkspace ? "-workspace" : "-project", configuration.containerPath,
            "-scheme", configuration.scheme,
            "-configuration", configuration.configuration,
            "-destination", "id=\(configuration.destinationIdentifier)",
            "-derivedDataPath", derivedData.path
        ]
    }

    func runProcess(
        executable: String,
        arguments: [String],
        logURL: URL,
        invocationID: UUID,
        destinationIdentifier: String,
        journal: ScenarioExecutionJournal,
        appendLog: Bool,
        deadline: Duration? = nil
    ) async throws -> Int32 {
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
        var runningJournal = journal
        runningJournal.processStartedAt = Date()
        do {
            try process.run()
        } catch {
            throw XcodeTestExecutorError.processLaunch(error.localizedDescription)
        }
        runningJournal.processIdentifier = process.processIdentifier
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
        try await persistence.saveJournal(runningJournal)
        enum ProcessOutcome: Sendable {
            case exited(Int32)
            case deadline
        }
        let (outcomes, continuation) = AsyncStream.makeStream(of: ProcessOutcome.self)
        process.terminationHandler = { terminated in
            continuation.yield(.exited(terminated.terminationStatus))
            continuation.finish()
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
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion,
           bundleIdentifier(at: paths.testBundleURL) != configuration.testBundleIdentifier {
            throw XcodeTestExecutorError.productMissing(
                "the built UI-test bundle does not match the selected target's bundle identifier"
            )
        }
        return (
            try productIdentity(bundle: paths.appBundleURL, fallbackBundleIdentifier: definition.target.bundleIdentifier),
            try productIdentity(bundle: paths.testBundleURL, fallbackBundleIdentifier: configuration.testBundleIdentifier)
        )
    }

    private func productIdentity(bundle: URL, fallbackBundleIdentifier: String) throws -> ScenarioProductIdentity {
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
