#if os(macOS)
import SwiftUI

/// Only a trusted native owner can present this internal view with reviewed sink metadata.
@MainActor struct AutomationSecretConsentView: View {
    let model: AutomationSecretConsentModel
    let onApproved: (AutomationSecretFillRequest) -> Void
    let onCancelled: () -> Void
    @State private var secret = ""
    @State private var closing = false
    @State private var delivered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow one secure fill?").font(.headline)
            Text("Enter the test credential you want to use for this field.")
            Form {
                LabeledContent("App", value: URL(fileURLWithPath: model.review.approval.app.canonicalBundlePath!).lastPathComponent)
                LabeledContent("Bundle", value: model.review.approval.app.bundleID)
                LabeledContent("Location", value: model.review.approval.app.canonicalBundlePath!)
                LabeledContent("Secure field", value: model.review.sinkID)
                LabeledContent("Session", value: "Current Mac session")
                SecureField("Test credential", text: $secret)
                    .disabled(!Self.acceptsInput(state: model.state, closing: closing))
                    .accessibilityIdentifier("automation.secret.credential")
            }
            Text(Self.effectNotice(for: model.review.approval.effects))
                .font(.caption)
            Text("Permission allows one fill and expires after 60 seconds. Delivery will be checked separately.").font(.caption)
            if Self.showsProgress(state: model.state) { ProgressView("Checking the app and secure field…") }
            if model.state == .failed { Text("The app or secure field could not be verified. Close this request and review the field again.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") {
                    closing = true; secret = ""
                    Task { await model.cancelAndDrain(); onCancelled() }
                }.keyboardShortcut(.cancelAction).disabled(closing)
                Button("Allow one fill") { confirm() }
                    .disabled(!Self.canConfirm(state: model.state, closing: closing, secret: secret))
            }
        }
        .padding(20).frame(minWidth: 440, idealWidth: 480)
        .task { do { try await model.prepare() } catch {} }
        .onChange(of: model.state) { if !Self.retainsSecret(state: model.state) { secret = "" } }
        .onDisappear {
            closing = true; secret = ""
            if Self.cancelsOnDisappear(delivered: delivered) { Task { await model.cancelAndDrain() } }
        }
    }
    static let maximumSecretUTF16Count = 32768
    static func acceptsInput(state: AutomationSecretConsentModel.State, closing: Bool) -> Bool {
        state == .ready && !closing
    }
    static func canConfirm(state: AutomationSecretConsentModel.State, closing: Bool, secret: String) -> Bool {
        acceptsInput(state: state, closing: closing) && !secret.isEmpty && secret.utf16.count <= maximumSecretUTF16Count
    }
    static func retainsSecret(state: AutomationSecretConsentModel.State) -> Bool { state == .ready }
    static func showsProgress(state: AutomationSecretConsentModel.State) -> Bool { state == .verifying || state == .authorizing }
    static func delivers(closing: Bool, state: AutomationSecretConsentModel.State) -> Bool { !closing && state == .approved }
    static func cancelsOnDisappear(delivered: Bool) -> Bool { !delivered }
    static func effectNotice(for effects: Set<AutomationEffect>) -> String {
        effects.contains(.externalWrite) ? "This may change data in the selected app." : "This may change the disposable test fixture."
    }
    private func confirm() {
        let value = secret; secret = ""
        Task {
            do {
                let request = try await model.confirm(value)
                guard Self.delivers(closing: closing, state: model.state) else { await model.cancelAndDrain(); return }
                delivered = true; onApproved(request)
            } catch {}
        }
    }
}
#endif
