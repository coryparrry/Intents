import SwiftUI

struct MCPSettingsView: View {
    @Bindable var controller: MCPSettingsController
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    Label(controller.serverState.label, systemImage: statusSymbol)
                        .foregroundStyle(statusColor)
                }

                Text("The connector lets Codex use your local evaluation tools and results.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let lastConnection = controller.lastConnection {
                    LabeledContent("Last connection") {
                        Text(lastConnection, format: .dateTime.month().day().hour().minute().second())
                    }
                }

                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Section("Codex") {
                LabeledContent("Configuration") {
                    Text(controller.installationState.label)
                        .foregroundStyle(controller.installationState == .needsAttention ? .orange : .secondary)
                }

                Text("This saves the connection in Codex and starts the connector. After setup, it starts automatically whenever Intents is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(codexActionTitle) {
                    Task { await controller.installOrUpdateCodex() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("Codex install or update")
                .disabled(controller.isBusy)

                DisclosureGroup("Advanced") {
                    Button("Copy Endpoint") {
                        controller.copyEndpoint()
                    }
                    .help("Copy the local address that Codex uses to connect to Intents.")

                    Button("Copy Manual Configuration") {
                        Task { await controller.copyManualConfiguration() }
                    }
                    .help("Copy the connection settings to add to Codex yourself.")

                    Button("Remove from Codex", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .disabled(controller.installationState == .notConfigured)
                }
                .disabled(controller.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 440)
        .navigationTitle("MCP Connector")
        .confirmationDialog(
            "Remove Intents from Codex?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from Codex", role: .destructive) {
                Task { await controller.removeFromCodex() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the managed Intents block is removed. Restart Codex afterward.")
        }
        .alert(
            "MCP Connector",
            isPresented: Binding(
                get: { controller.notice != nil },
                set: { if !$0 { controller.notice = nil } }
            )
        ) {
            Button("OK") { controller.notice = nil }
        } message: {
            Text(controller.notice ?? "")
        }
    }

    private var codexActionTitle: String {
        switch controller.installationState {
        case .notConfigured: "Connect to Codex"
        case .installed:
            controller.serverState == .running ? "Update Codex" : "Reconnect to Codex"
        case .needsAttention: "Repair Connection"
        }
    }

    private var statusSymbol: String {
        switch controller.serverState {
        case .running: "checkmark.circle.fill"
        case .starting, .stopping: "circle.dotted"
        case .stopped: "circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.serverState {
        case .running: .green
        case .starting, .stopping: .secondary
        case .stopped: .secondary
        case .failed: .orange
        }
    }
}

#Preview {
    MCPSettingsView(controller: MCPSettingsController(serverControl: .disconnected))
}
