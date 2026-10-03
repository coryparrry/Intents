import SwiftUI
import FoundationEvalsDeveloper

@main
struct IntentLabFixtureApp: App {
    @State private var runner = IntentLabFixtureRunner()

    init() {
        #if INTENT_LAB_TEST_SUPPORT
        if CommandLine.arguments.contains("-intent-lab-reset") {
            // Siri activation can outlast the phone’s normal auto-lock interval.
            // Keep only this test fixture awake for its lifetime.
            UIApplication.shared.isIdleTimerDisabled = true
            FixtureState.reset()
        }
        if let index = CommandLine.arguments.firstIndex(of: "-intent-lab-context"),
           CommandLine.arguments.indices.contains(index + 1) {
            FixtureState.begin(context: CommandLine.arguments[index + 1])
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Fixture", systemImage: "note.text") }
                NavigationStack {
                    if runner.isReady {
                        DeveloperRunnerView(service: runner.service)
                    } else {
                        ProgressView("Registering feature…")
                    }
                }
                .tabItem { Label("Runner", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .task { await runner.prepareIfNeeded() }
        }
    }
}

struct ContentView: View {
    @AppStorage(FixtureState.selectedNoteKey) private var selectedNoteID = "none"
    @AppStorage(FixtureState.mutationCountKey) private var mutationCount = 0
    @AppStorage(FixtureState.observedContextKey) private var observedContext = "none"
    @AppStorage(FixtureState.eventKey) private var lastEvent = "none"

    var body: some View {
        NavigationStack {
            List(FixtureNotes.all) { note in
                VStack(alignment: .leading) {
                    Text(note.title).font(.headline)
                    Text(note.body).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Synthetic notes")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedNoteID).accessibilityIdentifier("intent-lab-selected-note-id")
                    Text(String(mutationCount)).accessibilityIdentifier("intent-lab-mutation-count")
                    Text(observedContext).accessibilityIdentifier("intent-lab-observed-context")
                    Text(lastEvent).accessibilityIdentifier("intent-lab-last-event")
                }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }
}
