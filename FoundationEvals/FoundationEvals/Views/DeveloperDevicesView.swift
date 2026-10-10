import SwiftUI
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

struct DeveloperDevicesView: View {
    @Bindable var runners: DeveloperRunnerStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Devices & apps").font(.title2.bold())
                    Text("Evaluate the feature running in your own app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label("Nearby runners", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                        Spacer()
                        if runners.isBrowsing {
                            Text("Discovery on").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Find devices") { runners.start() }
                        }
                    }
                    if runners.runners.isEmpty {
                        WorkspaceEmptyState(
                            symbol: "laptopcomputer.and.iphone", title: "Connect your first app",
                            detail: "Open the runner in your development app on an iPhone, iPad, or Mac. Keep both devices on the same local network.",
                            actionTitle: "Set up the Swift package", actionSymbol: "plus", action: { showsGuide = true }
                        )
                        .workspaceSurface()
                    } else {
                        VStack(spacing: 12) {
                            ForEach(runners.runners) { runner in
                                DeveloperDeviceRow(runner: runner, runners: runners)
                            }
                        }
                    }
                    if let message = runners.lastError {
                        WorkspaceNotice(.warning, message: message).textSelection(.enabled)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your code. Your models. Your tools.").font(.callout.weight(.medium))
                            Text("Register a feature once, then run the same suite on each device.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Integration guide", systemImage: "chevron.left.forwardslash.chevron.right") { showsGuide = true }
                    }
                    Divider()
                    Text("Connect one runner at a time. Pairing requires the code displayed in your app. Run history keeps the device, OS, app, and feature version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(WorkspaceStyle.canvas)
        }
        .frame(width: 730, height: 630)
        .task { runners.start() }
        .sheet(isPresented: $showsGuide) { DeveloperIntegrationGuideView() }
    }
}

private struct DeveloperDeviceRow: View {
    let runner: DeveloperRunnerSnapshot
    @Bindable var runners: DeveloperRunnerStore
    @State private var pairingCode = ""
    @State private var error: String?
    @State private var confirmsForget = false

    private var isActive: Bool {
        runners.executingRunID.flatMap { runners.status(for: $0) }?.runnerID == runner.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: runner.identity.platform.deviceSymbol)
                    .font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(runner.identity.displayName).font(.headline)
                    Text("\(runner.identity.hardwareModel) · \(runner.identity.operatingSystem)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(runner.identity.appBundleIdentifier) · v\(runner.identity.appVersion)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(runner.state.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(runner.state == .connected ? Color.green : .secondary)
                connectionAction
            }
            if let detail = runner.availabilityDetail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if runner.state == .pairingRequired, let challenge = runners.pairingChallenges[runner.id] {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Enter the code shown in your app").font(.callout.weight(.medium))
                    HStack {
                        TextField("Pairing code", text: $pairingCode)
                            .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .onSubmit(pair)
                        Button("Pair device", action: pair)
                            .buttonStyle(.borderedProminent)
                            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Code expires at \(challenge.expiresAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if runner.state == .connected {
                HStack {
                    Label("\(runner.features.count) registered features", systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget pairing", role: .destructive) { confirmsForget = true }
                        .buttonStyle(.plain).font(.caption).disabled(isActive)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20).workspaceSurface()
        .confirmationDialog("Forget \(runner.identity.displayName)?", isPresented: $confirmsForget) {
            Button("Forget pairing", role: .destructive) {
                perform { try runners.forgetTrust(for: runner.id) }
            }
        } message: { Text("You will need to enter a new pairing code to connect again.") }
    }

    @ViewBuilder private var connectionAction: some View {
        switch runner.state {
        case .connected:
            Button("Disconnect") { runners.disconnect(runner.id) }.disabled(isActive)
        case .connecting, .pairingRequired:
            Button("Cancel") { runners.cancelPairing(with: runner.id); pairingCode = "" }
        case .discovered, .disconnected:
            Button("Connect") { perform { try runners.beginPairing(with: runner.id) } }
                .disabled(runners.runners.contains { $0.id != runner.id && [.connected, .connecting, .pairingRequired].contains($0.state) })
        case .incompatible:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func pair() {
        perform { try runners.trustRunner(runner.id, pairingCode: pairingCode) }
        pairingCode = ""
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

extension DeveloperRunnerPlatform {
    var deviceSymbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "desktopcomputer"
        case .vision: "visionpro"
        case .unknown: "externaldrive.connected.to.line.below"
        }
    }
}

extension DeveloperRunnerConnectionState {
    var displayTitle: String {
        switch self {
        case .discovered: "Nearby"
        case .connecting: "Connecting…"
        case .pairingRequired: "Pairing required"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .incompatible: "Update required"
        }
    }
}

extension DeveloperRunPhase {
    var isInProgress: Bool { self == .preparing || self == .dispatching || self == .running }
}
