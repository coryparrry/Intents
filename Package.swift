// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The desktop app has its own Xcode target. These deterministic components also
// build as a package for focused tests and developer integration.
let portableProductionSources = [
    "Services/AppLaunchIsolation.swift",
    "MCP/Installer/CodexMCPInstaller.swift",
    "Models/EvaluationFieldAssertion.swift",
    "Models/EvaluationScoringTypes.swift",
    "Models/WorkflowTimelineInterval.swift",
    "Services/EvaluationFieldAssertions.swift",
    "Services/MetricScorer.swift",
]
let portableTestSources = [
    "AppLaunchIsolationTests.swift",
    "CodexMCPInstallerTests.swift",
    "EvaluationFieldAssertionTests.swift",
    "MetricScorerTests.swift",
    "WorkflowTimelineIntervalTests.swift",
    "NavigationInteractionTests.swift",
    "TimelineRenderingTests.swift",
    "RunToolbarProgressTests.swift",
]
func excludedFiles(at path: String, keeping sources: [String]) -> [String] {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(path)
    guard let entries = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    return entries.compactMap { entry in
        guard let file = entry as? URL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        let relative = String(file.path.dropFirst(base.path.count + 1))
        return sources.contains(relative) ? nil : relative
    }
}
let package = Package(
    name: "FoundationEvalsPortable",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacIntentTesting", targets: ["MacIntentTesting"]),
        .library(name: "FoundationEvalsDeveloper", targets: ["FoundationEvalsDeveloper"]),
        .executable(name: "intents-evals", targets: ["ProductionEvalsCLI"]),
        .executable(name: "intents-native-tests", targets: ["MacIntentTestingCLI"]),
    ],
    targets: [
        .target(name: "ProductionEvals", path: "Packages/ProductionEvals/Sources/ProductionEvals"),
        .executableTarget(name: "ProductionEvalsCLI", dependencies: ["ProductionEvals"]),
        .target(name: "FoundationEvalsDeveloper", dependencies: ["ProductionEvals"]),
        .testTarget(name: "FoundationEvalsDeveloperTests", dependencies: ["FoundationEvalsDeveloper"]),
        .target(name: "MacIntentTesting"),
        .executableTarget(name: "MacIntentTestingCLI", dependencies: ["MacIntentTesting"]),
        .testTarget(name: "MacIntentTestingCLITests", dependencies: ["MacIntentTestingCLI"]),
        .testTarget(name: "MacIntentTestingTests", dependencies: ["MacIntentTesting"]),
        .target(name: "FoundationEvals", path: "FoundationEvals/FoundationEvals",
                exclude: excludedFiles(at: "FoundationEvals/FoundationEvals", keeping: portableProductionSources),
                sources: portableProductionSources),
        .target(name: "FoundationEvalsUIComponents", path: "FoundationEvals/FoundationEvals/Views/Components",
                exclude: excludedFiles(at: "FoundationEvals/FoundationEvals/Views/Components", keeping: ["SidebarNavigationList.swift", "FullWidthDisclosureStyle.swift", "SolidTimelineBar.swift", "RunToolbarProgress.swift"]),
                sources: ["SidebarNavigationList.swift", "FullWidthDisclosureStyle.swift", "SolidTimelineBar.swift", "RunToolbarProgress.swift"]),
        .testTarget(name: "FoundationEvalsPortableTests", dependencies: ["FoundationEvals", "FoundationEvalsUIComponents"],
                path: "FoundationEvals/FoundationEvalsTests",
                exclude: excludedFiles(at: "FoundationEvals/FoundationEvalsTests", keeping: portableTestSources),
                sources: portableTestSources),
    ]
)
