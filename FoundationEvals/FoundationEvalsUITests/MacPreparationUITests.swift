import XCTest
import CryptoKit

final class MacPreparationUITests: XCTestCase {
    /// Opt-in: builds only an explicitly supplied authored fixture, then saves an unexecuted draft.
    @MainActor
    func testSelectedToolchainPreparesMacCopyAndSavesReviewedDraft() throws {
        struct Profile: Decodable {
            let sourceProject: String
            let sourceDigest: String
            let projectDigest: String
            let developerDirectory: String
            let metadataGeneratorVersion: String
        }
        let profileURL = UITestStorage.root.appendingPathComponent("automation-native-mac-approved-profile.json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("Requires an explicitly approved private Mac fixture profile")
        }
        continueAfterFailure = false
        let profileData = try Data(contentsOf: profileURL)
        XCTAssertLessThanOrEqual(profileData.count, 16_384)
        let profile = try JSONDecoder().decode(Profile.self, from: profileData)
        let project = URL(fileURLWithPath: profile.sourceProject).resolvingSymlinksInPath()
        XCTAssertTrue(project.path.hasPrefix(UITestStorage.root.resolvingSymlinksInPath().path + "/"), project.path)
        XCTAssertEqual(project.lastPathComponent, "Subject.xcodeproj")
        let source = project.deletingLastPathComponent().appendingPathComponent("Subject.swift")
        let projectFile = project.appendingPathComponent("project.pbxproj")
        XCTAssertEqual(try digest(source), profile.sourceDigest)
        XCTAssertEqual(try digest(projectFile), profile.projectDigest)
        let storage = try UITestStorage.makeDirectory(prefix: "native-mac-preparation")
        print("NATIVE_MAC_PREPARATION_STORAGE=\(storage.path)")
        // Keep build provenance, saved draft and screenshots for inspection.
        let app = XCUIApplication()
        app.launchEnvironment["DEVELOPER_DIR"] = profile.developerDirectory
        app.launchArguments += ["--disable-mcp-autostart", "--evaluation-storage", storage.path,
                                "--evaluation-window-width", "1300", "--evaluation-window-height", "850"]
        app.launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let choose = app.buttons["Choose app…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15)); choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5)); path.typeText(project.path)
        app.typeKey(.return, modifierFlags: [])
        let panelChoose = app.buttons["Choose app"]
        XCTAssertTrue(panelChoose.waitForExistence(timeout: 5)); panelChoose.click()
        let destination = app.popUpButtons["Prepare for"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10), app.debugDescription); destination.click()
        app.menuItems["This Mac"].click()
        let prepare = app.buttons["Prepare app…"]
        XCTAssertTrue(prepare.isEnabled); prepare.click()
        let build = app.buttons["Build private copy"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        try capture(app, storage: storage, name: "build-review")
        build.click()
        let ready = app.staticTexts["Prepared a private Mac copy for inspection. Mac workflow execution is not available yet."]
        XCTAssertTrue(ready.waitForExistence(timeout: 300), app.debugDescription)

        let automation = storage.appendingPathComponent("Automation")
        let preparations = try FileManager.default.contentsOfDirectory(at: automation, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("prepare-") }
        XCTAssertEqual(preparations.count, 1)
        let prepared = try object(try XCTUnwrap(preparations.first).appendingPathComponent("prepared-application.json"))
        let host = try XCTUnwrap(prepared["host"] as? [String: Any])
        let product = URL(fileURLWithPath: try XCTUnwrap(host["subjectProductPath"] as? String))
        let metadata = try object(product.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata"))
        let generator = try XCTUnwrap(metadata["generator"] as? [String: Any])
        XCTAssertEqual(generator["version"] as? String, profile.metadataGeneratorVersion)

        let instruction = app.textFields["What should the app do?"]
        instruction.click(); instruction.typeText("Show the input adapter fixture")
        let endpoint = app.textFields["Visible label at the destination"]
        endpoint.click(); endpoint.typeText("Intents input adapter fixture")
        app.popUpButtons["Effects of this workflow"].click()
        app.menuItems["Observation and navigation"].click()
        app.checkBoxes["I confirm this workflow stays within these effects"].click()
        let review = app.buttons["Review Mac workflow…"]
        XCTAssertTrue(review.isEnabled); review.click()
        let save = app.buttons["Save draft"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.staticTexts["This draft has no execution result. Saving it does not approve or run the app."].exists)
        try capture(app, storage: storage, name: "workflow-review")
        save.click()
        XCTAssertTrue(app.staticTexts["Mac workflow draft saved. It has no execution result or approval."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Run workflow…"].exists)
        try capture(app, storage: storage, name: "saved-draft")
        XCTAssertEqual(try digest(source), profile.sourceDigest)
        XCTAssertEqual(try digest(projectFile), profile.projectDigest)
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    @MainActor
    private func capture(_ app: XCUIApplication, storage: URL, name: String) throws {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try screenshot.pngRepresentation.write(to: storage.appendingPathComponent(name + ".png"))
    }
}
