import AppKit
import SwiftUI

struct DeveloperIntegrationGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let packageURL = "https://github.com/coryparrry/Foundation-Eval-Labs.git"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect your Swift app").font(.title2.bold())
                    Text("Keep your real model sessions, @Generable types, and tools.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(1, title: "Add the package", detail: "In Xcode, add this repository as a package dependency. Link the FoundationEvalsDeveloper product to your development app.") {
                        code(packageURL)
                        Text("Requires iOS / iPadOS 26 or macOS 26 and later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    step(2, title: "Register your feature", detail: "Call the same service your app uses. Replace appFeature below with your own implementation.") {
                        code(Self.registration)
                    }
                    step(3, title: "Present the runner", detail: "Keep one runner ID per installation and store trust in your app’s private Application Support directory. Present this view in a development build.") {
                        code(Self.hosting)
                    }
                    step(4, title: "Pair and run", detail: "For iPhone and iPad, add these keys to Info.plist and allow local network access.") {
                        code(Self.networkConfiguration)
                        Text("Open the runner and choose Start pairing. Return to Devices & apps on your Mac, connect, and enter the displayed code. In a suite, choose the device and feature from Run destination.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .background(WorkspaceStyle.canvas)
        }
        .frame(width: 730, height: 690)
    }

    private func step<Content: View>(_ number: Int, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text(number.formatted()).font(.caption.weight(.semibold))
                    .frame(width: 23, height: 23).background(Color.accentColor.opacity(0.1), in: .circle)
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }

    private func code(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Copy into your project").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }.buttonStyle(.plain).font(.caption)
            }
            ScrollView(.horizontal) {
                Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(15).workspaceSurface()
    }

    private static let registration = """
    import FoundationEvalsDeveloper

    let registry = DeveloperFeatureRegistry()
    await registry.registerTextFeature(
        id: "my-app.summary", displayName: "Article summary", version: "1"
    ) { input, context in
        try context.checkCancellation()
        let answer = try await appFeature.respond(to: input.prompt)
        return DeveloperFeatureOutput(response: answer)
    }
    """
    private static let hosting = """
    let service = DeveloperRunnerService(
        identity: .current(id: savedRunnerID, displayName: "My App"),
        registry: registry,
        trustStoreURL: applicationSupportURL
            .appending(path: "foundation-evals-trust.json")
    )
    // Keep service alive for the lifetime of your runner screen.
    DeveloperRunnerView(service: service)
    """
    private static let networkConfiguration = """
    <key>NSLocalNetworkUsageDescription</key>
    <string>Connect to Foundation Evals on your Mac.</string>
    <key>NSBonjourServices</key>
    <array><string>_fnd-evals._tcp</string></array>
    """
}

struct DeveloperConnectionBanner: View {
    @Environment(DeveloperRunnerStore.self) private var runners
    @State private var showsDevices = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 5) {
                Text("Test the feature inside your app").font(.callout.weight(.semibold))
                Text("Connect a Swift app to evaluate it on iPhone, iPad, and Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Devices & apps", systemImage: "arrow.up.right") { showsDevices = true }
        }
        .padding(20).workspaceSurface()
        .sheet(isPresented: $showsDevices) { DeveloperDevicesView(runners: runners) }
    }
}
