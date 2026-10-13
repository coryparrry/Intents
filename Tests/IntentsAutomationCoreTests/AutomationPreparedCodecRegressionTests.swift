#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedCodecRegressionTests: XCTestCase {
    struct Fixture {
        let root: URL
        let prepared: AutomationPreparedApplication
        let plan: AutomationCase
        let approval: RunApproval
    }

    func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/prepared-codec-regression-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Self.makeFixture(root: root)
    }

    static func makeFixture(root requestedRoot: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        let root = try AutomationPath.canonical(requestedRoot)
        let source = root.appendingPathComponent("original"), project = source.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let objects: [String: Any] = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "MAIN", "productRefGroup": "PRODUCTS", "targets": ["APP"], "buildConfigurationList": "PROJECT_CONFIGS"],
            "MAIN": ["isa": "PBXGroup", "children": ["PRODUCTS"]], "PRODUCTS": ["isa": "PBXGroup", "children": [String]()],
            "APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "APP_CONFIGS"],
            "APP_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["APP_CONFIG"]],
            "APP_CONFIG": ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [String: String]()],
            "PROJECT_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["PROJECT_CONFIG"]],
            "PROJECT_CONFIG": ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [String: String]()]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["rootObject": "ROOT", "objects": objects], format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        var generated = try AutomationHostGenerator.associate(sessionRoot: session, projectRelativePath: "Subject.xcodeproj",
            subjectTargetID: "APP", configuration: "Debug", subjectPlatform: "ios", templates: templates)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("generated-host/" + generated.scheme + "/Sources/UIStepTests.swift").path))
        let products = session.appendingPathComponent("DerivedData/Build/Products")
        let host = products.appendingPathComponent("Debug-iphonesimulator/" + generated.scheme + "-Runner.app")
        let subject = products.appendingPathComponent("Debug-iphonesimulator/Subject.app")
        for (bundle, id) in [(host, generated.bundleID), (subject, "example.Subject")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id,
                "CFBundleExecutable": "App", "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "DTPlatformName": "iphonesimulator"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
            try AutomationPhysicalExecutableTests.binary(platform: 7).write(to: bundle.appendingPathComponent("App"))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/" + generated.scheme + ".xctest"), withIntermediateDirectories: true)
        let entry: [String: Any] = ["BlueprintName": generated.scheme, "IsUITestBundle": true,
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/" + generated.scheme + "-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/" + generated.scheme + ".xctest", "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/Subject.app"]
        try PropertyListSerialization.data(fromPropertyList: [generated.scheme: entry, "__xctestrun_metadata__": ["FormatVersion": 1]], format: .xml, options: 0)
            .write(to: products.appendingPathComponent(generated.scheme + "_iphonesimulator27.0-arm64.xctestrun"))
        generated.subjectProductPath = subject.path; generated.subjectBundleID = "example.Subject"
        let hostRecord = try AutomationPreparation.resolve(products: products, generated: generated, target: .init(id: UUID().uuidString, kind: .simulator))
        let action = ApplicationSurfaceCatalog.SystemAction(id: "CompleteTaskIntent", typeName: "CompleteTaskIntent", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true, compiled: true, registered: false, executed: false)
        let catalog = ApplicationSurfaceCatalog(app: hostRecord.app, systemActions: [action], systemDiscoveryComplete: true,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: [:], propertyTitles: [:])])
        let prepared = AutomationPreparedApplication(source: manifest, generatedHost: generated, host: hostRecord, catalog: catalog,
            buildLogPath: session.appendingPathComponent("build.log").path, buildLogTruncated: false)
        var plan = AutomationCase(id: "current-template-entity", app: hostRecord.app, target: hostRecord.target, environmentID: "test",
            execution: .init(id: "complete", kind: .systemIntent, phase: .subject, operation: "Complete task",
                requiredCapabilities: ["apple.codec.entity"], effects: [.observe], lifecycle: .persistedStateAcrossSegments))
        plan.execution.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTaskIntent", parameters: ["task": .entity(typeID: "TaskEntity", value: "task-1")])])
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 1, disposable: true)
        return .init(root: root, prepared: prepared, plan: plan, approval: approval)
    }

    func testCurrentTemplatesIncludingUIStepsAdmitEntityPlanWithoutSuppliedCapabilities() async throws {
        let h = try fixture()
        let runner = try AutomationApplicationRunner(supportRoot: h.root.appendingPathComponent("attempts"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertFalse(AutomationPreparedCapabilities.base(h.prepared).records.keys.contains { $0.hasPrefix("apple.codec.") })
        let capabilities = try await runner.capabilitiesForExecution(subject: .prepared(h.prepared), plan: h.plan, capabilities: .init())
        try PlanValidator.validate(h.plan, approval: h.approval, capabilities: capabilities)
    }

    func testDecodedPreparationGrantsEveryImplementedCodecWithoutRegistration() async throws {
        let h = try fixture()
        let decoded = try JSONDecoder().decode(AutomationPreparedApplication.self, from: JSONEncoder().encode(h.prepared))
        let capabilities = try await AutomationSimulatorCodecQualification.enrich(.init(), prepared: decoded)
        XCTAssertEqual(Set(capabilities.records.keys), Set(AutomationCodecRegistry.parameterFamilies.map { "apple.codec." + $0 }))
        XCTAssertFalse(capabilities.supports(["apple.codec.unimplemented"]))
        try PlanValidator.validate(h.plan, approval: h.approval, capabilities: capabilities)
    }

    func testExplicitVetoAndConsentSurviveDiskVerification() async throws {
        let h = try fixture()
        for state in [CapabilityProfile.State.unavailable, .consentRequired, .available] {
            let record = CapabilityProfile.Record(state: state, reason: "Caller decision", probeVersion: "caller", evidence: ["caller"])
            let capabilities = try await AutomationSimulatorCodecQualification.enrich(.init(records: ["apple.codec.entity": record]), prepared: h.prepared)
            XCTAssertEqual(capabilities.records["apple.codec.entity"], record)
        }
        let unknown = CapabilityProfile(records: ["apple.codec.entity": .init(state: .unknown, reason: "Unchecked", probeVersion: "test", evidence: [])])
        let enriched = try await AutomationSimulatorCodecQualification.enrich(unknown, prepared: h.prepared)
        XCTAssertTrue(enriched.supports(["apple.codec.entity"]))
    }

    func testChangedSubjectHostXctestrunAndGeneratedSourcesAreRejectedEvenWithCachedCapabilities() async throws {
        for artifact in ["subject", "host", "xctestrun", "source"] {
            let h = try fixture()
            let cached = try await AutomationSimulatorCodecQualification.enrich(.init(), prepared: h.prepared)
            let path: URL
            switch artifact {
            case "subject": path = URL(fileURLWithPath: h.prepared.host.subjectProductPath).appendingPathComponent("App")
            case "host": path = URL(fileURLWithPath: h.prepared.host.hostBundlePath).appendingPathComponent("App")
            case "xctestrun": path = URL(fileURLWithPath: h.prepared.host.xctestrunPath)
            default: path = URL(fileURLWithPath: h.prepared.buildLogPath).deletingLastPathComponent()
                .appendingPathComponent("generated-host/" + h.prepared.generatedHost.scheme + "/Sources/UIStepTests.swift")
            }
            try Data("modified".utf8).write(to: path)
            do {
                _ = try await AutomationSimulatorCodecQualification.enrich(cached, prepared: h.prepared)
                XCTFail("Modified \(artifact) admitted cached codecs")
            } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation, artifact) }
        }
    }

    func testDifferentApprovedSubjectCannotReusePreparedCapabilities() async throws {
        let h = try fixture()
        var foreign = h.plan; foreign.app.logicalID = "foreign"
        let runner = try AutomationApplicationRunner(supportRoot: h.root.appendingPathComponent("attempts"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        do {
            _ = try await runner.capabilitiesForExecution(subject: .prepared(h.prepared), plan: foreign, capabilities: .init())
            XCTFail("Different subject admitted")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
    }

}
#endif
