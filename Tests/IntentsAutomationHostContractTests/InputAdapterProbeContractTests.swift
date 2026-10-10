#if os(macOS)
import Foundation
import XCTest
import IntentsAutomationDateCodec
@testable import IntentsAutomationHostContracts
@testable import IntentsAutomationCore

final class InputAdapterProbeContractTests: XCTestCase, @unchecked Sendable {
    private let scope = AutomationScope(runID: "run", attemptID: "probe", segmentID: "input-adapter", leaseGeneration: 2)
    private let families = ["text", "bool", "integer", "decimal", "date", "url", "duration", "calendarComponents",
                            "textArray", "boolArray", "integerArray", "decimalArray", "dateArray"]
    private func prepared(family: String = "text") -> AutomationPreparedApplication {
        var app = AppIdentity(logicalID: "synthetic", bundleID: "example.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "Subject.Probe", typeName: "Probe", title: "Probe",
            parameters: [.init(name: "sample", family: family, optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let host = AutomationPreparedAppleHost(app: app, target: .init(id: "synthetic-mac", kind: .nativeMac, loginSession: "synthetic"),
            xctestrunPath: "/private/tmp/probe.xctestrun", xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "/private/tmp/Subject.app",
            hostBundlePath: "/private/tmp/Host-Runner.app", hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host", testTarget: "Host", hostProductDigestVersion: 2)
        return .init(source: .init(sourceRoot: "/private/tmp/source", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "project", scheme: "Host", targetID: "Host", bundleID: host.hostBundleID, configuration: "Debug", templateDigest: String(repeating: "d", count: 64)),
            host: host, catalog: catalog, buildLogPath: "/private/tmp/build.log", buildLogTruncated: false)
    }
    private func plan(family: String = "text") throws -> AutomationInputAdapterProbePlan {
        try .init(prepared: prepared(family: family), actionID: "Subject.Probe", parameterNames: ["sample"])
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func receipt(_ plan: AutomationInputAdapterProbePlan) throws -> [String: Any] {
        var fields = try object(plan.payload(scope: scope))
        fields["runner"] = ["pid": 123, "startIdentity": "123:0", "executablePath": plan.prepared.host.hostBundlePath + "/Contents/MacOS/Host-Runner"]
        fields["complete"] = true
        return fields
    }
    func testAllFixedFamiliesCrossNativeAndHostContractsAndImportExactEchoes() throws {
        for family in families {
            let plan = try plan(family: family), host = try HostInputAdapterProbePlan.decode(plan.payload(scope: scope))
            XCTAssertEqual(host.purpose, "inputAdapterRoundTrip"); XCTAssertEqual(host.parameters[0].family, family)
            XCTAssertEqual(host.parameters[0].samples, try HostInputAdapterProbePlan.samples(family: family))
            let observation = try AutomationInputAdapterProbeObservation.read(data(receipt(plan)), plan: plan, scope: scope)
            XCTAssertEqual(observation.echoedSamples["sample"], plan.parameters[0].samples); XCTAssertNil(observation.runtimeObservation)
            XCTAssertEqual(observation.receiptDigest.count, 64)
            if family.hasSuffix("Array") { XCTAssertEqual(plan.parameters[0].samples.count, 2) }
        }
    }
    func testCanaryCannotBeImportedAsBusinessReceiptOrBecomeAnOrdinaryOperation() throws {
        let probe = try plan()
        let business = AutomationHostProgram(operations: [.init(id: "sample", kind: .invoke, typeID: "Subject.Probe", parameters: ["sample": .text("Intents adapter probe")], resultCodec: "noValue")])
        XCTAssertThrowsError(try AutomationHostReceiptImporter.importReceipt(data(receipt(probe)), scope: scope, app: probe.prepared.host.app, program: business))
        let ordinary = try business.payload(scope: scope, app: probe.prepared.host.app, route: .systemIntent, phase: .subject)
        XCTAssertThrowsError(try HostInputAdapterProbePlan.decode(ordinary))
        XCTAssertThrowsError(try JSONDecoder().decode(HostPlan.self, from: probe.payload(scope: scope)))
    }
    func testProbeSelectionRejectsForeignOrUnsupportedCatalogParameters() throws {
        for family in ["entity", "enum", "object", "file", "unknown", "null", "omission", "nestedArray"] {
            XCTAssertThrowsError(try plan(family: family))
        }
        let original = prepared()
        for names in [[], ["sample", "sample"], ["missing"], Array(repeating: "sample", count: 11)] {
            XCTAssertThrowsError(try AutomationInputAdapterProbePlan(prepared: original, actionID: "Subject.Probe", parameterNames: names))
        }
        XCTAssertThrowsError(try AutomationInputAdapterProbePlan(prepared: original, actionID: "Foreign.Probe", parameterNames: ["sample"]))
        var changed = original; changed.catalog.app.bundleID = "foreign"
        XCTAssertThrowsError(try AutomationInputAdapterProbePlan(prepared: changed, actionID: "Subject.Probe", parameterNames: ["sample"]))
        changed = original; changed.catalog.systemActions[0].parametersComplete = false
        XCTAssertThrowsError(try AutomationInputAdapterProbePlan(prepared: changed, actionID: "Subject.Probe", parameterNames: ["sample"]))
        changed = original; changed.host.target.kind = .simulator
        XCTAssertThrowsError(try AutomationInputAdapterProbePlan(prepared: changed, actionID: "Subject.Probe", parameterNames: ["sample"]))
    }
    func testHostRejectsChangedSamplesUnknownFieldsAndMalformedScope() throws {
        let plan = try plan(), original = try object(plan.payload(scope: scope))
        var variants: [[String: Any]] = []
        for (key, value) in [("purpose", "invoke"), ("productDigest", "bad"), ("actionID", "../foreign"), ("unknown", "value")] {
            var fields = original; fields[key] = value; variants.append(fields)
        }
        var fields = original; fields["leaseGeneration"] = 0; variants.append(fields)
        for sample in [["kind": "text", "value": "arbitrary user input"], ["kind": "null"], ["kind": "omission"],
                       ["kind": "text", "value": "Intents adapter probe", "unknown": "extra"]] {
            fields = original; fields["parameters"] = [["name": "sample", "family": "text", "samples": [sample]]]; variants.append(fields)
        }
        for fields in variants { XCTAssertThrowsError(try HostInputAdapterProbePlan.decode(data(fields))) }
    }
    func testReceiptDeniesChangedScopeFamilyValuesRunnerAndDispatchClaims() throws {
        let plan = try plan(), original = try receipt(plan)
        var variants: [[String: Any]] = []
        for (key, value) in [("attemptID", "old"), ("catalogDigest", String(repeating: "e", count: 64)), ("hostProductDigest", String(repeating: "e", count: 64))] {
            var fields = original; fields[key] = value; variants.append(fields)
        }
        var fields = original; fields["complete"] = false; variants.append(fields)
        fields = original; fields["dispatched"] = true; variants.append(fields)
        fields = original; fields["runner"] = ["pid": 0, "startIdentity": "123:0", "executablePath": "/foreign"]; variants.append(fields)
        fields = original; fields["parameters"] = [["name": "sample", "family": "bool", "samples": [["kind": "bool", "boolValue": true]]]]; variants.append(fields)
        fields = original; fields["parameters"] = [["name": "sample", "family": "text", "samples": [["kind": "text", "value": "different"]]]]; variants.append(fields)
        fields = original; fields["parameters"] = []; variants.append(fields)
        for fields in variants { XCTAssertThrowsError(try AutomationInputAdapterProbeObservation.read(data(fields), plan: plan, scope: scope)) }
    }
    private func fileProbeExport(at root: URL, plan: AutomationInputAdapterProbePlan) throws -> [[String: Any]] {
        var fields = try receipt(plan)
        let value = try HostIntentFileCodec.encode(data: AutomationIntentFileCalibration.data, filename: AutomationIntentFileCalibration.filename,
            typeIdentifier: AutomationIntentFileCalibration.typeIdentifier, operationID: "sample:0")
        fields["parameters"] = [["name": "sample", "family": "intentFile", "samples": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]]]
        let raw = try data(fields)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(AutomationIntentFileCalibration.data.base64EncodedString()))
        XCTAssertThrowsError(try AutomationInputAdapterProbeObservation.read(raw, plan: plan, scope: scope))
        try raw.write(to: root.appendingPathComponent("receipt.json")); try AutomationIntentFileCalibration.data.write(to: root.appendingPathComponent("file.bin"))
        let entries = [("receipt.json", "intents-input-adapter-probe"), ("file.bin", "intents-file-sample:0")].map { file, name in
            ["exportedFileName": file, "suggestedHumanReadableName": name, "isAssociatedWithFailure": false,
             "configurationName": "Debug", "deviceName": "fixture", "deviceId": "owned"] as [String: Any]
        }
        let manifest: [[String: Any]] = [["testIdentifier": "InputAdapterProbeTests/testParameterRoundTrip()", "attachments": entries]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json")); return manifest
    }
    private func probeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("file-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testFileCanaryRequiresImmutableSampleAndSeparateBinaryReadback() async throws {
        let plan = try plan(family: "intentFile"), host = try HostInputAdapterProbePlan.decode(plan.payload(scope: scope))
        XCTAssertEqual(host.parameters[0].samples, try HostInputAdapterProbePlan.samples(family: "intentFile"))
        XCTAssertEqual(try HostIntentFileCodec.decode(host.parameters[0].samples[0]).0, AutomationIntentFileCalibration.data)
        var altered = try object(plan.payload(scope: scope)), parameter = try XCTUnwrap((altered["parameters"] as? [[String: Any]])?.first)
        var sample = try XCTUnwrap((parameter["samples"] as? [[String: Any]])?.first); sample["value"] = Data("custom bytes".utf8).base64EncodedString()
        parameter["samples"] = [sample]; altered["parameters"] = [parameter]
        XCTAssertThrowsError(try HostInputAdapterProbePlan.decode(data(altered)))
        let root = try probeRoot(), artifacts = try AutomationArtifactRegistry(root: probeRoot())
        _ = try fileProbeExport(at: root, plan: plan)
        let (_, observation) = try await AutomationInputAdapterProbeFileAttachments.importExport(root: root, plan: plan, scope: scope, artifacts: artifacts)
        guard case .artifact(let handle, let digest) = observation.echoedSamples["sample"]?.first else { return XCTFail("Missing opaque file readback") }
        XCTAssertEqual(digest, AutomationIntentFileMetadata.digest(AutomationIntentFileCalibration.data))
        do { _ = try await artifacts.resolve(handle: handle, scope: scope); XCTFail("Probe binary exposed") } catch {}
        XCTAssertFalse(CapabilityProfile().supports(["apple.codec.intentFile"]))
    }
    func testFileCanaryRejectsMissingChangedUnclaimedAndStaleBinaryReceipts() async throws {
        let plan = try plan(family: "intentFile")
        for failure in ["missing", "changed", "unclaimed", "duplicate", "stale", "metadata", "secret"] {
            let root = try probeRoot(), artifacts = try AutomationArtifactRegistry(root: probeRoot())
            var manifest = try fileProbeExport(at: root, plan: plan)
            switch failure {
            case "missing": try FileManager.default.removeItem(at: root.appendingPathComponent("file.bin"))
            case "changed": try Data("changed".utf8).write(to: root.appendingPathComponent("file.bin"))
            case "unclaimed", "duplicate":
                var entries = manifest[0]["attachments"] as! [[String: Any]]
                if failure == "duplicate" { entries.append(entries[1]) } else { entries[1]["suggestedHumanReadableName"] = "unclaimed" }
                manifest[0]["attachments"] = entries
                try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
            case "stale", "metadata":
                var fields = try object(Data(contentsOf: root.appendingPathComponent("receipt.json")))
                if failure == "stale" { fields["attemptID"] = "stale" }
                else {
                    var params = fields["parameters"] as! [[String: Any]], samples = params[0]["samples"] as! [[String: Any]], metadata = samples[0]["file"] as! [String: Any]
                    metadata["filename"] = "different.txt"; samples[0]["file"] = metadata; params[0]["samples"] = samples; fields["parameters"] = params
                }
                try data(fields).write(to: root.appendingPathComponent("receipt.json"))
            case "secret": try await artifacts.restrictSecretEvidence(scope: scope)
            default: break
            }
            do { _ = try await AutomationInputAdapterProbeFileAttachments.importExport(root: root, plan: plan, scope: scope, artifacts: artifacts); XCTFail("Accepted " + failure) } catch {}
        }
    }
    func testIntentIdentityMustMatchAtEveryDefinitionAndInstanceBoundary() throws {
        let expected = ["example.Subject", "example.Subject", "Subject.Probe", "example.Subject", "Subject.Probe"]
        func validate(_ values: [String]) throws {
            try HostIntentIdentity.validate(bundle: "example.Subject", action: "Subject.Probe", definitionsBundle: values[0],
                definitionBundle: values[1], definitionID: values[2], intentBundle: values[3], intentID: values[4])
        }
        try validate(expected)
        for index in expected.indices { var values = expected; values[index] = "foreign"; XCTAssertThrowsError(try validate(values)) }
    }
}
#endif
