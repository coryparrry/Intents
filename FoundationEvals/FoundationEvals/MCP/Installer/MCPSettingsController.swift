import AppKit
import Foundation
import Observation

struct MCPServerControl: Sendable {
    let start: @MainActor @Sendable (CodexMCPConfiguration) async throws -> Void
    let stop: @MainActor @Sendable () async throws -> Void

    /// Wraps main-actor asynchronous server start and stop operations for the settings controller.
    init(
        start: @escaping @MainActor @Sendable (CodexMCPConfiguration) async throws -> Void,
        stop: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    static let disconnected = MCPServerControl(start: { _ in }, stop: {})
}

enum MCPConnectorServerState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .failed: "Needs attention"
        }
    }
}

enum CodexMCPInstallationState: Equatable, Sendable {
    case notConfigured
    case installed
    case needsAttention

    var label: String {
        switch self {
        case .notConfigured: "Not installed"
        case .installed: "Installed"
        case .needsAttention: "Needs attention"
        }
    }
}

enum MCPSettingsAccessError: LocalizedError {
    case missingExistingCredential
    case configurationReadOnly

    var errorDescription: String? {
        switch self {
        case .missingExistingCredential: "No existing local MCP credential is available; the isolated connector was not started."
        case .configurationReadOnly: "This isolated connector can use an existing credential only; Codex configuration changes are disabled."
        }
    }
}

@MainActor
@Observable
final class MCPSettingsController {
    private static let legacyPortKey = "mcp.server.port"
    private static let legacyBookmarkKey = "mcp.codex.configuration-directory-bookmark"

    @ObservationIgnored private let telemetry: TelemetryController?
    private let serverControl: MCPServerControl
    private let installer: CodexMCPInstaller
    private let credentialStore: MCPCredentialStore
    private let pasteboardWriter: @MainActor (String) -> Void
    private let userDefaults: UserDefaults
    private let existingCredentialOnly: Bool
    private let configurationDirectory: URL
    private var needsFixedPortMigration: Bool
    private var runningConfiguration: CodexMCPConfiguration?
    private var hasRecordedConnection = false

    private(set) var serverState: MCPConnectorServerState = .stopped
    private(set) var installationState: CodexMCPInstallationState = .notConfigured
    private(set) var lastConnection: Date?
    private(set) var isBusy = false
    var notice: String?

    /// Sets up connector dependencies and the Codex configuration directory, detects legacy-port
    /// migration, and refreshes installation state. Existing-credential-only mode skips preference
    /// migration and installation inspection. An injectable pasteboard writer keeps isolated tests
    /// from changing the general clipboard.
    init(
        serverControl: MCPServerControl,
        userDefaults: UserDefaults = .standard,
        installer: CodexMCPInstaller = CodexMCPInstaller(),
        credentialStore: MCPCredentialStore = .keychain,
        existingCredentialOnly: Bool = false,
        configurationDirectory: URL? = nil,
        pasteboardWriter: @escaping @MainActor (String) -> Void = { value in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        },
        telemetry: TelemetryController? = nil
    ) {
        self.telemetry = telemetry
        self.serverControl = serverControl
        self.userDefaults = userDefaults
        self.installer = installer
        self.credentialStore = credentialStore
        self.pasteboardWriter = pasteboardWriter
        self.existingCredentialOnly = existingCredentialOnly
        self.configurationDirectory = configurationDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
        if existingCredentialOnly {
            needsFixedPortMigration = false
            return
        }
        let legacyPort = userDefaults.integer(forKey: Self.legacyPortKey)
        needsFixedPortMigration = (1_024...65_535).contains(legacyPort)
            && legacyPort != CodexMCPConfiguration.defaultPort
        if !needsFixedPortMigration {
            userDefaults.removeObject(forKey: Self.legacyPortKey)
        }
        userDefaults.removeObject(forKey: Self.legacyBookmarkKey)
        refreshInstallationState()
    }

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(CodexMCPConfiguration.defaultPort)/mcp")!
    }

    /// Starts the connector with the current credential unless another settings action is busy. Records
    /// telemetry and exposes failures through notice instead of throwing.
    func startServer() async {
        guard !isBusy else { return }
        let diagnostic = telemetry?.begin(.mcpStart)
        var diagnosticFailure: TelemetryFailure?
        isBusy = true
        defer {
            isBusy = false
            telemetry?.end(diagnostic, failure: diagnosticFailure)
        }
        do {
            let configuration = try currentConfiguration()
            try await startServer(using: configuration)
            notice = nil
        } catch {
            diagnosticFailure = .classify(error)
            notice = safeDescription(for: error)
        }
    }

    /// Writes or updates the Codex entry, clears legacy-port migration state, then starts the
    /// connector. Reports configuration and startup outcomes separately; existing-credential-only mode
    /// refuses configuration changes.
    func installOrUpdateCodex() async {
        guard !existingCredentialOnly else { notice = MCPSettingsAccessError.configurationReadOnly.localizedDescription; return }
        guard !isBusy else { return }
        let diagnostic = telemetry?.begin(.mcpInstall)
        var diagnosticFailure: TelemetryFailure?
        isBusy = true
        defer {
            isBusy = false
            telemetry?.end(diagnostic, failure: diagnosticFailure)
        }
        do {
            let configuration = try currentConfiguration()
            let receipt = try installer.installOrUpdate(
                in: codexConfigurationDirectory,
                configuration: configuration
            )
            needsFixedPortMigration = false
            userDefaults.removeObject(forKey: Self.legacyPortKey)
            installationState = .installed
            let successNotice: String? = switch receipt.change {
            case .installed: "Intents is ready. Restart Codex to connect."
            case .updated: "The Codex connection was updated. Restart Codex to reconnect."
            case .unchanged: "Intents is ready. Restart Codex if it does not appear."
            case .removed: nil
            }
            do {
                try await startServer(using: configuration)
                notice = successNotice
            } catch {
            diagnosticFailure = .classify(error)
                notice = "Codex was configured, but the local connector could not start. " + safeDescription(for: error)
            }
        } catch {
            diagnosticFailure = .classify(error)
            installationState = .needsAttention
            notice = safeDescription(for: error) + " You can copy the manual configuration instead."
        }
    }

    /// Removes the managed Codex entry, stops the connector, and deletes its stored credential in that
    /// order. Marks intentional shutdown before awaiting it, restoring the previous state if shutdown
    /// fails. Updates notices on failure; existing-credential-only mode refuses removal.
    func removeFromCodex() async {
        guard !existingCredentialOnly else { notice = MCPSettingsAccessError.configurationReadOnly.localizedDescription; return }
        guard !isBusy else { return }
        let diagnostic = telemetry?.begin(.mcpStop)
        var diagnosticFailure: TelemetryFailure?
        isBusy = true
        defer {
            isBusy = false
            telemetry?.end(diagnostic, failure: diagnosticFailure)
        }
        do {
            let receipt = try installer.remove(from: codexConfigurationDirectory)
            let previousState = serverState
            serverState = .stopping
            do {
                try await serverControl.stop()
            } catch {
                serverState = previousState
                throw error
            }
            serverState = .stopped
            runningConfiguration = nil
            try credentialStore.remove()
            needsFixedPortMigration = false
            userDefaults.removeObject(forKey: Self.legacyPortKey)
            installationState = .notConfigured
            notice = receipt.change == .removed
                ? "Intents was removed from Codex. Restart Codex to apply the change."
                : "No managed Intents entry was present."
        } catch {
            diagnosticFailure = .classify(error)
            installationState = .needsAttention
            notice = safeDescription(for: error)
        }
    }

    /// Copies the fixed loopback endpoint to the general pasteboard and sets a confirmation notice.
    func copyEndpoint() {
        copyToPasteboard(endpoint.absoluteString)
        notice = "MCP endpoint copied."
    }

    /// Copies the credential-bearing manual TOML snippet and starts its connector without editing
    /// Codex configuration. Serializes settings actions and reports copied-but-failed startup
    /// separately; existing-credential-only mode refuses the action.
    func copyManualConfiguration() async {
        guard !existingCredentialOnly else { notice = MCPSettingsAccessError.configurationReadOnly.localizedDescription; return }
        guard !isBusy else { return }
        let diagnostic = telemetry?.begin(.mcpStart)
        var diagnosticFailure: TelemetryFailure?
        isBusy = true
        defer {
            isBusy = false
            telemetry?.end(diagnostic, failure: diagnosticFailure)
        }
        do {
            let configuration = try currentConfiguration()
            copyToPasteboard(configuration.manualSnippet)
            do {
                try await startServer(using: configuration)
                notice = "Codex configuration copied. The local connector is running. Add the configuration to your client, then reconnect."
            } catch {
                diagnosticFailure = .classify(error)
                notice = "Codex configuration copied, but the local connector could not start. " + safeDescription(for: error)
            }
        } catch {
            diagnosticFailure = .classify(error)
            notice = safeDescription(for: error)
        }
    }

    /// Records the latest authenticated, admitted request time and counts connector use once per
    /// listener run while usage sharing is enabled. An opted-out request does not consume the later
    /// consented event. Admission establishes contact, not successful initialization or tool execution.
    func recordConnection(at date: Date = .now) {
        guard serverState == .starting || serverState == .running else { return }
        lastConnection = date
        guard !hasRecordedConnection, let telemetry, telemetry.isEnabled, telemetry.isConfigured else { return }
        hasRecordedConnection = true
        telemetry.capture(.featureUsed(.mcpConnected))
    }

    /// Marks an active or starting connector as failed and clears its remembered configuration. Ignores
    /// deliberate stops and duplicate failures. Reports a running listener failure as a separate issue;
    /// startup failures remain owned by their existing operation span.
    func recordServerFailure(_ error: MCPServerError) {
        guard serverState == .starting || serverState == .running else { return }
        if serverState == .running {
            telemetry?.issue(.mcpStart, .classify(error))
        }
        serverState = .failed
        runningConfiguration = nil
        notice = safeDescription(for: error)
    }

    /// Reads the managed block, stored credential, and file permissions to classify installation state.
    /// Migration or inspection errors require attention; existing-credential-only mode skips
    /// inspection.
    func refreshInstallationState() {
        guard !existingCredentialOnly else { return }
        do {
            let detectedState: CodexMCPInstallationState
            if try installer.isInstalled(in: codexConfigurationDirectory) {
                if let credential = try credentialStore.load(),
                   let configuration = try? CodexMCPConfiguration(credential: credential),
                   try installer.isInstalled(in: codexConfigurationDirectory, matching: configuration) {
                    detectedState = .installed
                } else {
                    detectedState = .needsAttention
                }
            } else {
                detectedState = .notConfigured
            }
            installationState = needsFixedPortMigration && detectedState == .installed
                ? .needsAttention
                : detectedState
        } catch {
            installationState = .needsAttention
        }
    }

    /// Builds the fixed-port configuration using the existing credential or loading/creating one
    /// according to access mode. Throws when read-only startup has no credential or validation/storage
    /// fails.
    private func currentConfiguration() throws -> CodexMCPConfiguration {
        let credential: String
        if existingCredentialOnly {
            guard let existing = try credentialStore.load() else {
                throw MCPSettingsAccessError.missingExistingCredential
            }
            credential = existing
        } else {
            credential = try credentialStore.loadOrCreate()
        }
        return try CodexMCPConfiguration(port: CodexMCPConfiguration.defaultPort, credential: credential)
    }

    /// Reuses a running server with identical configuration or stops it before starting a changed
    /// configuration. Resets connection-use tracking only for a new listener, restores running state
    /// if stop fails, and records failed state if start throws.
    private func startServer(using configuration: CodexMCPConfiguration) async throws {
        if serverState == .running {
            guard runningConfiguration != configuration else { return }
            serverState = .stopping
            do {
                try await serverControl.stop()
            } catch {
                serverState = .running
                throw error
            }
            serverState = .stopped
            runningConfiguration = nil
        }
        hasRecordedConnection = false
        serverState = .starting
        do {
            try await serverControl.start(configuration)
            serverState = .running
            runningConfiguration = configuration
        } catch {
            serverState = .failed
            runningConfiguration = nil
            throw error
        }
    }

    private var codexConfigurationDirectory: URL {
        configurationDirectory
    }

    /// Sends plain text to the configured writer, which replaces the general pasteboard by default.
    private func copyToPasteboard(_ value: String) {
        pasteboardWriter(value)
    }

    /// Returns localized descriptions for recognized connector errors and a generic message for other
    /// failures, avoiding arbitrary error detail in settings notices.
    private func safeDescription(for error: Error) -> String {
        switch error {
        case let error as CodexMCPInstallerError:
            error.localizedDescription
        case let error as MCPServerError:
            error.localizedDescription
        case let error as MCPSettingsAccessError:
            error.localizedDescription
        case let error as MCPCredentialError:
            error.localizedDescription
        default:
            "The MCP configuration could not be changed safely."
        }
    }
}
