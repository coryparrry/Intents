//
//  FoundationEvalsApp.swift
//  FoundationEvals
//
//  Created by Cory Parry on 01/09/2026.
//

import AppKit
import SwiftUI
import Sparkle

@main
@MainActor
struct FoundationEvalsApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(FoundationEvalsAppDelegate.self) private var appDelegate
    @State private var store: EvaluationStore
    @State private var telemetry: TelemetryController
    @State private var mcpSettings: MCPSettingsController
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private let mcpRuntime: FoundationEvalsMCPRuntime

    init() {
        let telemetry = TelemetryController(configuration: Self.telemetryConfiguration)
        let store = EvaluationStore(supportDirectory: Self.acceptanceStorageDirectory)
        let runtime = FoundationEvalsMCPRuntime(store: store)
        let settings = MCPSettingsController(
            serverControl: MCPServerControl(
                start: { configuration in try await runtime.start(configuration) },
                stop: { await runtime.stop() }
            )
        )
        runtime.settingsController = settings
        _telemetry = State(initialValue: telemetry)
        telemetry.capture(.appOpened)
        _store = State(initialValue: store)
        _mcpSettings = State(initialValue: settings)
        mcpRuntime = runtime
    }

    private static var telemetryConfiguration: TelemetryConfiguration? {
        #if DEBUG
        // Hosted tests must not inherit a developer's saved telemetry consent.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return nil
        }
        #endif
        return .bundled
    }

    private static var acceptanceStorageDirectory: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
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
                .task(id: mcpSettings.installationState) {
                    appDelegate.runtime = mcpRuntime
                    guard !ProcessInfo.processInfo.arguments.contains("--disable-mcp-autostart") else { return }
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            CommandMenu("Evaluation") {
                Button("Show Suite Editor") {
                    store.selection = .suite
                    openWindow(id: "evaluation-main", value: "main")
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Add Test Case") {
                    store.selection = .suite
                    store.addCase()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.isRunning || store.isProcessingFiles)

                Button("Add Reference Files…") {
                    store.selection = .suite
                    store.isImportingFiles = true
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(store.isRunning || store.isProcessingFiles)

                Divider()

                Button("Run Evaluation") {
                    store.startRun()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(store.isRunning || store.isProcessingFiles || store.runBlocker != nil)

                Button("Cancel Run") {
                    store.cancelRun()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.isRunning)
            }
        }

        Settings {
            AppSettingsView(mcpSettings: mcpSettings, telemetry: telemetry)
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
