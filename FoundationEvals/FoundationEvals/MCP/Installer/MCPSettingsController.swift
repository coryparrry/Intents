import AppKit
import Foundation
import Observation

struct MCPServerControl: Sendable {
    let start: @MainActor @Sendable (CodexMCPConfiguration) async throws -> Void
    let stop: @MainActor @Sendable () async throws -> Void

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

@MainActor
@Observable
final class MCPSettingsController {
    private static let legacyPortKey = "mcp.server.port"
    private static let legacyBookmarkKey = "mcp.codex.configuration-directory-bookmark"

    private let serverControl: MCPServerControl
    private let installer: CodexMCPInstaller
    private let userDefaults: UserDefaults
    private var needsFixedPortMigration: Bool

    private(set) var serverState: MCPConnectorServerState = .stopped
    private(set) var installationState: CodexMCPInstallationState = .notConfigured
    private(set) var lastConnection: Date?
    private(set) var isBusy = false
    var notice: String?

    init(
        serverControl: MCPServerControl,
        userDefaults: UserDefaults = .standard,
        installer: CodexMCPInstaller = CodexMCPInstaller()
    ) {
        self.serverControl = serverControl
        self.userDefaults = userDefaults
        self.installer = installer
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

    func startServer() async {
        guard !isBusy, serverState != .running else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let configuration = try currentConfiguration()
            try await startServer(using: configuration)
            notice = nil
        } catch {
            notice = safeDescription(for: error)
        }
    }

    func installOrUpdateCodex() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
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
            case .installed: "Foundation Evals is ready. Restart Codex to connect."
            case .updated: "The Codex connection was updated. Restart Codex to reconnect."
            case .unchanged: "Foundation Evals is ready. Restart Codex if it does not appear."
            case .removed: nil
            }
            do {
                try await startServer(using: configuration)
                notice = successNotice
            } catch {
                notice = "Codex was configured, but the local connector could not start. " + safeDescription(for: error)
            }
        } catch {
            installationState = .needsAttention
            notice = safeDescription(for: error) + " You can copy the manual configuration instead."
        }
    }

    func removeFromCodex() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let receipt = try installer.remove(from: codexConfigurationDirectory)
            needsFixedPortMigration = false
            userDefaults.removeObject(forKey: Self.legacyPortKey)
            installationState = .notConfigured
            notice = receipt.change == .removed
                ? "Foundation Evals was removed from Codex. Restart Codex to apply the change."
                : "No managed Foundation Evals entry was present."
        } catch {
            installationState = .needsAttention
            notice = safeDescription(for: error)
        }
    }

    func copyEndpoint() {
        copyToPasteboard(endpoint.absoluteString)
        notice = "MCP endpoint copied."
    }

    func copyManualConfiguration() async {
        do {
            copyToPasteboard(try currentConfiguration().manualSnippet)
            notice = "Codex configuration copied."
        } catch {
            notice = safeDescription(for: error)
        }
    }

    func recordConnection(at date: Date = .now) {
        lastConnection = date
    }

    func recordServerFailure(_ error: MCPServerError) {
        guard serverState == .starting || serverState == .running else { return }
        serverState = .failed
        notice = safeDescription(for: error)
    }

    func refreshInstallationState() {
        do {
            let detectedState: CodexMCPInstallationState = try installer.isInstalled(
                in: codexConfigurationDirectory
            ) ? .installed : .notConfigured
            installationState = needsFixedPortMigration && detectedState == .installed
                ? .needsAttention
                : detectedState
        } catch {
            installationState = .needsAttention
        }
    }

    private func currentConfiguration() throws -> CodexMCPConfiguration {
        try CodexMCPConfiguration(port: CodexMCPConfiguration.defaultPort)
    }

    private func startServer(using configuration: CodexMCPConfiguration) async throws {
        guard serverState != .running else { return }
        serverState = .starting
        do {
            try await serverControl.start(configuration)
            serverState = .running
        } catch {
            serverState = .failed
            throw error
        }
    }

    private var codexConfigurationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func safeDescription(for error: Error) -> String {
        switch error {
        case let error as CodexMCPInstallerError:
            error.localizedDescription
        case let error as MCPServerError:
            error.localizedDescription
        default:
            "The MCP configuration could not be changed safely."
        }
    }
}
