import CryptoKit
import Darwin
import Foundation

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
        let directLaneSeconds = includesDirectLane ? scenarioWaitSeconds : 0
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
    private var inFlightJournal: ScenarioExecutionJournal?
    private var awaitingValidationJournal: ScenarioExecutionJournal?
    private var reservations: [String: ScenarioDeviceReservation] = [:]
    private var clearingDestinations: Set<String> = []
    private var cancelledInvocationIDs: Set<UUID> = []

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
        var canAccept = accepted && !cancelledInvocationIDs.contains(journal.id)
        finished.phase = canAccept ? .stopped : .recoveryRequired
        finished.recoveryReason = canAccept ? nil : ScenarioExecutionRecoveryPolicy.reason(for: .invalidEvidence)
        finished.evidenceAccepted = canAccept
        finished.updatedAt = Date()
        if !canAccept {
            reservations[destination] = .quarantined(reason: finished.recoveryReason!)
        }
        try await persistence.saveJournal(finished)
        // Cancellation can arrive while the journal write is suspended.
        if canAccept && cancelledInvocationIDs.contains(journal.id) {
            canAccept = false
            finished.phase = .recoveryRequired
            finished.recoveryReason = ScenarioExecutionRecoveryPolicy.reason(for: .cancellation)
            finished.evidenceAccepted = false
            finished.updatedAt = Date()
            reservations[destination] = .quarantined(reason: finished.recoveryReason!)
            try await persistence.saveJournal(finished)
        }
        if canAccept { reservations[destination] = nil }
        if awaitingValidationJournal?.id == journal.id { awaitingValidationJournal = nil }
        cancelledInvocationIDs.remove(journal.id)
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
        active != nil || inFlightJournal != nil
    }

    func persistPreparingJournal(_ journal: ScenarioExecutionJournal) async throws {
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
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil else {
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
        check("testBundleIdentifier", "Test bundle identity",
              configuration.testBundleIdentifier.contains("."),
              "Enter the UI-test bundle identifier used by the signed test runner.")
        let discoveredCapabilities = Set(configuration.harnessCapabilities ?? [])
        check(
            "harness",
            "Intent Lab harness",
            configuration.harnessVersion == ScenarioInvocationIdentity.currentHarnessVersion,
            "Add INTENT_LAB_HARNESS_VERSION=\(ScenarioInvocationIdentity.currentHarnessVersion) to the UI-test target, then include IntentLabScenarioTests/testIntentLabScenario."
        )
        check("signing", "Device signing",
              configuration.applicationSigningConfigured == true && configuration.testSigningConfigured == true,
              "Select a development team for both the app and UI-test targets in Xcode Signing & Capabilities.")
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
        let destination = physicalDestination(configuration.destinationIdentifier)
        check("destination", "Physical destination", destination.ready, destination.detail)

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

    func execute(
        definition: ScenarioDefinition,
        configuration: XcodeTestConfiguration,
        projectTrusted: Bool,
        linkedFeatureEvidenceAvailable: Bool = false
    ) async throws -> ScenarioExecutorResult {
        try Task.checkCancellation()
        guard active == nil, inFlightJournal == nil, awaitingValidationJournal == nil else {
            throw XcodeTestExecutorError.activeExecution
        }
        let report = preflight(
            definition: definition,
            configuration: configuration,
            projectTrusted: projectTrusted,
            linkedFeatureEvidenceAvailable: linkedFeatureEvidenceAvailable
        )
        guard report.isReady else { throw XcodeTestExecutorError.preflight(report.checks) }

        let invocationID = UUID()
        let invocationDirectory = workDirectory.appending(path: invocationID.uuidString, directoryHint: .isDirectory)
        let derivedData = invocationDirectory.appending(path: "DerivedData", directoryHint: .isDirectory)
        let resultBundle = invocationDirectory.appending(path: "IntentLab.xcresult", directoryHint: .isDirectory)
        let attachments = invocationDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
        let buildLog = invocationDirectory.appending(path: "xcodebuild.log")
        try fileManager.createDirectory(at: invocationDirectory, withIntermediateDirectories: true)

        let testIdentity = ScenarioTestIdentity(
            bundleIdentifier: configuration.testBundleIdentifier,
            className: "IntentLabScenarioTests",
            methodName: "testIntentLabScenario"
        )
        let invocation = ScenarioInvocationIdentity(
            id: invocationID,
            nonce: randomNonce(),
            issuedAt: Date(),
            testIdentity: testIdentity,
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: configuration.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: resultBundle.lastPathComponent,
            appProduct: nil,
            testProduct: nil
        )
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

            let productPaths = try XCTestRunInvocationTransport.resolveProducts(
                derivedData: derivedData,
                testTarget: configuration.testTarget,
                fileManager: fileManager
            )
            let products = try verifyBuiltProducts(
                definition: definition,
                configuration: configuration,
                paths: productPaths
            )
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
            inFlightJournal = journal
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
            inFlightJournal = journal
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
            awaitingValidationJournal = journal
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

    private func physicalDestination(_ identifier: String) -> (ready: Bool, detail: String) {
        let requested = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return (false, "Choose an enrolled physical iPhone destination identifier.")
        }
        let devices: [IntentLabDeviceDestination]
        do {
            devices = try XcodeConnectionDiscoveryService().discoverDevices()
        } catch {
            return (false, "Xcode device discovery failed: \(error.localizedDescription)")
        }
        guard let device = devices.first(where: { $0.identifier == requested }) else {
            return (false, "Xcode did not report the selected identifier as an available device.")
        }
        guard device.available else {
            return (false, "\(device.name) is not an available paired physical iPhone.")
        }
        return (true, "\(device.name) is reported by Xcode as an available physical iPhone.")
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
