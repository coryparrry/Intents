import SwiftUI

struct ProductionActiveBatchBanner: View {
    let job: ProductionJob
    let progress: ProductionProgress?
    let showResults: () -> Void
    let pause: () -> Void
    let cancel: () -> Void
    let repeatBatch: () -> Void
    let export: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            RunToolbarProgress(completed: progress?.completed ?? 0, total: job.plannedCount)
                .help(job.name)
            Button("View running batch", systemImage: "arrow.up.right.square", action: showResults)
                .labelStyle(.iconOnly).help("Open results for \(job.name)")
            Menu {
                Text(job.name)
                Button("Pause", systemImage: "pause", action: pause)
                Button("Cancel…", systemImage: "stop.fill", role: .destructive, action: cancel)
                Divider()
                Button("Repeat batch", action: repeatBatch)
                Button("Export evidence…", action: export)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Running batch actions")
        }
        .accessibilityIdentifier("production-active-batch")
    }
}
