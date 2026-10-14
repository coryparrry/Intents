import XCTest

/// The committed fixture is staged in the shared UI-test sandbox before launch.
/// Opt-in configuration supplies only runtime destination and toolchain settings.
struct AutomationFixtureUITestSupport {
    static let iOSBundleID = "com.coryparry.IntentsAutomation.AutomationFixture"
    static let macBundleID = "com.coryparry.IntentsAutomation.AutomationFixtureMac"
    let project: URL
    let simulatorID: String?
    let developerDirectory: String?
    private let sourceBytes: [String: Data]

    init(requiresSimulator: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INTENTS_AUTOMATION_LIVE_UI"] == "1" else {
            throw XCTSkip("Opt in with INTENTS_AUTOMATION_LIVE_UI=1 and stage examples/AutomationFixture in the shared UI test root")
        }
        project = UITestStorage.root.appendingPathComponent("AutomationFixture/AutomationFixture.xcodeproj")
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path) else {
            throw NSError(domain: "AutomationFixtureUITests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Stage examples/AutomationFixture and generate AutomationFixture.xcodeproj at \(project.path) before running live UI tests"])
        }
        simulatorID = environment["INTENTS_AUTOMATION_SIMULATOR_UUID"]
        if requiresSimulator {
            guard let simulatorID, UUID(uuidString: simulatorID) != nil else {
                throw NSError(domain: "AutomationFixtureUITests", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "INTENTS_AUTOMATION_SIMULATOR_UUID must identify the disposable simulator owned by this test run"])
            }
        }
        developerDirectory = environment["INTENTS_AUTOMATION_DEVELOPER_DIR"] ?? environment["DEVELOPER_DIR"]
        sourceBytes = try Self.snapshot(project: project)
    }

    @MainActor
    func configure(_ app: XCUIApplication, storage: URL) {
        if let developerDirectory { app.launchEnvironment["DEVELOPER_DIR"] = developerDirectory }
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
            "--automation-select-path", project.path,
            "--automation-xcode-settings-suite", "automation-fixture-ui-" + UUID().uuidString,
            "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
    }

    func assertSourceUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Self.snapshot(project: project), sourceBytes,
                       "The staged fixture must remain unchanged", file: file, line: line)
    }

    private static func snapshot(project: URL) throws -> [String: Data] {
        let root = project.deletingLastPathComponent()
        var bytes = ["AutomationFixture.xcodeproj/project.pbxproj": try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where ["swift", "xcscheme"].contains(file.pathExtension) || file.lastPathComponent == "project.yml" {
            bytes[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        XCTAssertTrue(bytes.keys.contains { $0.hasSuffix("TaskIntents.swift") }, "The staged fixture must contain its task intents")
        return bytes
    }
}
