import SwiftUI

struct CustomProviderControls: View {
    @Binding var configuration: EvaluationCustomProviderConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Local provider endpoint", text: $configuration.endpoint)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Custom provider endpoint")

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context size")
                    HStack(spacing: 6) {
                        TextField("Tokens", value: $configuration.contextSize, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .accessibilityLabel("Context size in tokens")
                            .accessibilityIdentifier("Custom provider context size")
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Request timeout")
                    Stepper(
                        "\(configuration.requestTimeoutSeconds.formatted(.number.precision(.fractionLength(0)))) s",
                        value: $configuration.requestTimeoutSeconds,
                        in: 1...60,
                        step: 1
                    )
                    .accessibilityLabel("Request timeout")
                    .accessibilityValue("\(configuration.requestTimeoutSeconds.formatted(.number.precision(.fractionLength(0)))) seconds")
                    .accessibilityIdentifier("Custom provider request timeout")
                }
            }

            Text("Declared capabilities")
                .font(.subheadline.weight(.semibold))
            Text("Enable only capabilities the local inference service implements through the version 1 event protocol.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Toggle("Guided generation", isOn: $configuration.supportsGuidedGeneration)
                    Toggle("Reasoning", isOn: $configuration.supportsReasoning)
                }
                GridRow {
                    Toggle("Tool calling", isOn: $configuration.supportsToolCalling)
                    Toggle("Vision", isOn: $configuration.supportsVision)
                }
            }

            if let issue = configuration.validationIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Requests are sent only when a run uses this provider. The endpoint must be literal 127.0.0.1; redirects, proxies, cookies, and credentials are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 18)
    }
}
