import SwiftUI

struct RefusalExplanationView: View {
    let trace: EvaluationRefusalTrace
    var title: LocalizedStringResource = "Why the model refused"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).fontWeight(.semibold)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(WorkspaceStyle.warning)
            }

            if let explanation = trace.explanation {
                Text(explanation)
                    .textSelection(.enabled)
                if trace.explanationWasTruncated {
                    Text("The saved explanation was shortened to the trace limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if trace.explanationGenerationFailed {
                Text("The model refused the request, but its explanation could not be generated.")
                if let message = trace.explanationFailureMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous))
    }
}
