import SwiftUI

struct SpotlightSearchTraceView: View {
    let trace: EvaluationSpotlightSearchTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Spotlight search", systemImage: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            SpotlightTraceConfiguration(trace: trace)

            if !trace.collectionComplete {
                Label(
                    trace.collectionIssue ?? "Spotlight trace metadata collection was incomplete.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("Incomplete Spotlight trace")
            }

            if trace.replyCount == 0, trace.collectionComplete {
                Text("The model did not produce a Spotlight search result during this sample.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if trace.replyCount > 0 {
                SpotlightTraceMetrics(trace: trace)
            }

            Text("The saved trace contains aggregate counts only. Queries and result content are available only when full public transcript capture was enabled for the run.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct SpotlightTraceConfiguration: View {
    let trace: EvaluationSpotlightSearchTrace

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Sources")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if trace.searchedFiles {
                        Label("Files", systemImage: "folder")
                    }
                    if trace.searchedCoreSpotlight {
                        Label("Core Spotlight", systemImage: "square.stack.3d.up")
                    }
                    if trace.allowedMail {
                        Label("Mail", systemImage: "envelope")
                    }
                }
            }

            GridRow {
                Text("Guidance")
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(trace.guidanceMode.title)
                    if let focusedDomain = trace.focusedDomain {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(focusedDomain.title)
                    }
                }
            }

            GridRow {
                Text("Format")
                    .foregroundStyle(.secondary)
                Text(trace.outputFormat.title)
            }

            GridRow {
                Text("Resolver")
                    .foregroundStyle(.secondary)
                Text(trace.contactResolverEnabled ? "Configured identity" : "Off")
            }

            GridRow {
                Text("Custom stages")
                    .foregroundStyle(.secondary)
                Text(trace.customPipelineStages.isEmpty
                    ? "None"
                    : trace.customPipelineStages.joined(separator: ", "))
            }

            GridRow {
                Text("Limits")
                    .foregroundStyle(.secondary)
                Text("\(trace.maximumPossibleResults) results · \(trace.maximumResponseSize) response size")
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }
}

private struct SpotlightTraceMetrics: View {
    let trace: EvaluationSpotlightSearchTrace

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                metric("Queries", value: trace.queryCount)
                metric("Stages", value: trace.stageCount)
                metric("Replies", value: trace.replyCount)
            }
            GridRow {
                metric("Items", value: itemCount)
                metric("Table rows", value: trace.tableRowCount)
                metric("Text replies", value: trace.textReplyCount)
            }
        }
        .font(.caption)
    }

    private var itemCount: Int {
        trace.itemResultCount + trace.scoredItemResultCount + trace.groupedItemResultCount
    }

    private func metric(_ label: LocalizedStringResource, value: Int) -> some View {
        LabeledContent(label) {
            Text(value, format: .number)
                .monospacedDigit()
        }
    }
}
