import SwiftUI

/// A small drop-in companion surface for a developer app on iPhone, iPad, or Mac.
/// The containing app still owns feature registration and the service lifecycle.
public struct DeveloperRunnerView: View {
    public let service: DeveloperRunnerService

    public init(service: DeveloperRunnerService) {
        self.service = service
    }

    public var body: some View {
        Form {
            Section("Runner") {
                LabeledContent("Name", value: service.identity.displayName)
                LabeledContent("Device", value: service.identity.hardwareModel)
                LabeledContent("System", value: service.identity.operatingSystem)
                LabeledContent("Status", value: service.isAdvertising ? "Discoverable" : "Stopped")
            }

            Section("Registered features") {
                if service.features.isEmpty {
                    ContentUnavailableView(
                        "No Features Registered",
                        systemImage: "shippingbox",
                        description: Text("Register at least one feature before connecting Foundation Evals.")
                    )
                } else {
                    ForEach(service.features) { feature in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.displayName)
                            Text("\(feature.id) · v\(feature.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("Pairing") {
                pairingContent
                Button("Start pairing") {
                    Task { @concurrent in
                        await service.beginPairing()
                    }
                }
                .disabled(!service.isAdvertising)

                Button("Cancel pairing", role: .cancel) {
                    Task { @concurrent in
                        await service.cancelPairing()
                    }
                }
                .disabled(!isPairing)
            }

            if !service.connectedDesktopNames.isEmpty {
                Section("Trusted connections") {
                    ForEach(service.connectedDesktopNames, id: \.self) { name in
                        Label(name, systemImage: "lock.shield")
                    }
                }
            }

            if let lastError = service.lastError {
                Section("Connection issue") {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Foundation Evals Runner")
        .task {
            service.start()
            await service.refreshFeatures()
            await service.refreshPairingState()
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        switch service.pairingState {
        case .idle:
            Text("Pairing is off. Start it only when you are ready to connect a desktop.")
                .foregroundStyle(.secondary)
        case .advertising(let code, let endpoint, let expiresAt):
            LabeledContent("Code") {
                Text(code)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
                .accessibilityLabel("Pairing code \(code)")
            LabeledContent("Endpoint", value: endpoint)
            LabeledContent("Expires", value: expiresAt.formatted(date: .omitted, time: .standard))
        case .paired:
            Label("Paired", systemImage: "checkmark.shield")
        case .expired:
            Label("Pairing code expired", systemImage: "clock.badge.exclamationmark")
        }
    }

    private var isPairing: Bool {
        if case .advertising = service.pairingState { true } else { false }
    }
}
