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
        startingUpdater: !FoundationEvalsApp.launchesProductionWorker && !FoundationEvalsApp.launchIsolation.isHostedTest,
        updaterDelegate: nil, userDriverDelegate: nil
    )
    #endif
    private let appControl: EvaluationAppControl
    private let mcpRuntime: FoundationEvalsMCPRuntime

    init() {
        let telemetry = TelemetryController(defaults: Self.launchDefaults, configuration: Self.telemetryConfiguration,
            discardPendingCrashes: { if Self.acceptanceStorageDirectory == nil && !Self.launchesProductionWorker { TelemetryPendingCrashReports.current?.discard() } })
        let storeDirectory: URL?
        do { storeDirectory = Self.launchesProductionWorker ? try ProductionNativeWorkerCommand.prepareScratch() : Self.acceptanceStorageDirectory }
        catch { FileHandle.standardError.write(Data(("Native eval worker: \(error.localizedDescription)\n").utf8)); ProductionNativeWorkerCommand.finish(30) }
        let store = EvaluationStore(supportDirectory: storeDirectory, telemetry: telemetry)
        let control = EvaluationAppControl(store: store)
        appControl = control
        let runtime = FoundationEvalsMCPRuntime(store: store, control: control)
        let settings = MCPSettingsController(
            serverControl: MCPServerControl(
                start: { configuration in try await runtime.start(configuration) },
                stop: { await runtime.stop() }
            ),
            userDefaults: Self.launchDefaults,
            credentialStore: Self.launchCredentialStore,
            existingCredentialOnly: Self.launchesProductionWorker || Self.readOnlyMCPAccess || Self.launchIsolation.isHostedTest,
            configurationDirectory: Self.launchIsolation.isHostedTest ? storeDirectory?.appending(path: "Codex") : nil,
            telemetry: telemetry
        )
        runtime.settingsController = settings
        _telemetry = State(initialValue: telemetry)
        telemetry.appBecameActive()
        _store = State(initialValue: store)
        _runnerStore = State(initialValue: control.runners)
        _mcpSettings = State(initialValue: settings)
        mcpRuntime = runtime
        if Self.launchesProductionWorker {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { await ProductionNativeWorkerCommand.run(store: store) }
        }
    }

    private static var telemetryConfiguration: TelemetryConfiguration? {
        if Self.launchesProductionWorker || acceptanceStorageDirectory != nil { return nil }
        return .bundled
    }

    private static var launchCredentialStore: MCPCredentialStore {
        if launchIsolation.isHostedTest {
            return .init(load: { nil }, save: { _ in throw MCPSettingsAccessError.configurationReadOnly },
                remove: { throw MCPSettingsAccessError.configurationReadOnly })
        }
        #if DEBUG
        return MCPDebugLaunchConfiguration.credentialStore(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            isolatedStorage: acceptanceStorageDirectory, existing: .keychain
        )
        #else
        return .keychain
        #endif
    }

    private static var readOnlyMCPAccess: Bool {
        #if DEBUG
        return MCPDebugLaunchConfiguration.requiresReadOnlyAccess(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            isolatedStorage: acceptanceStorageDirectory
        )
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

    private static let launchIsolation: AppLaunchIsolation = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        #else
        let arguments: [String] = []
        #endif
        return .resolve(arguments: arguments, environment: ProcessInfo.processInfo.environment,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            temporaryDirectory: FileManager.default.temporaryDirectory)
    }()

    private static var launchesProductionWorker: Bool {
        launchIsolation.shouldLaunchProductionWorker(requested: ProductionNativeWorkerCommand.isRequested)
    }

    private static var acceptanceStorageDirectory: URL? { launchIsolation.storageDirectory }

    private static let launchDefaults: UserDefaults = {
        guard acceptanceStorageDirectory != nil else { return .standard }
        // No consent or connector migrations may touch the developer's defaults.
        return UserDefaults(suiteName: "Intents.IsolatedLaunch.\(UUID().uuidString)")!
    }()

    private static func sizeVerificationWindow() async {
        #if DEBUG
        guard acceptanceStorageDirectory != nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func dimension(_ flag: String, within range: ClosedRange<Double>) -> Double? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1),
                  let value = Double(arguments[index + 1]), range.contains(value) else { return nil }
            return value
        }
        guard let width = dimension("--evaluation-window-width", within: 1_000...1_600) else { return }
        let height = dimension("--evaluation-window-height", within: 700...900) ?? 780
        await Task.yield()
        guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) else { return }
        window.setContentSize(NSSize(width: width, height: height))
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "evaluation-main", for: String.self) { _ in
            ContentView(store: store, control: appControl)
                .environment(runnerStore)
                .task { await Self.sizeVerificationWindow() }
                .task(id: mcpSettings.installationState) {
                    appDelegate.runtime = mcpRuntime
                    guard !Self.launchesProductionWorker, !Self.launchIsolation.isHostedTest,
                          !ProcessInfo.processInfo.arguments.contains("--disable-mcp-autostart") else { return }
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
                Button("Show Model Evaluations") {
                    store.selection = .overview
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Show App Intent Testing") {
                    store.selection = .appIntentTesting
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Show Suite Editor") {
                    store.selection = .suite
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("3", modifiers: [.command])

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
