import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationHostContracts
import IntentsAutomationDateCodec

final class IntentFileTransportTests: XCTestCase, @unchecked Sendable {
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1)
    private let bytes = Data("private-file-body".utf8)
    private var app: AppIdentity { .init(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64)) }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("intent-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func export(_ root: URL, bytes: Data? = nil, operationID: String = "make") throws -> (AutomationHostProgram, Data, [[String: Any]]) {
        let bytes = bytes ?? self.bytes
        let value = try HostIntentFileCodec.encode(data: bytes, filename: "sample.txt", typeIdentifier: "public.plain-text", operationID: operationID)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": Int32.max, "startIdentity": "100:0", "executablePath": "/owned/Host.app/Host"],
            "runID": scope.runId, "attemptID": scope.attemptId, "segmentID": scope.segmentId, "leaseGeneration": scope.leaseGeneration,
            "bundleID": app.bundleID, "productDigest": app.productDigest!, "complete": true,
            "operations": [["operationID": operationID, "dispatched": true, "value": json]]]
        let data = try JSONSerialization.data(withJSONObject: receipt)
        try data.write(to: root.appendingPathComponent("receipt.json")); try bytes.write(to: root.appendingPathComponent("binary.dat"))
        let attachments = [("receipt.json", "intents-system-receipt"), ("binary.dat", "intents-file-" + operationID)].map { file, name in
            ["exportedFileName": file, "suggestedHumanReadableName": name, "isAssociatedWithFailure": false,
             "configurationName": "Debug", "deviceName": "fixture", "deviceId": "owned"] as [String: Any]
        }
        let manifest: [[String: Any]] = [["testIdentifier": "SegmentTests/testSegment()", "attachments": attachments]]
        try writeManifest(manifest, root: root)
        return (.init(operations: [.init(id: operationID, kind: .invoke, typeID: "MakeIntent", resultCodec: "intentFile")]), data, manifest)
    }
    private func writeManifest(_ value: [[String: Any]], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("manifest.json"))
    }
    private func plan(_ program: AutomationHostProgram) -> AutomationCase {
        var setup = AutomationSegment(id: "setup", kind: .systemIntent, phase: .setup, operation: "Make", lifecycle: .persistedStateAcrossSegments)
        setup.hostProgram = program; setup.requiredCapabilities = ["apple.codec.intentFile"]
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Read", lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "read", kind: .invoke, typeID: "ReadIntent", resultCodec: "noValue")])
        subject.inputBindings = [.init(producerSegmentID: "setup", outputID: program.operations[0].id, destination: .hostParameter, operationID: "read", name: "file", parameterCodec: "intentFile")]
        subject.requiredCapabilities = ["apple.codec.intentFile"]
        return .init(id: "file-case", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "fixture", execution: subject, setup: [setup])
    }
    func testBinaryAttachmentThroughTypedRegistryPermitPayloadAndHostReadback() async throws {
        let root = try root()
        let (program, json, _) = try export(root), plan = plan(program)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("private-file-body"))
        XCTAssertThrowsError(try AutomationHostReceiptImporter.importReceipt(json, scope: scope, app: app, program: program))
        let artifactsRoot = try self.root(), artifacts = try AutomationArtifactRegistry(root: artifactsRoot)
        let imported = try await AutomationHostFileAttachments.importExport(root: root, scope: scope, app: app, program: program, artifacts: artifacts, planDigest: AutomationFrozenCase.planDigest(plan))
        var producer = AutomationSegmentReceipt(scope: scope, app: app, target: plan.target, segmentID: "setup", route: .systemIntent,
            dispatched: true, completed: true, verifiedOutputs: imported.receipt.values, environmentID: plan.environmentID)
        producer.hostReceiptDigest = AutomationArtifactRegistry.digest(imported.receiptData)
        let resolution = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [producer], plan: plan, runID: "run", attemptID: "attempt")
        let consumer = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        XCTAssertThrowsError(try resolution.segment.hostProgram!.payload(scope: consumer, app: app, route: .systemIntent, phase: .subject))
        let inputs = try await resolution.authority.fileInputs(plan: plan, segment: resolution.segment, scope: consumer, artifacts: artifacts)
        let wire = try resolution.segment.hostProgram!.executionPayload(scope: consumer, app: app, route: .systemIntent, phase: .subject, fileInputs: inputs)
        let host = try JSONDecoder().decode(HostPlan.self, from: wire)
        let (decoded, metadata) = try HostIntentFileCodec.decode(XCTUnwrap(host.operations[0].parameters["file"]))
        XCTAssertEqual(decoded, bytes); XCTAssertEqual(metadata.filename, "sample.txt"); XCTAssertEqual(metadata.typeIdentifier, "public.plain-text")
        if case .artifact(let handle, _) = imported.receipt.values["make"] {
            do { _ = try await artifacts.resolve(handle: handle, scope: scope); XCTFail("Binary exposed to ordinary evidence") } catch {}
        } else { XCTFail("Missing opaque artifact") }
        var foreign = consumer; foreign.attemptId = "foreign"
        do { _ = try await resolution.authority.fileInputs(plan: plan, segment: resolution.segment, scope: foreign, artifacts: artifacts); XCTFail("Foreign attempt got bytes") } catch {}
        try AutomationCodecRequirements.validate(plan.execution, plan: plan, capabilities: .init(), purpose: .review)
        XCTAssertThrowsError(try AutomationCodecRequirements.validate(plan.execution, plan: plan, capabilities: .init()))
    }
    func testXcodeExportSuffixesAndAutomaticRecordingPreserveExactFileImport() async throws {
        let root = try root(), (program, _, initial) = try export(root)
        var manifest = initial, entries = initial[0]["attachments"] as! [[String: Any]]
        // Naming captured from the Xcode 27 simulator export, not the host's raw attachment name.
        entries[0]["suggestedHumanReadableName"] = "intents-system-receipt_0_F2839133-BF2D-4CE3-B21F-DF4FC978C4CF.json"
        entries[1]["suggestedHumanReadableName"] = "intents-file-make_0_0D3B99C5-2405-4559-8D4D-E21A7234F4D5.txt"
        var recording = entries[0]
        recording["exportedFileName"] = "A0EE9C86-53C0-429D-8A69-3DE5725B66AC.mp4"
        recording["suggestedHumanReadableName"] = "Screen Recording 2026-10-14 at 08.25.36 am.mp4"
        entries.append(recording)
        try Data("unclaimed recording".utf8).write(to: root.appendingPathComponent(recording["exportedFileName"] as! String))
        manifest[0]["attachments"] = entries; try writeManifest(manifest, root: root)
        let artifactsRoot = try self.root(), artifacts = try AutomationArtifactRegistry(root: artifactsRoot)
        let imported = try await AutomationHostFileAttachments.importExport(root: root, scope: scope, app: app, program: program,
            artifacts: artifacts, planDigest: AutomationFrozenCase.planDigest(plan(program)))
        guard case .artifact(_, let digest) = imported.receipt.values["make"] else { return XCTFail("Missing exact file output") }
        XCTAssertEqual(digest, AutomationArtifactRegistry.digest(bytes))
        let index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self,
            from: Data(contentsOf: artifactsRoot.appendingPathComponent("artifact-index.json")))
        XCTAssertEqual(index.count, 1, "Only the correlated file becomes an artifact")
    }
    func testExportRejectsDuplicateNamesAfterRemovingXcodeSuffix() throws {
        let root = try root(), (_, _, initial) = try export(root)
        var manifest = initial, entries = initial[0]["attachments"] as! [[String: Any]], duplicate = entries[0]
        duplicate["exportedFileName"] = "duplicate.json"
        duplicate["suggestedHumanReadableName"] = "intents-system-receipt_0_F2839133-BF2D-4CE3-B21F-DF4FC978C4CF.json"
        try Data(contentsOf: root.appendingPathComponent("receipt.json")).write(to: root.appendingPathComponent("duplicate.json"))
        entries.append(duplicate); manifest[0]["attachments"] = entries; try writeManifest(manifest, root: root)
        XCTAssertThrowsError(try AutomationHostFileAttachments.exportEntries(root: root, testIdentifier: "SegmentTests/testSegment()",
            expectedNames: ["intents-system-receipt", "intents-file-make"]))
    }
    func testXcodeExportPreservesDottedOperationIDAcrossAllAttachments() async throws {
        let root = try root(), (program, receiptData, initial) = try export(root, operationID: "file.echo")
        var manifest = initial, entries = initial[0]["attachments"] as! [[String: Any]]
        entries[0]["suggestedHumanReadableName"] = "intents-system-receipt_0_246F4B45-9E0E-4513-9BC8-D2C0CA8DE7FD.json"
        entries[1]["suggestedHumanReadableName"] = "intents-file-file_0_B926F051-5659-4214-B1F9-F527286D8C21.echo"
        var progress = entries[0], dispatch = entries[0]
        progress["exportedFileName"] = "progress.json"
        progress["suggestedHumanReadableName"] = "intents-system-receipt-file_0_9ECD9287-624C-4791-852B-3A8D52DFF738.echo"
        dispatch["exportedFileName"] = "dispatch.json"
        dispatch["suggestedHumanReadableName"] = "intents-dispatch-file_0_4F818EB8-5D7B-48E7-A0F4-3F34E3100BEB.echo"
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
        receipt["complete"] = false
        try JSONSerialization.data(withJSONObject: receipt).write(to: root.appendingPathComponent("progress.json"))
        try JSONSerialization.data(withJSONObject: ["operationID": "file.echo", "dispatched": true]).write(to: root.appendingPathComponent("dispatch.json"))
        entries += [progress, dispatch]; manifest[0]["attachments"] = entries; try writeManifest(manifest, root: root)
        let artifacts = try AutomationArtifactRegistry(root: self.root())
        let imported = try await AutomationHostFileAttachments.importExport(root: root, scope: scope, app: app, program: program,
            artifacts: artifacts, planDigest: AutomationFrozenCase.planDigest(plan(program)))
        guard case .artifact(_, let digest) = imported.receipt.values["file.echo"] else { return XCTFail("Dotted output missing") }
        XCTAssertEqual(digest, AutomationArtifactRegistry.digest(bytes))
    }
    func testXcodeExportRejectsAmbiguousOrUnexpectedLogicalNames() throws {
        let root = try root(), (_, _, initial) = try export(root)
        var manifest = initial, entries = initial[0]["attachments"] as! [[String: Any]]
        entries[0]["suggestedHumanReadableName"] = "intents-system-receipt_0_246F4B45-9E0E-4513-9BC8-D2C0CA8DE7FD.json"
        manifest[0]["attachments"] = entries; try writeManifest(manifest, root: root)
        XCTAssertThrowsError(try AutomationHostFileAttachments.exportEntries(root: root, testIdentifier: "SegmentTests/testSegment()",
            expectedNames: ["intents-system-receipt", "intents-system-receipt.json", "intents-file-make"]))
        XCTAssertThrowsError(try AutomationHostFileAttachments.exportEntries(root: root, testIdentifier: "SegmentTests/testSegment()",
            expectedNames: ["intents-system-receipt", "intents-file-other"]))
    }
    func testMetadataByteAndNativeInputBoundsRejectMalformedFiles() throws {
        for name in ["../escape", "a/b", "a\\b", ".hidden", "", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try AutomationIntentFileMetadata(filename: name, typeIdentifier: nil, data: bytes))
        }
        XCTAssertThrowsError(try AutomationIntentFileMetadata(filename: "file", typeIdentifier: "public.executable", data: bytes))
        XCTAssertThrowsError(try AutomationIntentFileMetadata(filename: "file", typeIdentifier: nil, data: Data(repeating: 0, count: 8193)))
        let value = try HostIntentFileCodec.encode(data: bytes, filename: "file", typeIdentifier: nil, operationID: "make")
        let encoded = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(bytes.base64EncodedString()))
        let metadata = try XCTUnwrap(value.file)
        var input = try JSONDecoder().decode(HostInput.self, from: JSONSerialization.data(withJSONObject: ["kind": "intentFile", "value": bytes.base64EncodedString(), "file": JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))]))
        XCTAssertEqual(try HostIntentFileCodec.decode(input).0, bytes)
        input = try JSONDecoder().decode(HostInput.self, from: Data("{\"kind\":\"intentFile\",\"value\":\"not base64\"}".utf8))
        XCTAssertThrowsError(try HostIntentFileCodec.decode(input))
    }
    func testExportRejectsMissingDuplicateUnclaimedLinkedAndHashMismatchedAttachments() async throws {
        for failure in ["missing", "duplicate", "unclaimed", "unlisted", "linked", "hardlink", "digest", "test", "completedProgress", "traversal"] {
            let root = try root(), (program, _, initial) = try export(root), artifacts = try AutomationArtifactRegistry(root: self.root())
            var manifest = initial, entries = initial[0]["attachments"] as! [[String: Any]]
            switch failure {
            case "missing": try FileManager.default.removeItem(at: root.appendingPathComponent("binary.dat"))
            case "duplicate": entries.append(entries[1])
            case "unclaimed": entries[1]["suggestedHumanReadableName"] = "foreign-binary"
            case "unlisted": try bytes.write(to: root.appendingPathComponent("unlisted.bin"))
            case "linked":
                try FileManager.default.removeItem(at: root.appendingPathComponent("binary.dat"))
                let foreign = try self.root().appendingPathComponent("foreign"); try bytes.write(to: foreign)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("binary.dat"), withDestinationURL: foreign)
            case "hardlink":
                try FileManager.default.removeItem(at: root.appendingPathComponent("binary.dat"))
                let foreign = try self.root().appendingPathComponent("foreign"); try bytes.write(to: foreign)
                try FileManager.default.linkItem(at: foreign, to: root.appendingPathComponent("binary.dat"))
            case "digest": try Data("changed".utf8).write(to: root.appendingPathComponent("binary.dat"))
            case "test": manifest[0]["testIdentifier"] = "Other/testSegment()"
            case "completedProgress":
                var progress = entries[0]; progress["exportedFileName"] = "progress.json"; progress["suggestedHumanReadableName"] = "intents-system-receipt-make"; entries.append(progress)
                try Data(contentsOf: root.appendingPathComponent("receipt.json")).write(to: root.appendingPathComponent("progress.json"))
            case "traversal": entries[1]["exportedFileName"] = "../binary.dat"
            default: break
            }
            manifest[0]["attachments"] = entries; try writeManifest(manifest, root: root)
            do { _ = try await AutomationHostFileAttachments.importExport(root: root, scope: scope, app: app, program: program, artifacts: artifacts, planDigest: AutomationFrozenCase.planDigest(plan(program))); XCTFail("Accepted " + failure) } catch {}
        }
    }
    func testAggregatePayloadBudgetAndSecretFenceApplyToTransferredFiles() async throws {
        let artifactRoot = try root()
        let artifacts = try AutomationArtifactRegistry(root: artifactRoot), data = Data(repeating: 42, count: 8192)
        let metadata = try AutomationIntentFileMetadata(filename: "data.bin", typeIdentifier: "public.data", data: data)
        let operations = (0..<3).map { AutomationHostProgram.Operation(id: "make\($0)", kind: .invoke, typeID: "MakeIntent", resultCodec: "intentFile") }
        var plan = plan(.init(operations: operations))
        plan.execution.inputBindings = (0..<3).map { .init(producerSegmentID: "setup", outputID: "make\($0)", destination: .hostParameter,
            operationID: "read", name: "file\($0)", parameterCodec: "intentFile") }
        let digest = try AutomationFrozenCase.planDigest(plan)
        var outputs: [String: AutomationValue] = [:]
        for operation in operations {
            let artifact = try await artifacts.storeNativeEvidence(data: data, scope: scope, metadata: metadata,
                provenance: .init(planDigest: digest, operationID: operation.id, receiptDigest: String(repeating: "c", count: 64)))
            outputs[operation.id] = .artifact(handle: artifact.handle, sha256: artifact.sha256)
        }
        var receipt = AutomationSegmentReceipt(scope: scope, app: app, target: plan.target, segmentID: "setup", route: .systemIntent,
            dispatched: true, completed: true, verifiedOutputs: outputs, environmentID: plan.environmentID)
        receipt.hostReceiptDigest = String(repeating: "c", count: 64)
        let resolved = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt")
        let consumer = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        let inputs = try await resolved.authority.fileInputs(plan: plan, segment: resolved.segment, scope: consumer, artifacts: artifacts)
        XCTAssertThrowsError(try resolved.segment.hostProgram!.executionPayload(scope: consumer, app: app, route: .systemIntent, phase: .subject, fileInputs: inputs))
        try AutomationSecretEvidenceFence(root: artifactRoot).restrict(scope)
        do { _ = try await resolved.authority.fileInputs(plan: plan, segment: resolved.segment, scope: consumer, artifacts: artifacts); XCTFail("Secret-tainted file transferred") } catch {}
    }
    func testArtifactFromDifferentFrozenPlanOrOutputCannotSatisfyTransfer() async throws {
        let program = AutomationHostProgram(operations: [.init(id: "make", kind: .invoke, typeID: "MakeIntent", resultCodec: "intentFile")]), plan = plan(program)
        for wrongPlan in [false, true] {
            let artifacts = try AutomationArtifactRegistry(root: root())
            let metadata = try AutomationIntentFileMetadata(filename: "sample.txt", typeIdentifier: nil, data: bytes)
            let artifact = try await artifacts.storeNativeEvidence(data: bytes, scope: scope, metadata: metadata,
                provenance: .init(planDigest: wrongPlan ? String(repeating: "b", count: 64) : AutomationFrozenCase.planDigest(plan),
                    operationID: wrongPlan ? "make" : "other", receiptDigest: String(repeating: "c", count: 64)))
            var receipt = AutomationSegmentReceipt(scope: scope, app: app, target: plan.target, segmentID: "setup", route: .systemIntent,
                dispatched: true, completed: true, verifiedOutputs: ["make": .artifact(handle: artifact.handle, sha256: artifact.sha256)], environmentID: plan.environmentID)
            receipt.hostReceiptDigest = String(repeating: "c", count: 64)
        let resolved = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt")
            let consumer = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
            do { _ = try await resolved.authority.fileInputs(plan: plan, segment: resolved.segment, scope: consumer, artifacts: artifacts); XCTFail("Foreign file provenance accepted") } catch {}
        }
    }
    func testReceiptCommitmentAndOriginalArtifactHashSurviveReloadedIndexChanges() async throws {
        let root = try root(), registry = try AutomationArtifactRegistry(root: root)
        let plan = plan(.init(operations: [.init(id: "make", kind: .invoke, typeID: "MakeIntent", resultCodec: "intentFile")]))
        let metadata = try AutomationIntentFileMetadata(filename: "sample.txt", typeIdentifier: nil, data: bytes)
        let artifact = try await registry.storeNativeEvidence(data: bytes, scope: scope, metadata: metadata,
            provenance: .init(planDigest: AutomationFrozenCase.planDigest(plan), operationID: "make", receiptDigest: String(repeating: "c", count: 64)))
        var receipt = AutomationSegmentReceipt(scope: scope, app: app, target: plan.target, segmentID: "setup", route: .systemIntent,
            dispatched: true, completed: true, verifiedOutputs: ["make": .artifact(handle: artifact.handle, sha256: artifact.sha256)], environmentID: plan.environmentID)
        let consumer = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        XCTAssertThrowsError(try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt"))
        receipt.hostReceiptDigest = String(repeating: "d", count: 64)
        let wrong = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt")
        do { _ = try await wrong.authority.fileInputs(plan: plan, segment: wrong.segment, scope: consumer, artifacts: registry); XCTFail("Different producer receipt accepted") } catch {}
        receipt.hostReceiptDigest = String(repeating: "c", count: 64)
        let exact = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt")
        _ = try await exact.authority.fileInputs(plan: plan, segment: exact.segment, scope: consumer, artifacts: registry)
        let replacement = Data("replacement-metadata-and-file".utf8)
        try replacement.write(to: root.appendingPathComponent(artifact.relativePath))
        let indexURL = root.appendingPathComponent("artifact-index.json")
        var index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self, from: Data(contentsOf: indexURL))
        index[artifact.handle]?.fileMetadata = try .init(filename: "sample.txt", typeIdentifier: nil, data: replacement)
        try JSONEncoder().encode(index).write(to: indexURL)
        let reopened = try AutomationArtifactRegistry(root: root)
        do { _ = try await exact.authority.fileInputs(plan: plan, segment: exact.segment, scope: consumer, artifacts: reopened); XCTFail("Rewritten metadata bypassed frozen artifact hash") } catch {}
        // Removing optional index classification cannot expose the physically reserved file.
        try bytes.write(to: root.appendingPathComponent(artifact.relativePath))
        index[artifact.handle]?.nativeOnly = nil; index[artifact.handle]?.fileMetadata = nil; index[artifact.handle]?.fileProvenance = nil
        try JSONEncoder().encode(index).write(to: indexURL)
        let stripped = try AutomationArtifactRegistry(root: root)
        do { _ = try await stripped.resolve(handle: artifact.handle, scope: scope); XCTFail("Stripped native classification exposed bytes") } catch {}
    }
    func testNativeStagingResidueCannotBeRegisteredOrResolvedAsOrdinaryEvidence() async throws {
        let root = try root(), registry = try AutomationArtifactRegistry(root: root)
        let artifact = try await registry.storeNativeEvidence(data: bytes, scope: scope)
        for name in [artifact.relativePath + ".staging", "." + artifact.relativePath + ".old.tmp"] {
            try bytes.write(to: root.appendingPathComponent(name))
            for owner in [registry, try AutomationArtifactRegistry(root: root)] {
                do { _ = try await owner.register(relativePath: name, scope: scope); XCTFail("Native staging residue registered") } catch {}
            }
            var forged = artifact; forged.relativePath = name; forged.nativeOnly = nil
            let indexURL = root.appendingPathComponent("artifact-index.json")
            try JSONEncoder().encode([artifact.handle: forged]).write(to: indexURL)
            let reopened = try AutomationArtifactRegistry(root: root)
            do { _ = try await reopened.resolve(handle: artifact.handle, scope: scope); XCTFail("Native staging residue resolved") } catch {}
        }
    }
    func testReservedNativeArtifactsCannotBeRetaggedThroughStaleOrReloadedRegistry() async throws {
        let root = try root(), first = try AutomationArtifactRegistry(root: root), stale = try AutomationArtifactRegistry(root: root)
        let metadata = try AutomationIntentFileMetadata(filename: "sample.txt", typeIdentifier: nil, data: bytes)
        let artifact = try await first.storeNativeEvidence(data: bytes, scope: scope, metadata: metadata, provenance: .init(planDigest: String(repeating: "b", count: 64), operationID: "make", receiptDigest: String(repeating: "c", count: 64)))
        for registry in [first, stale, try AutomationArtifactRegistry(root: root)] {
            do { _ = try await registry.register(relativePath: artifact.relativePath, scope: scope); XCTFail("Retagged native bytes") } catch {}
            do { _ = try await registry.resolve(handle: artifact.handle, scope: scope); XCTFail("Exposed native bytes") } catch {}
        }
        let log = try await first.storeNativeEvidence(data: bytes, scope: scope)
        do { _ = try await first.resolve(handle: log.handle, scope: scope); XCTFail("Exposed file-bearing runner log") } catch {}
    }
}
