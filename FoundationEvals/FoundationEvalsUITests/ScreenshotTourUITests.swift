import XCTest

/// Opt-in visual tour. Set TOUR_DATA to a disposable workspace fixture to walk
/// the main screens and save screenshots; regular CI skips when no fixture exists.
final class ScreenshotTourUITests: XCTestCase {
    private let root = URL(filePath: "/private/tmp/foundation-evals-ui-tests", directoryHint: .isDirectory)

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTourDark() throws { try tour(appearance: "dark") }

    @MainActor
    func testTourLight() throws { try tour(appearance: "light") }

    @MainActor
    func testTourNarrow() throws { try tour(appearance: "light", width: 1000, height: 700) }

    /// Reproduces the default-size window the regular UI tests use, with a fresh workspace.
    @MainActor
    func testDefaultSizeCases() throws {
        let storageName = UUID().uuidString
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/FoundationEvalsUITests/\(storageName)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: storage) }
        try FileManager.default.createDirectory(at: root.appending(path: "Screenshots"), withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage-name", storageName]
        app.launch()
        defer { app.terminate() }
        app.activate()
        app.menuBars.menuBarItems["Evaluation"].click()
        app.menuItems["Show Suite Editor"].click()
        let add = app.buttons["Add Case"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        print("PROBE window=\(app.windows.firstMatch.frame) addCase=\(add.frame) hittable=\(add.isHittable)")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: root.appending(path: "Screenshots/probe-default-cases.png"))

        let prompt = app.textViews["Case prompt"]
        prompt.click()
        prompt.typeKey("a", modifierFlags: .command)
        prompt.typeText("Why is the sky blue?\nExplain it in two short paragraphs.\nUse plain language.")
        Thread.sleep(forTimeInterval: 1)
        print("PROBE after typing window=\(app.windows.firstMatch.frame) prompt=\(prompt.frame) addCase=\(add.frame) hittable=\(add.isHittable)")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(
            to: root.appending(path: "Screenshots/probe-after-typing.png"))
    }

    @MainActor
    private func tour(appearance: String, width: Int = 1300, height: Int = 850) throws {
        let source = URL(filePath: ProcessInfo.processInfo.environment["TOUR_DATA"] ?? root.appending(path: "tour-data").path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Copy a workspace to \(source.path) before running the tour")
        }
        let data = root.appending(path: "tour-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: data)
        defer { try? FileManager.default.removeItem(at: data) }
        let label = (ProcessInfo.processInfo.environment["TOUR_LABEL"] ?? "shot") + (width == 1000 ? "-narrow" : "")
        let app = XCUIApplication()
        app.launchArguments += [
            "--disable-mcp-autostart", "--evaluation-storage", data.path,
            "--evaluation-window-width", String(width), "--evaluation-window-height", String(height)
        ]
        app.launchArguments += appearance == "dark"
            ? ["-AppleInterfaceStyle", "Dark"]
            : ["-NSRequiresAquaSystemAppearance", "YES"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        func shot(_ name: String) {
            Thread.sleep(forTimeInterval: 1.2)
            let directory = root.appending(path: "Screenshots", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(label)-\(appearance)-\(name).png")
            do {
                try window.screenshot().pngRepresentation.write(to: url, options: .atomic)
                try app.debugDescription.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            } catch { XCTFail("Could not save screenshot: \(error)") }
            XCTAssertLessThanOrEqual(window.frame.height, CGFloat(height + 100), "Navigation must not grow the window off screen: \(name)")
        }
        func tap(_ element: XCUIElement) {
            guard element.waitForExistence(timeout: 4) else { XCTFail("Missing tour control: \(element)"); return }
            element.click()
        }

        tap(app.outlines.staticTexts["Overview"].firstMatch)
        shot("01-overview")
        let newSuite = app.buttons["New Suite"].firstMatch
        if newSuite.waitForExistence(timeout: 3) {
            newSuite.click()
            if app.sheets.firstMatch.waitForExistence(timeout: 3) {
                shot("01b-new-suite-sheet")
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        app.typeKey("1", modifierFlags: .command)
        tap(app.radioButtons["Cases"])
        shot("02-suite-cases")
        tap(app.radioButtons["Setup"])
        shot("03-suite-setup")
        for (index, page) in ["Scoring", "Model", "Tools", "Structured output", "Session profile", "Performance"].enumerated() {
            let menu = app.popUpButtons["Suite setup"]
            if menu.exists { menu.click(); tap(app.menuItems[page].firstMatch) }
            else { tap(app.buttons[page].firstMatch) }
            shot("03\(Character(UnicodeScalar(97 + index)!))-setup-\(page.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        tap(app.radioButtons["History"])
        shot("04-suite-history")

        let runRow = app.outlines.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] 'passed' OR value CONTAINS[c] 'issue'")).firstMatch
        tap(runRow)
        tap(app.radioButtons["Report"])
        shot("05-run-report")
        let scroll = app.scrollViews["Run report scroll"]
        if scroll.exists {
            scroll.scroll(byDeltaX: 0, deltaY: -520)
            shot("06-run-report-results")
        }
        tap(app.radioButtons["Performance"])
        shot("06b-run-performance")
        tap(app.radioButtons["Review & release"])
        shot("06c-run-review")
        tap(app.radioButtons["Workflow trace"])
        shot("07-run-trace")

        app.typeKey("2", modifierFlags: .command)
        tap(app.radioButtons["Connect app"])
        shot("08-intent-lab-connect")
        tap(app.radioButtons["Create test"])
        shot("09-intent-lab-create")
        tap(app.radioButtons["Results"])
        shot("10-intent-lab-results")

        tap(app.outlines.descendants(matching: .any)["Sidebar evaluations"].firstMatch)
        shot("11-evaluations")
        tap(app.outlines.descendants(matching: .any)["Sidebar batch runs"].firstMatch)
        shot("12-batch-runs")
        tap(app.outlines.descendants(matching: .any)["Sidebar traces"].firstMatch)
        shot("13-traces")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.element(boundBy: 0)
        if settings.waitForExistence(timeout: 3) {
            Thread.sleep(forTimeInterval: 1)
            let directory = root.appending(path: "Screenshots", directoryHint: .isDirectory)
            try? settings.screenshot().pngRepresentation.write(
                to: directory.appending(path: "\(label)-\(appearance)-12-settings.png"), options: .atomic)
        }
    }
}
