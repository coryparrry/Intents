import AppKit
import MacIntentTesting
import SwiftUI

/// Guides first-run setup while keeping advanced signing settings optional and authoring available.
struct SiriStudioSetupView: View {
    @Bindable var native: MacIntentTestingStore
    let catalog: MacIntentCatalog
    let showsAdvanced: Bool
    @State private var copied = false

    /// Uses the validated configuration and explicit Siri confirmation to describe readiness.
    private var ready: Bool { native.siriSetup.issue(configuration: native.setupConfiguration) == nil }

    /// Distinguishes validated readiness from a changed advanced setting or an in-progress check.
    private var status: String {
        if ready { return "Ready to run" }
        if native.siriSetup.isChecking { return "Checking setup…" }
        if let report = native.siriSetup.report, report.configuration != native.setupConfiguration { return "Recheck settings" }
        return showsAdvanced ? "\(native.siriSetup.steps.filter(\.complete).count) of 7 ready" : "Finish setup"
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
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("siri-studio-setup-status")
            if !ready || showsAdvanced {
                if native.siriSetup.isChecking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Detecting Xcode, signing, and app registration…")
                    }
                }
                ForEach(showsAdvanced ? native.siriSetup.steps : Array(native.siriSetup.steps.filter { !$0.complete }.prefix(1))) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.complete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.complete ? .green : .secondary)
                            .accessibilityLabel(step.complete ? "Ready" : "Action needed")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).fontWeight(.medium)
                            Text(showsAdvanced || step.id == "signing" ? step.detail : help(for: step.id)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            if !step.complete {
                                ForEach(Array(instructions(for: step.id).enumerated()), id: \.offset) { index, instruction in
                                    Text("\(index + 1). \(instruction)")
                                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
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
                if !setup.siriConfirmed || showsAdvanced {
                    Toggle("Siri AI is enabled and its downloads are complete", isOn: $setup.siriConfirmed)
                        .accessibilityIdentifier("siri-studio-confirm-siri")
                }
                Text("Keep this Mac unlocked during a run. You can write and export scenarios while finishing setup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Recheck setup") { native.detectSiriSetup() }
                        .disabled(native.siriSetup.isChecking || native.isRunning || native.siri.isBusy)
                    if showsAdvanced {
                        Text("Xcode, team, and certificate are filled automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .workspaceSurface()
    }

    /// Describes only the next user action in the simple flow; Advanced retains the complete detected facts.
    private func help(for step: String) -> String {
        switch step {
        case "macos": "Update this Mac to run Siri conversations."
        case "xcode": "Install Xcode and finish its first-launch setup."
        case "signing": "Add your developer account in Xcode to sign tests."
        case "xcodegen": "Install the test project helper once."
        case "registered": "Use the installed copy of your app, then check again."
        case "stopped": "Close the app before running a test."
        default: "Enable Siri AI and finish its downloads."
        }
    }

    /// Gives concrete, ordered recovery actions for the prerequisite currently blocking the first test.
    private func instructions(for step: String) -> [String] {
        switch step {
        case "macos": ["Open Software Update and install macOS 27.3 or later.", "Return to Intents and choose Recheck setup."]
        case "xcode": ["Install Xcode 27.3 or later and open it once.", "Accept its license and finish installing the requested components, then Recheck setup."]
        case "signing": ["Open your project in Xcode. Select the Mac app target, then Signing & Capabilities, and choose your development team.", "In Xcode Settings, select your Apple Account and Manage Certificates. Create an Apple Development certificate if one is missing.", "Build the app with that team, replace its copy in Applications, then choose the updated app in Intents. Recheck setup to fill the matching certificate automatically."]
        case "xcodegen": ["Copy the install command, open Terminal, paste it and press Return.", "If brew is not available, install Homebrew from brew.sh first.", "When installation finishes, return here and Recheck setup."]
        case "registered": ["Copy the updated development build to Applications.", "Open that copy once, then quit it. Choose that same copy in Intents and Recheck setup."]
        case "stopped": ["Switch to the selected app and use its app menu → Quit; closing its window is not enough.", "Return here and Recheck setup."]
        default: ["Open Siri Settings, enable Siri AI and wait for its model downloads to finish.", "Confirm the switch below only after Siri is ready. Intents cannot verify this setting automatically."]
        }
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
            if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                Button("Open Xcode") { NSWorkspace.shared.open(xcode) }
            }
        case .xcodegen:
            Button(copied ? "Command copied" : "Copy install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install xcodegen", forType: .string)
                copied = true
            }
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                Button("Open Terminal") { NSWorkspace.shared.open(terminal) }
            }
            Link("Homebrew setup", destination: URL(string: "https://brew.sh")!)
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
