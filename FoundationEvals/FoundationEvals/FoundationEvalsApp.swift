import AppKit
import SwiftUI
import Sparkle

@main
@MainActor
struct FoundationEvalsApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(FoundationEvalsAppDelegate.self) private var appDelegate
    @State private var store: EvaluationStore
    @State private var runnerStore: DeveloperRunnerStore
    @State private var telemetry: TelemetryController
    @State private var mcpSettings: MCPSettingsController
    // Debug builds must retain the exact executable being tested.
    #if !DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !ProductionNativeWorkerCommand.isRequested, updaterDelegate: nil, userDriverDelegate: nil
    )
    #endif
    private let mcpRuntime: FoundationEvalsMCPRuntime

    init() {
        let telemetry = TelemetryController(configuration: Self.telemetryConfiguration)
        let storeDirectory: URL?
        do { storeDirectory = ProductionNativeWorkerCommand.isRequested ? try ProductionNativeWorkerCommand.prepareScratch() : Self.acceptanceStorageDirectory }
        catch { FileHandle.standardError.write(Data(("Native eval worker: \(error.localizedDescription)\n").utf8)); ProductionNativeWorkerCommand.finish(30) }
        let store = EvaluationStore(supportDirectory: storeDirectory)
        let runtime = FoundationEvalsMCPRuntime(store: store)
        let settings = MCPSettingsController(
            serverControl: MCPServerControl(
                start: { configuration in try await runtime.start(configuration) },
                stop: { await runtime.stop() }
            ),
            credentialStore: Self.launchCredentialStore,
            existingCredentialOnly: ProductionNativeWorkerCommand.isRequested || Self.readOnlyMCPCredentialRequest
        )
        runtime.settingsController = settings
        _telemetry = State(initialValue: telemetry)
        telemetry.capture(.appOpened)
        _store = State(initialValue: store)
        _runnerStore = State(initialValue: DeveloperRunnerStore(evaluationStore: store))
        _mcpSettings = State(initialValue: settings)
        mcpRuntime = runtime
        if ProductionNativeWorkerCommand.isRequested {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { await ProductionNativeWorkerCommand.run(store: store) }
        }
    }

    private static var telemetryConfiguration: TelemetryConfiguration? {
        if ProductionNativeWorkerCommand.isRequested { return nil }
        #if DEBUG
        // Hosted tests must not inherit a developer's saved telemetry consent.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return nil
        }
        #endif
        return .bundled
    }

    private static var launchCredentialStore: MCPCredentialStore {
        #if DEBUG
        return MCPDebugLaunchConfiguration.credentialStore(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            isolatedStorage: acceptanceStorageDirectory, existing: .keychain
        )
        #else
        return .keychain
        #endif
    }

    private static var readOnlyMCPCredentialRequest: Bool {
        #if DEBUG
        return MCPDebugLaunchConfiguration.requestsExistingCredential(arguments: ProcessInfo.processInfo.arguments)
        #else
        return false
        #endif
    }

    private static var useExistingMCPCredential: Bool {
        #if DEBUG
        return MCPDebugLaunchConfiguration.usesExistingCredential(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            isolatedStorage: acceptanceStorageDirectory
        )
        #else
        return false
        #endif
    }

    private static var acceptanceStorageDirectory: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--evaluation-storage-name"),
           arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "FoundationEvalsUITests", directoryHint: .isDirectory)
                .appending(path: id.uuidString, directoryHint: .isDirectory)
        }
        if let index = arguments.firstIndex(of: "--evaluation-storage"),
           arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup(id: "evaluation-main", for: String.self) { _ in
            ContentView(store: store)
                .environment(runnerStore)
                .task(id: mcpSettings.installationState) {
                    appDelegate.runtime = mcpRuntime
                    guard !ProductionNativeWorkerCommand.isRequested, !ProcessInfo.processInfo.arguments.contains("--disable-mcp-autostart") else { return }
                    if Self.useExistingMCPCredential {
                        await mcpSettings.startServer()
                        return
                    }
                    guard mcpSettings.installationState == .installed else { return }
                    await mcpSettings.startServer()
                }
        } defaultValue: {
            "main"
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // AppKit's Services scanner blocks accessibility menu inspection on a lower-QoS thread.
            CommandGroup(replacing: .systemServices) { }
            #if !DEBUG
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif

            CommandMenu("Evaluation") {
                Button("Show Suite Editor") {
                    store.selection = .suite
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Show Intent Lab") {
                    store.selection = .intentLab
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Add Test Case") {
                    store.selection = .suite
                    store.addCase()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)

                Button("Add Reference Files…") {
                    store.selection = .suite
                    store.isImportingFiles = true
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)

                Divider()

                Button("Run Evaluation") {
                    do { try runnerStore.startSelectedRun(for: store) }
                    catch { store.notice = error.localizedDescription }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!runnerStore.canStartRun(for: store))

                Button("Cancel Run") {
                    runnerStore.cancelCurrentRun(for: store)
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!runnerStore.canCancelRun(for: store))
            }
        }

        Settings {
            AppSettingsView(store: store, mcpSettings: mcpSettings, telemetry: telemetry)
                .disclosureGroupStyle(FullWidthDisclosureStyle())
        }
    }
}

@MainActor
private final class FoundationEvalsAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: FoundationEvalsMCPRuntime?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await runtime.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) {
                canCheckForUpdates = $0
            }
    }
}
