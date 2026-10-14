import XCTest
@testable import IntentsAutomationCore

final class AutomationHostTests: XCTestCase {
    func testDigestVersionIsCorrelatedInPayloadAndReceiptWithoutChangingOldWireShape() throws {
        let program = AutomationHostProgram(operations: [.init(id: "find", kind: .invoke, typeID: "FindIntent", resultCodec: "noValue")])
        let old = try JSONDecoder().decode(AutomationJSON.self, from: program.payload(scope: scope, app: app, route: .systemIntent, phase: .subject))
        XCTAssertNil(old.object?["productDigestVersion"])
        var linked = app; linked.productDigestVersion = 2
        let payload = try JSONDecoder().decode(AutomationJSON.self, from: program.payload(scope: scope, app: linked, route: .systemIntent, phase: .subject))
        XCTAssertEqual(payload.object?["productDigestVersion"], .number(2))
        var receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": 123, "startIdentity": "123456:100", "executablePath": "/owned/Host.app/Host"],
            "runID": "run", "attemptID": "attempt", "segmentID": "subject", "leaseGeneration": 2, "bundleID": app.bundleID,
            "productDigest": app.productDigest!, "productDigestVersion": 2, "complete": true,
            "operations": [["operationID": "find", "dispatched": true, "value": ["kind": "noValue"]]]]
        func read(_ identity: AppIdentity) throws -> AutomationImportedHostReceipt {
            try AutomationHostReceiptImporter.importReceipt(JSONSerialization.data(withJSONObject: receipt), scope: scope, app: identity, program: program)
        }
        XCTAssertNoThrow(try read(linked))
        XCTAssertThrowsError(try read(app))
        receipt["productDigestVersion"] = 1; XCTAssertThrowsError(try read(linked))
        receipt.removeValue(forKey: "productDigestVersion"); XCTAssertThrowsError(try read(linked))
        XCTAssertNoThrow(try read(app))
    }
    private let app = AppIdentity(logicalID: "app", bundleID: "com.example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
    func testApplePayloadIsTypedDataAndUnknownSettersNeverDispatch() throws {
        let program = AutomationHostProgram(operations: [.init(id: "find", kind: .invoke, typeID: "FindIntent", parameters: ["query": .text("quotes \" / newline\n"), "optional": .omission, "number": .integer("9223372036854775807")], resultCodec: "noValue")])
        let data = try program.payload(scope: scope, app: app, route: .systemIntent, phase: .subject)
        let value = try JSONDecoder().decode(AutomationJSON.self, from: data)
        XCTAssertEqual(value.object?["leaseGeneration"], .number(2))
        for unsupported in [AutomationValue.integer("9223372036854775808"), .date("2026-10-06", timeZone: "UTC"), .array([.integer("1")])] {
            XCTAssertThrowsError(try AutomationHostProgram(operations: [.init(id: "op", kind: .invoke, typeID: "Intent", parameters: ["input": unsupported])]).validate(route: .systemIntent, phase: .subject))
        }
        XCTAssertThrowsError(try program.validate(route: .systemIntent, phase: .observe))
        XCTAssertThrowsError(try AutomationHostProgram(operations: [.init(id: "query", kind: .query, typeID: "Entity", queryText: "text", queryIDs: ["id"])]).validate(route: .systemQuery, phase: .observe))
    }
    func testCorrelatedCompletedReceiptDoesNotAcceptWrongScopeOrDuplicateOperations() throws {
        let program = AutomationHostProgram(operations: [.init(id: "find", kind: .invoke, typeID: "FindIntent", resultCodec: "noValue")])
        var receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": 123, "startIdentity": "123456:100", "executablePath": "/owned/Host.app/Host"],
            "runID": "run", "attemptID": "attempt", "segmentID": "subject", "leaseGeneration": 2, "bundleID": app.bundleID, "productDigest": app.productDigest!,
            "complete": true, "operations": [["operationID": "find", "dispatched": true, "value": ["kind": "noValue"]]]]
        func imported() throws -> AutomationImportedHostReceipt { try AutomationHostReceiptImporter.importReceipt(JSONSerialization.data(withJSONObject: receipt), scope: scope, app: app, program: program) }
        XCTAssertEqual(try imported().values, ["find": .omission]); XCTAssertEqual(try imported().runner.pid, 123)
        receipt["attemptID"] = "old"; XCTAssertThrowsError(try imported()); receipt["attemptID"] = "attempt"
        receipt["complete"] = false; XCTAssertThrowsError(try imported()); receipt["complete"] = true
        let operations = receipt["operations"] as! [[String: Any]]; receipt["operations"] = operations + operations; XCTAssertThrowsError(try imported())
    }
    func testHostFileFreezesTheCurrentLeaseAndRejectsAdditionalTargets() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let host = root.appendingPathComponent("Host.app")
        let subject = root.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let target: [String: Any] = ["BlueprintName": "OwnedHost", "TestHostPath": "__TESTROOT__/Host.app", "TestBundlePath": "__TESTHOST__/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app", "IsUITestBundle": true]
        let original: [String: Any] = ["OwnedHost": target, "__xctestrun_metadata__": ["FormatVersion": 1]]
        let frozen = try AutomationAppleHostFile.freeze(original, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: "OwnedHost", payload: Data("current lease".utf8))
        let environment = (frozen["OwnedHost"] as? [String: Any])?["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(environment?["INTENTS_AUTOMATION_HOST_PLAN_B64"], Data("current lease".utf8).base64EncodedString())
        var wrong = target; wrong["UITargetAppPath"] = "__TESTROOT__/Host.app"
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(["OwnedHost": wrong], testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: "OwnedHost", payload: Data()))
        wrong = target; wrong["TestBundlePath"] = "__TESTHOST__/PlugIns/../../Foreign.xctest"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Foreign.xctest"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(["OwnedHost": wrong], testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: "OwnedHost", payload: Data()))

        var extra = original; extra["OtherHost"] = target
        XCTAssertThrowsError(try AutomationAppleHostFile.freeze(extra, testRoot: root, expectedHost: host, expectedSubject: subject, testTarget: "OwnedHost", payload: Data()))
    }
}


extension AutomationHostTests {
    func testDestinationArtifactsKeepTheInstalledSubjectAndValidatePreparedPaths() throws {
        let root = URL(fileURLWithPath: "/private/tmp/destination-artifacts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("Host.app"), subject = root.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        let target: [String: Any] = ["BlueprintName": "OwnedHost", "TestHostPath": "__TESTROOT__/Host.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app", "IsUITestBundle": true]
        for configurationFormat in [false, true] {
            let source: [String: Any] = configurationFormat ? ["TestConfigurations": [["TestTargets": [target]]]] : ["OwnedHost": target]
            func onlyTarget(_ value: [String: Any]) throws -> [String: Any] {
                if configurationFormat {
                    let configurations = try XCTUnwrap(value["TestConfigurations"] as? [[String: Any]])
                    return try XCTUnwrap((configurations[0]["TestTargets"] as? [[String: Any]])?.first)
                }
                return try XCTUnwrap(value["OwnedHost"] as? [String: Any])
            }
            let frozen = try AutomationAppleHostFile.freeze(source, testRoot: root, expectedHost: host,
                expectedSubject: subject, testTarget: "OwnedHost", payload: Data(),
                destinationBundleIDs: ("example.Host.xctrunner", "example.Subject"))
            let installed = try onlyTarget(frozen)
            XCTAssertEqual(installed["UseDestinationArtifacts"] as? Bool, true)
            XCTAssertEqual(installed["TestHostBundleIdentifier"] as? String, "example.Host.xctrunner")
            XCTAssertEqual(installed["UITargetAppBundleIdentifier"] as? String, "example.Subject")
            XCTAssertEqual(installed["TestBundleDestinationRelativePath"] as? String, "__TESTHOST__/PlugIns/OwnedHost.xctest")
            for key in ["TestBundlePath", "TestHostPath", "UITargetAppPath"] { XCTAssertNil(installed[key]) }
            let physical = try onlyTarget(AutomationAppleHostFile.freeze(source, testRoot: root, expectedHost: host,
                expectedSubject: subject, testTarget: "OwnedHost", payload: Data(), platform: .physicalIOS))
            XCTAssertNil(physical["UseDestinationArtifacts"])
            XCTAssertEqual(physical["UITargetAppPath"] as? String, subject.path)
            XCTAssertEqual(physical["TestHostPath"] as? String, host.path)
            XCTAssertEqual(physical["TestBundlePath"] as? String, host.path + "/PlugIns/OwnedHost.xctest")
            XCTAssertThrowsError(try AutomationAppleHostFile.freeze(source, testRoot: root, expectedHost: host,
                expectedSubject: host, testTarget: "OwnedHost", payload: Data(),
                destinationBundleIDs: ("example.Host.xctrunner", "example.Subject")))
            #if os(macOS)
            for kind in [TargetIdentity.Kind.simulator, .physical] {
                let prepared = AutomationPreparedAppleHost(app: .init(logicalID: "app", bundleID: "example.Subject", platform: "ios"),
                    target: .init(id: "target", kind: kind), xctestrunPath: root.appendingPathComponent("host.xctestrun").path,
                    xctestrunDigest: "unused", subjectProductPath: subject.path, hostBundlePath: host.path,
                    hostProductDigest: "unused", hostBundleID: "example.Host.xctrunner", testTarget: "OwnedHost")
                let uiTarget = try onlyTarget(AutomationXCUITestRouteDriver.freeze(source, prepared: prepared, payload: Data()))
                XCTAssertEqual(uiTarget["UseDestinationArtifacts"] as? Bool, kind == .simulator ? true : nil)
                let environment = try XCTUnwrap(uiTarget["EnvironmentVariables"] as? [String: String])
                XCTAssertNotNil(environment["INTENTS_AUTOMATION_UI_PLAN_B64"])
                XCTAssertNil(environment["INTENTS_AUTOMATION_HOST_PLAN_B64"])
            }
            #endif
        }
    }
}
