import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FoundationEvals

/// Renders the main window with fixture data into PNGs for visual review.
/// Runs only when `INTENTS_SNAPSHOT_DIR` is set (CI forwards it as `TEST_RUNNER_INTENTS_SNAPSHOT_DIR`).
@MainActor
@Suite(.serialized)
struct UISnapshotTests {
    @Test func captureMainWindowScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let output = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for dark in [false, true] {
            let fixture = try SnapshotFixture()
            defer { fixture.close() }
            let suffix = dark ? "dark" : "light"
            let host = SnapshotWindow(store: fixture.store, runners: fixture.runners, dark: dark)
            defer { host.close() }

            fixture.store.selection = .overview
            try await host.settle(2.5)
            try host.write(to: output.appending(path: "01-overview-\(suffix).png"))

            fixture.store.selection = .suite
            try await host.settle(1.5)
            try host.write(to: output.appending(path: "02-suite-cases-\(suffix).png"))

            if host.selectSegment(titled: "Results") {
                try await host.settle(1)
                try host.write(to: output.appending(path: "03-suite-results-\(suffix).png"))
            }
            if host.selectSegment(titled: "Setup") {
                try await host.settle(1)
                try host.write(to: output.appending(path: "04-suite-setup-\(suffix).png"))
            }
            if host.selectSegment(titled: "Cases") { try await host.settle(0.5) }

            fixture.store.selection = .run(fixture.latestRunID)
            try await host.settle(1.5)
            if host.selectSegment(titled: "Report") {
                try await host.settle(1.5)
                try host.write(to: output.appending(path: "05-run-report-\(suffix).png"))
            }
            if host.selectSegment(titled: "Workflow trace") {
                try await host.settle(1)
                try host.write(to: output.appending(path: "06-run-trace-\(suffix).png"))
            }

            fixture.store.selection = .intentLab
            try await host.settle(2)
            try host.write(to: output.appending(path: "07-intent-lab-\(suffix).png"))
        }
    }
}

@MainActor
private final class SnapshotFixture {
    let directory: URL
    let store: EvaluationStore
    let runners: DeveloperRunnerStore
    private(set) var latestRunID = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "IntentsSnapshots-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = EvaluationStore(supportDirectory: directory)
        runners = DeveloperRunnerStore(evaluationStore: store)

        let untitled = store.selectedSuiteID
        _ = try store.createSuite(name: "Receipt extraction", starter: .structuredExtraction)
        _ = try store.createSuite(name: "Conversation behaviour", starter: .conversationBehaviour)
        let main = try store.createSuite(name: "Grounded answers", starter: .groundedAnswers)
        try? store.archiveSuite(id: untitled)
        if store.selectedSuiteID != main { try store.switchSuite(id: main) }
        store.draftSuite.repetitions = 2
        _ = store.saveSuite()
        store.runs = makeRuns()
        latestRunID = store.runs.first?.id ?? latestRunID
    }

    func close() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRuns() -> [EvaluationRun] {
        let suite = store.draftSuite
        let plans: [(hoursAgo: Double, failures: Set<Int>, errors: Set<Int>)] = [
            (0.4, [2], []), (5, [1, 2], []), (27, [], [0]), (52, [0, 1, 3], [])
        ]
        return plans.enumerated().map { index, plan in
            let started = Date().addingTimeInterval(-plan.hoursAgo * 3_600)
            var results: [EvaluationSampleResult] = []
            for repetition in 1...suite.repetitions {
                for (caseIndex, evaluationCase) in suite.cases.enumerated() {
                    let slot = results.count
                    let status: EvaluationResultStatus = plan.errors.contains(slot) ? .error
                        : plan.failures.contains(slot) ? .failed : .passed
                    results.append(EvaluationSampleResult(
                        caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: repetition,
                        prompt: evaluationCase.prompt, expected: evaluationCase.expected,
                        response: status == .error ? "" : "A grounded response for \(evaluationCase.name.lowercased()).",
                        status: status, score: status == .passed ? 4 : status == .failed ? 2 : nil,
                        rationale: status == .failed ? "One requirement is materially unmet." : "Every requirement is met.",
                        durationMilliseconds: Double(820 + (caseIndex * 610 + repetition * 240 + index * 130) % 2_400),
                        usage: EvaluationUsage(inputTokens: 380 + caseIndex * 40, outputTokens: 140 + repetition * 30),
                        judgeDurationMilliseconds: 420, judgeUsage: nil,
                        errorCategory: status == .error ? "providerUnavailable" : nil,
                        errorMessage: status == .error ? "The model was not ready." : nil,
                        judgeErrorCategory: nil, judgeErrorMessage: nil
                    ))
                }
            }
            return EvaluationRun(
                id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: "v1.\(3 - index)",
                instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
                repetitions: suite.repetitions, judgePromptVersion: "fixture", judgePassingScore: 3,
                plannedSampleCount: results.count, suiteRevision: store.suiteRevision, plannedCases: suite.cases,
                historySequence: UInt64(10 - index),
                startedAt: started, completedAt: started.addingTimeInterval(38), cancelled: false,
                terminationReason: nil,
                environment: .init(operatingSystem: "macOS 27.0", locale: "en_GB",
                                   model: "Apple on-device model", modelContextSize: 4_096),
                attachments: [], results: results
            )
        }
    }
}

@MainActor
private final class SnapshotWindow {
    let window: NSWindow

    init(store: EvaluationStore, runners: DeveloperRunnerStore, dark: Bool) {
        let controller = NSHostingController(rootView: ContentView(store: store).environment(runners))
        controller.sceneBridgingOptions = [.toolbars, .title]
        controller.sizingOptions = []
        window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 1_320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_320, height: 860))
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
    }

    /// Suspends rather than spinning the run loop so parallel main-actor tests keep making progress.
    func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func write(to url: URL) throws {
        let view = window.contentView?.superview ?? window.contentView!
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    /// Selects a segment by title in any segmented control, including toolbar-bridged ones.
    func selectSegment(titled title: String) -> Bool {
        var roots: [NSView] = []
        if let frame = window.contentView?.superview { roots.append(frame) }
        for item in window.toolbar?.items ?? [] { if let view = item.view { roots.append(view) } }
        for root in roots {
            if let control = segmentedControl(in: root, containing: title) {
                for segment in 0..<control.segmentCount where control.label(forSegment: segment) == title {
                    control.selectedSegment = segment
                    _ = control.sendAction(control.action, to: control.target)
                    return true
                }
            }
        }
        return false
    }

    private func segmentedControl(in view: NSView, containing title: String) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl,
           (0..<control.segmentCount).contains(where: { control.label(forSegment: $0) == title }) {
            return control
        }
        for child in view.subviews {
            if let found = segmentedControl(in: child, containing: title) { return found }
        }
        return nil
    }
}
