import SwiftUI

struct LiveResponseSection: View {
    let response: EvaluationLiveResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                WorkspaceSymbolBadge(symbol: "waveform", tint: .accentColor, size: 26)
                Text("Live response")
                    .font(.headline)
                Spacer()
                Text("\(response.caseName) · repetition \(response.repetition) · \(response.turnName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                Text(response.content.isEmpty ? "Waiting for response content…" : response.content)
                    .foregroundStyle(response.content.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("Live response content")
            }
            .frame(maxHeight: 180)
            .workspaceInset()
            Text("Partial output can change while generation continues. Scoring starts after the final response.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .workspaceSurface()
    }
}
