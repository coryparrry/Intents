import AppKit
import MacIntentTesting
import SwiftUI

/// Guides first-run setup while keeping advanced signing settings optional and authoring available.
struct SiriStudioSetupView: View {
    @Bindable var native: MacIntentTestingStore
    let catalog: MacIntentCatalog
    @State private var expanded = true
    @State private var copied = false

    /// Uses the validated configuration and explicit Siri confirmation to describe readiness.
    private var ready: Bool { native.siriSetup.issue(configuration: native.setupConfiguration) == nil }

    /// Distinguishes validated readiness from a changed advanced setting or an in-progress check.
    private var status: String {
        if ready { return "Ready to run" }
        if native.siriSetup.isChecking { return "Checking setup…" }
        if let report = native.siriSetup.report, report.configuration != native.setupConfiguration { return "Recheck settings" }
        return "\(native.siriSetup.steps.filter(\.complete).count) of 7 ready"
    }

    var body: some View {
        @Bindable var setup = native.siriSetup
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Siri Studio setup", systemImage: ready ? "checkmark.circle.fill" : "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                Text(status)
                    .foregroundStyle(ready ? .green : .secondary)
                Button(expanded ? "Hide setup checklist" : "Show setup checklist") { expanded.toggle() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("siri-studio-setup-status")
            if expanded {
                if native.siriSetup.isChecking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Detecting Xcode, signing, and app registration…")
                    }
                }
                ForEach(native.siriSetup.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.complete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.complete ? .green : .secondary)
                            .accessibilityLabel(step.complete ? "Ready" : "Action needed")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).fontWeight(.medium)
                            Text(step.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if !step.complete { action(step.action) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("siri-studio-setup-\(step.id)")
                }
                if let issue = native.siriSetup.issue(configuration: native.setupConfiguration),
                   native.siriSetup.diagnostic != nil || native.siriSetup.report?.configuration != native.setupConfiguration {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Siri AI is enabled and its downloads are complete", isOn: $setup.siriConfirmed)
                    .accessibilityIdentifier("siri-studio-confirm-siri")
                Text("Keep this Mac unlocked during a run. You can write and export scenarios while finishing setup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Recheck setup") { native.detectSiriSetup() }
                        .disabled(native.siriSetup.isChecking || native.isRunning || native.siri.isBusy)
                    Text("Xcode, team, and certificate are filled automatically. Override them in Xcode and signing below if needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: ready) { _, value in if value { expanded = false } }
    }

    /// Offers only explicit prerequisite actions; setup never installs tools, signs apps, or quits another app automatically.
    @ViewBuilder private func action(_ action: SiriStudioSetupStep.Action) -> some View {
        switch action {
        case .softwareUpdate:
            Button("Open Settings") { open("x-apple.systempreferences:com.apple.Software-Update-Settings.extension") }
        case .xcode:
            if let report = native.siriSetup.report,
               report.xcodes.contains(where: { $0.developerDirectory == report.configuration.developerDirectory }) {
                Button("Open Xcode") {
                    NSWorkspace.shared.open(URL(filePath: report.configuration.developerDirectory)
                        .deletingLastPathComponent().deletingLastPathComponent())
                }
            } else {
                Link("Get Xcode", destination: URL(string: "https://developer.apple.com/download/all/?q=Xcode")!)
            }
        case .signing:
            Text("Use Xcode → Settings → Accounts").font(.caption).foregroundStyle(.secondary)
        case .xcodegen:
            Button(copied ? "Command copied" : "Copy install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install xcodegen", forType: .string)
                copied = true
            }
        case .registerApp:
            if let installed = native.siriSetup.report?.registeredApplicationPath {
                Button("Show installed copy") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: installed)])
                }
            } else {
                Button("Open app once") {
                    Task {
                        do { _ = try await NSWorkspace.shared.openApplication(at: catalog.appURL, configuration: .init()) }
                        catch { native.reportSelectionError(error) }
                    }
                }
                .disabled(native.siriSetup.report?.running == true)
            }
        case .quitApp:
            Text("Quit it, then Recheck setup").font(.caption).foregroundStyle(.secondary)
        case .siri:
            Button("Open Siri Settings") { open("x-apple.systempreferences:com.apple.Siri-Settings.extension") }
        case .none:
            EmptyView()
        }
    }

    /// Opens an explicit settings action without treating launch success as proof that a prerequisite is complete.
    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
