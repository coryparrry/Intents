import SwiftUI

struct LiveResponseSection: View {
    let response: EvaluationLiveResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live response", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text("\(response.caseName) · repetition \(response.repetition) · \(response.turnName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(response.content.isEmpty ? "Waiting for response content…" : response.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("Live response content")
            }
            .frame(maxHeight: 180)
            Text("Partial output can change while generation continues. Scoring starts after the final response.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}
