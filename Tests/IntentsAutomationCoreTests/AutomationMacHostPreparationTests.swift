#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacHostPreparationTests: XCTestCase, @unchecked Sendable {
    private let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "mac-gui-v1:501:42:none")
    func testSelectedProductAcceptsOnlyAliasOfTheSameActualProject() throws {
        let root = URL(fileURLWithPath: "/private/tmp/product-alias-" + UUID().uuidString)
        let project = root.appendingPathComponent("Subject.xcodeproj"), products = root.appendingPathComponent("Products")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = ["TARGET_NAME": "Subject", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": project.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"),
                        "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx",
                        "TARGET_BUILD_DIR": products.path + "/Debug", "FULL_PRODUCT_NAME": "Subject.app", "PRODUCT_BUNDLE_IDENTIFIER": "example.Subject"]
        func bytes() throws -> Data { try JSONSerialization.data(withJSONObject: [["target": "Subject", "buildSettings": settings]]) }
        let platform = try AutomationBuildPlatform.read(bytes(), project: project, targetName: "Subject", configuration: "Debug",
            developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(try AutomationAssociatedHostPlatform.subjectProduct(bytes(), platform: platform, products: products).path, products.path + "/Debug/Subject.app")
        settings["PROJECT_FILE_PATH"] = root.appendingPathComponent("Missing.xcodeproj").path
        XCTAssertThrowsError(try AutomationAssociatedHostPlatform.subjectProduct(bytes(), platform: platform, products: products))
    }
    func testSelectedProductSettingsRequireExactTargetAndOwnedDirectory() throws {
        let products = URL(fileURLWithPath: "/private/tmp/owned/DerivedData/Build/Products")
        let project = URL(fileURLWithPath: "/private/tmp/owned/source/Subject.xcodeproj")
        let settings = ["TARGET_NAME": "Subject", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": project.path,
                        "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx",
                        "TARGET_BUILD_DIR": products.path + "/Debug", "FULL_PRODUCT_NAME": "Subject.app", "PRODUCT_BUNDLE_IDENTIFIER": "example.Subject"]
        func bytes(_ values: [String: String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [["target": "Subject", "buildSettings": values]])
        }
        let platform = try AutomationBuildPlatform.read(bytes(settings), project: project, targetName: "Subject", configuration: "Debug",
            developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        let selected = try AutomationAssociatedHostPlatform.subjectProduct(bytes(settings), platform: platform, products: products)
        XCTAssertEqual(selected.path, products.path + "/Debug/Subject.app"); XCTAssertEqual(selected.bundleID, "example.Subject")
        for (key, value) in [("TARGET_NAME", "Foreign"), ("CONFIGURATION", "Release"), ("PROJECT_FILE_PATH", "/foreign/Subject.xcodeproj"),
                             ("TARGET_BUILD_DIR", "/foreign/Products/Debug"), ("TARGET_BUILD_DIR", products.path + "/Debug/../Foreign"),
                             ("FULL_PRODUCT_NAME", "../Foreign.app"), ("PRODUCT_BUNDLE_IDENTIFIER", "$(UNRESOLVED)")] {
            var changed = settings; changed[key] = value
            XCTAssertThrowsError(try AutomationAssociatedHostPlatform.subjectProduct(bytes(changed), platform: platform, products: products))
        }
        let row: [String: Any] = ["target": "Subject", "buildSettings": settings]
        XCTAssertThrowsError(try AutomationAssociatedHostPlatform.subjectProduct(JSONSerialization.data(withJSONObject: [row, row]), platform: platform, products: products))
    }
    private func fixture() throws -> (URL, AutomationGeneratedHost, URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/mac-host-products-" + UUID().uuidString)
        let host = root.appendingPathComponent("Debug/Host-Runner.app"), subject = root.appendingPathComponent("Debug/Subject.app")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (bundle, id) in [(host, "example.Host.xctrunner"), (subject, "example.Subject")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleExecutable": "Subject", "CFBundleSupportedPlatforms": ["MacOSX"]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Contents/MacOS/Subject"))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents/PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "IsUITestBundle": true, "TestHostPath": "__TESTROOT__/Debug/Host-Runner.app",
                                  "TestBundlePath": "__TESTHOST__/Contents/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Debug/Subject.app"]
        try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry, "__xctestrun_metadata__": ["FormatVersion": 1]], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("OwnedHost_macosx27.0-arm64.xctestrun"))
        let generated = AutomationGeneratedHost(projectPath: "unused", scheme: "OwnedHost", targetID: "HOST", bundleID: "example.Host.xctrunner", configuration: "Debug", templateDigest: String(repeating: "a", count: 64), subjectProductPath: subject.path, subjectBundleID: "example.Subject")
        return (root, generated, host, subject)
    }
    func testMacLayoutAndVersionedFrameworkDigestRoundTrip() throws {
        let (root, generated, host, _) = try fixture()
        let framework = host.appendingPathComponent("Contents/Frameworks/Example.framework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: framework.appendingPathComponent("Versions/A/Example"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Example").path, withDestinationPath: "Versions/Current/Example")
        let prepared = try AutomationPreparation.resolve(products: root, generated: generated, target: target)
        XCTAssertEqual(prepared.hostProductDigestVersion, 2); XCTAssertEqual(prepared.app.productDigestVersion, 2)
        XCTAssertEqual(prepared.app.platform, "macos")
        XCTAssertEqual(prepared.hostProductDigest, try AutomationProductDigest.compute(bundle: host, version: 2))
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: host))
        XCTAssertEqual(try JSONDecoder().decode(AutomationPreparedAppleHost.self, from: JSONEncoder().encode(prepared)), prepared)
        var old = prepared; old.hostProductDigestVersion = nil
        let bytes = try JSONEncoder().encode(old)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(fields["hostProductDigestVersion"])
        XCTAssertNil(try JSONDecoder().decode(AutomationPreparedAppleHost.self, from: bytes).hostProductDigestVersion)
        XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: .init(id: UUID().uuidString, kind: .simulator)))
    }
    func testMacLayoutCannotReplaceIOSLayoutOrEscapeRunner() throws {
        let (root, generated, host, subject) = try fixture()
        let file = root.appendingPathComponent("OwnedHost_macosx27.0-arm64.xctestrun")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(plist, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: generated.scheme, payload: Data()))
        for path in ["__TESTHOST__/PlugIns/OwnedHost.xctest", "__TESTHOST__/Contents/PlugIns/../../Foreign.xctest", "__TESTROOT__/Foreign.xctest"] {
            var changed = plist, entry = try XCTUnwrap(plist[generated.scheme] as? [String: Any]); entry["TestBundlePath"] = path; changed[generated.scheme] = entry
            XCTAssertThrowsError(try AutomationAppleHostFile.freeze(changed, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: generated.scheme, payload: Data(), platform: .macOS))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents/PlugIns/Foreign.xctest"), withIntermediateDirectories: true)
        var foreignBundle = plist, foreignEntry = try XCTUnwrap(plist[generated.scheme] as? [String: Any])
        foreignEntry["TestBundlePath"] = "__TESTHOST__/Contents/PlugIns/Foreign.xctest"; foreignBundle[generated.scheme] = foreignEntry
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(foreignBundle, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: generated.scheme, payload: Data(), platform: .macOS))
        var extra = plist; extra["ForeignHost"] = plist[generated.scheme]
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(extra, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: generated.scheme, payload: Data(), platform: .macOS))
    }
    func testWrongHostSubjectPlatformsAndPhysicalPreparationFailClosed() throws {
        let (root, generated, host, subject) = try fixture()
        XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: .init(id: "device", kind: .physical)))
        XCTAssertThrowsError(try AutomationAssociatedHostPlatform(target: .init(id: "foreign", kind: .nativeMac, loginSession: target.loginSession)))
        XCTAssertThrowsError(try AutomationAssociatedHostPlatform(target: .init(id: target.id, kind: .nativeMac)))
        for bundle in [host, subject] {
            let file = bundle.appendingPathComponent("Contents/Info.plist"), original = try Data(contentsOf: file)
            var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
            info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file)
            XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: target))
            try original.write(to: file)
        }
        var other = generated; other.bundleID = "example.Foreign"
        XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: other, target: target))
        let foreign = root.appendingPathComponent("Debug/Foreign.app")
        try FileManager.default.copyItem(at: subject, to: foreign)
        let testFile = root.appendingPathComponent("OwnedHost_macosx27.0-arm64.xctestrun")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: testFile), format: nil) as? [String: Any])
        var entry = try XCTUnwrap(plist[generated.scheme] as? [String: Any]); entry["UITargetAppPath"] = "__TESTROOT__/Debug/Foreign.app"; plist[generated.scheme] = entry
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: testFile)
        XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: target))
    }
    func testExplicitStopDuringSyntaxPreparationCannotFallBackIntoBuilding() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["INTENTS_MAC_HOST_SOURCE"],
              let outputPath = ProcessInfo.processInfo.environment["INTENTS_MAC_HOST_PREPARATION_ROOT"] else {
            throw XCTSkip("Opt in to an owned cancellation fixture; no app or intent is launched")
        }
        let source = URL(fileURLWithPath: sourcePath), root = URL(fileURLWithPath: outputPath)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(source.appendingPathComponent("Subject.xcodeproj")).candidates.first)
        let current = try AutomationMacGUIIdentity.currentTarget()
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let session = root.appendingPathComponent("cancel-" + UUID().uuidString), preparation = AutomationPreparation()
        let task = Task {
            try await preparation.prepare(candidate: candidate,
                approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: current),
                sessionRoot: session, templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        }
        let scannerSource = session.appendingPathComponent("source-syntax/Scanner.swift")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: scannerSource.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedScanner = FileManager.default.fileExists(atPath: scannerSource.path)
        let drained = await preparation.cancel()
        XCTAssertTrue(reachedScanner); XCTAssertTrue(drained)
        do { _ = try await task.value; XCTFail("Stop must not produce a prepared application") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected Stop outcome: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("platform-settings.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("DerivedData").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("prepared-application.json").path))
    }
    func testExplicitIntegerEntityPreparationBuildsAndCapturesMetadataWithoutLaunching() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["INTENTS_ENTITY_INTEGER_SOURCE"],
              let outputPath = ProcessInfo.processInfo.environment["INTENTS_ENTITY_INTEGER_ROOT"] else {
            throw XCTSkip("Opt in to the controlled integer-entity SDK fixture; no app or intent is launched")
        }
        let source = URL(fileURLWithPath: sourcePath), root = URL(fileURLWithPath: outputPath)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(source.appendingPathComponent("Subject.xcodeproj")).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: AutomationMacGUIIdentity.currentTarget()),
            sessionRoot: root.appendingPathComponent("prepare-" + UUID().uuidString), templates: templates,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        let entity = try XCTUnwrap(prepared.catalog.entities?.first { $0.typeID == "IntegerEntity" })
        XCTAssertEqual(entity.properties, ["title": "text", "sequence": "integer"])
        let action = try XCTUnwrap(prepared.catalog.systemActions.first { $0.id == "IntegerEntityIntent" })
        XCTAssertTrue(action.parametersComplete); XCTAssertFalse(prepared.catalog.systemDiscoveryComplete)
        let approval = RunApproval(runID: "integer-query", app: prepared.host.app, target: prepared.host.target,
            environmentID: "disposable", effects: [.observe], maximumActions: 10, disposable: true)
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Invoice", approval: approval)
        XCTAssertEqual(plan.execution.hostProgram?.operations.first?.properties?["sequence"], "integer")
        try AutomationFrozenCase(plan: plan).validate()
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
    }
    func testExplicitActualMacPreparationBuildsWithoutLaunching() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["INTENTS_MAC_HOST_SOURCE"],
              let outputPath = ProcessInfo.processInfo.environment["INTENTS_MAC_HOST_PREPARATION_ROOT"] else {
            throw XCTSkip("Opt in to an owned build-only Mac fixture; no app or intent is launched")
        }
        let source = URL(fileURLWithPath: sourcePath), root = URL(fileURLWithPath: outputPath)
        let intake = try AutomationApplicationIntake.assess(source.appendingPathComponent("Subject.xcodeproj"))
        let candidate = try XCTUnwrap(intake.candidates.first)
        let current = try AutomationMacGUIIdentity.currentTarget()
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let session = root.appendingPathComponent("prepare-" + UUID().uuidString)
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: current),
            sessionRoot: session, templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(prepared.host.target, current); XCTAssertEqual(prepared.host.app.platform, "macos")
        XCTAssertEqual(prepared.host.hostProductDigestVersion, 2); XCTAssertFalse(prepared.buildLogTruncated)
        let graph = try XCTUnwrap(prepared.sourceGraph)
        XCTAssertEqual(graph.schemaVersion, AutomationSourceGraph.currentSchemaVersion)
        XCTAssertEqual(graph.sourceManifestDigest, try prepared.source.digest)
        XCTAssertEqual(graph.targetID, candidate.targetID)
        XCTAssertEqual(prepared.catalog.sourceGraphDigest, try graph.digest)
        let syntax = try XCTUnwrap(prepared.sourceSyntax)
        let conditions = try XCTUnwrap(syntax.compilationConditions)
        XCTAssertEqual(conditions.configuration, "Debug")
        XCTAssertEqual(conditions.owner, graph.projectRelativePath + "#" + graph.targetID)
        XCTAssertEqual(conditions.settingsSHA256, AutomationArtifactRegistry.digest(try Data(contentsOf: session.appendingPathComponent("source-compilation-settings.json"))))
        XCTAssertEqual(prepared.host.app.sourceSyntaxIndexDigest, try syntax.digest)
        XCTAssertEqual(prepared.catalog.sourceSyntaxIndexDigest, try syntax.digest)
        XCTAssertTrue(syntax.declarations.contains { $0.name == "HostProbeIntent" })
        XCTAssertTrue(prepared.catalog.systemActions.contains { $0.sourceReconciliation == "syntaxCandidate" })
        XCTAssertTrue(graph.inputs.contains { $0.role == "explicitSwiftMembership" })
        XCTAssertFalse(prepared.catalog.systemDiscoveryComplete)
        if ProcessInfo.processInfo.environment["INTENTS_URL_CODEC_TEST"] == "1" {
            let input = try XCTUnwrap(prepared.catalog.systemActions.first { $0.id == "URLInputProbeIntent" })
            let parameter = try XCTUnwrap(input.parameters.first { $0.name == "url" })
            XCTAssertEqual(parameter.family, "url"); XCTAssertTrue(input.parametersComplete)
            XCTAssertEqual(try AutomationCodecRegistry.input("https://example.invalid/typed-url", parameter: parameter, catalog: prepared.catalog).value,
                           .object(["url": .text("https://example.invalid/typed-url")]))
            XCTAssertEqual(prepared.catalog.systemActions.first { $0.id == "URLResultProbeIntent" }?.resultFamily, "url")
            XCTAssertTrue(prepared.catalog.gaps.contains { $0.contains("runtime conversion qualification remain unavailable") })
        }
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        let settingsFile = session.appendingPathComponent("source-compilation-settings.json")
        let retainedSettings = try Data(contentsOf: settingsFile)
        try Data("altered settings".utf8).write(to: settingsFile)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        try retainedSettings.write(to: settingsFile)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.hostBundlePath), version: 2), prepared.host.hostProductDigest)
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
    }
}
#endif
