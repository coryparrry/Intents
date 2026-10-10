import AppKit
import SwiftUI

struct TelemetrySettingsView: View {
    @Bindable var telemetry: TelemetryController
    @State private var copiedReport = false

    var body: some View {
        Form {
            Section("Usage statistics") {
                Toggle("Share usage statistics", isOn: Binding(
                    get: { telemetry.isEnabled }, set: { telemetry.setEnabled($0) }
                ))
                .disabled(!telemetry.isConfigured)
                .accessibilityIdentifier("Share usage statistics")
                Text("On by default. Shares app sessions, first observed use, fixed screen names, completed features, app/build and macOS versions, and random installation/session identifiers with PostHog. No name, email, or Apple account.")
                    .foregroundStyle(.secondary)
            }
            Section("Optional diagnostics") {
                Toggle("Share diagnostic statistics", isOn: Binding(
                    get: { telemetry.diagnosticsEnabled }, set: { telemetry.setDiagnosticsEnabled($0) }
                ))
                .disabled(!telemetry.isConfigured)
                .accessibilityIdentifier("Share diagnostic statistics")
                Text("Off by default. Shares which operations start and finish, their duration, error categories, app build, macOS version, and processor type. Generated session and operation identifiers help connect related events. Also shares automatic crash reports on the next launch, with crash categories, native stack addresses and binary identifiers.")
                    .foregroundStyle(.secondary)
                Text("Prompts, responses, scores, names, file paths, URLs, credentials, screen recordings, raw error messages and breadcrumbs are excluded. Stack traces contain code addresses, not app content.")
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics on this Mac") {
                Text("The latest 100 diagnostic events are kept in memory for this session, even when sharing is off. Copy a report to help investigate an issue.")
                    .foregroundStyle(.secondary)
                Text(telemetry.delivery.label)
                    .accessibilityIdentifier("Telemetry delivery status")
                Button("Retry upload") { telemetry.flushPendingEvents() }
                    .disabled(!telemetry.isEnabled && !telemetry.diagnosticsEnabled)
                Text("\(telemetry.recentDiagnostics.count) recent events")
                    .foregroundStyle(.secondary)
                ForEach(Array(telemetry.recentDiagnostics.filter {
                    $0.properties["error_code"] != nil && $0.properties["error_code"] != "cancelled"
                }.suffix(3).enumerated()), id: \.offset) { _, record in
                    Text("\((record.properties["operation"] ?? "operation").replacingOccurrences(of: "_", with: " ").capitalized): \((record.properties["error_code"] ?? "error").replacingOccurrences(of: "_", with: " "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(copiedReport ? "Diagnostic report copied" : "Copy diagnostic report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(telemetry.diagnosticReport(), forType: .string)
                    copiedReport = true
                }
                .accessibilityIdentifier("Copy diagnostic report")
                if !telemetry.isConfigured {
                    Text("Sharing is disabled by this Mac’s local policy, in development, tests, previews and demos, or when this build has no telemetry configuration. Local reports are still available.")
                        .foregroundStyle(.secondary)
                }
                Text("Turning a sharing option off clears queued events and pending crash reports. Crashes recorded outside diagnostic consent are discarded. Data already received by PostHog is not deleted. Uploads are best effort; acceptance confirms the upload, not that it is already visible in a chart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 620)
    }
}
