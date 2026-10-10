import AppKit
import SwiftUI

private enum AppSettingsPage: String, Hashable {
    case mcp
    case judges
    case privacy
}

struct AppSettingsView: View {
    @Bindable var store: EvaluationStore
    @Bindable var mcpSettings: MCPSettingsController
    @Bindable var telemetry: TelemetryController
    @Environment(\.controlActiveState) private var windowActivity
    @AppStorage("settingsPage") private var selectedPage = AppSettingsPage.mcp

    var body: some View {
        TabView(selection: $selectedPage) {
            MCPSettingsView(controller: mcpSettings)
                .workspacePageTransition(value: selectedPage, animatesOnAppearance: true)
                .tabItem { Label("MCP Connector", systemImage: "network") }
                .tag(AppSettingsPage.mcp)

            JudgeConnectionsSettingsView(store: store)
                .workspacePageTransition(value: selectedPage, animatesOnAppearance: true)
                .tabItem { Label("Judges", systemImage: "checkmark.seal") }
                .tag(AppSettingsPage.judges)

            TelemetrySettingsView(telemetry: telemetry)
                .workspacePageTransition(value: selectedPage, animatesOnAppearance: true)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(AppSettingsPage.privacy)
        }
        .padding(12)
        .onChange(of: telemetry.isEnabled) { _, _ in recordScreen() }
        .onChange(of: selectedPage, initial: true) { _, _ in recordScreen() }
        .onChange(of: windowActivity, initial: true) { _, activity in
            if activity == .key { recordScreen() }
        }
    }
    private func recordScreen() {
        guard windowActivity == .key else { return }
        telemetry.screen(selectedPage == .privacy ? .privacySettings : (selectedPage == .judges ? .judgeSettings : .mcpSettings))
    }
}
