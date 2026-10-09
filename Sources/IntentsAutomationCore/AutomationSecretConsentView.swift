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
                    .disabled(model.state != .ready || closing)
                    .accessibilityIdentifier("automation.secret.credential")
            }
            Text(model.review.approval.effects.contains(.externalWrite) ? "This may change data in the selected app." : "This may change the disposable test fixture.")
                .font(.caption)
            Text("Permission allows one fill and expires after 60 seconds. Delivery will be checked separately.").font(.caption)
            if model.state == .verifying || model.state == .authorizing { ProgressView("Checking the app and secure field…") }
            if model.state == .failed { Text("The app or secure field could not be verified. Close this request and review the field again.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") {
                    closing = true; secret = ""
                    Task { await model.cancelAndDrain(); onCancelled() }
                }.keyboardShortcut(.cancelAction).disabled(closing)
                Button("Allow one fill") { confirm() }
                    .disabled(closing || model.state != .ready || secret.isEmpty || secret.utf16.count > 32768)
            }
        }
        .padding(20).frame(minWidth: 440, idealWidth: 480)
        .task { do { try await model.prepare() } catch {} }
        .onChange(of: model.state) { if model.state != .ready { secret = "" } }
        .onDisappear {
            closing = true; secret = ""
            if !delivered { Task { await model.cancelAndDrain() } }
        }
    }
    private func confirm() {
        let value = secret; secret = ""
        Task {
            do {
                let request = try await model.confirm(value)
                guard !closing, model.state == .approved else { await model.cancelAndDrain(); return }
                delivered = true; onApproved(request)
            } catch {}
        }
    }
}
#endif
