#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

/// These exercise the independent file reader and recorded-fact correlation.
/// Synthetic receipts do not create runtime qualification or live recipe authority.
final class AutomationDurableStateObserverTests: XCTestCase {
    private let profile = AutomationDurableStateProfile.registered[0]
    private var app: AppIdentity {
        var app = AppIdentity(logicalID: "fixture", bundleID: profile.bundleID, platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = "/fixture/Product.app"; app.sourceManifestDigest = String(repeating: "b", count: 64)
        return app
    }
    private var target: TargetIdentity { .init(id: "host-macos-local", kind: .nativeMac, loginSession: "fixture-login") }
    private var reader: AutomationDurableStateReader {
        .init(profileID: profile.id, catalogDigest: String(repeating: "c", count: 64), hostProductDigest: String(repeating: "d", count: 64), hostXctestrunDigest: String(repeating: "e", count: 64), app: app, target: target, environmentID: "fixture", sourceManifestPath: "/fixture/source-manifest.json", sourceFiles: Dictionary(uniqueKeysWithValues:
            profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }.map { ("/fixture/source/" + $0.key, $0.value) }), declaration: profile.schema())
    }
    private var query: AutomationHostProgram.Operation {
        .init(id: "records", kind: .query, typeID: profile.entityTypeID, queryIDs: ["selected", "protected"], properties: profile.properties)
    }
    private func directory() throws -> URL {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("durable-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        // The reader intentionally refuses directory symlinks. Foundation's
        // resolvingSymlinksInPath can retain /var or /tmp aliases on macOS;
        // use the product's realpath contract after this directory exists.
        let root = try AutomationPath.canonical(requested)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func document(selected: Bool, protected: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["control": "correct", "executionCount": 1, "records": [
            ["id": "selected", "title": "Send invoice", "owner": "Work", "completed": selected],
            ["id": "protected", "title": "Send invoice", "owner": "Personal", "completed": protected]]], options: [.sortedKeys])
    }
    private func plan() throws -> AutomationCase {
        let subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete")
        var observer = AutomationSegment(id: "read", kind: .systemQuery, phase: .observe, operation: "Read", lifecycle: .persistedStateAcrossSegments)
        observer.hostProgram = .init(operations: [query])
        let checks = [("Work", true), ("Personal", false)].map { owner, expected in
            AutomationRequirement(observationID: "read", expected: .bool(expected), proof: .appState, justification: "Reviewed required state",
                checkID: owner, entityProperty: .init(operationID: "records", selection: .init(typeID: profile.entityTypeID,
                    matchingProperties: ["owner": .text(owner)]), property: "completed"))
        }
        var plan = AutomationCase(id: "fixture-case", app: app, target: target, environmentID: "fixture", execution: subject,
                                  observations: [observer], requirements: checks)
        plan.provenance = ["catalog": reader.catalogDigest, "apple.macHostProductDigest": reader.hostProductDigest, "apple.macXctestrunDigest": reader.hostXctestrunDigest]
        return try reader.applying(to: plan)
    }
    private func evidence(plan: AutomationCase, document: Data, outputs: [String: AutomationValue]) throws -> [AutomationSegmentReceipt] {
        let segment = plan.observations[0], actualReader = plan.observations[0].durableStateReader!, scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: segment.id, leaseGeneration: 2)
        var observation = AutomationObservation(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: "attempt",
            stepID: segment.id, route: .storageRead, proof: .persistedState, value: outputs["records"]!)
        observation.artifact = "reader-artifact"
        var receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .storageRead,
            dispatched: true, completed: true, observations: [observation], artifact: "reader-artifact", verifiedOutputs: outputs, environmentID: plan.environmentID)
        receipt.durableStateRead = .init(scope: scope, planDigest: try AutomationFrozenCase.planDigest(plan), recipeDigest: try actualReader.digest(),
            documentDigest: AutomationArtifactRegistry.digest(document), outputsDigest: try AutomationDurableStateReadReceipt.outputsDigest(outputs))
        return [.init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: plan.app, target: plan.target,
                      segmentID: "subject", route: .systemIntent, dispatched: true, completed: true, environmentID: plan.environmentID), receipt]
    }
    private func assessment(_ plan: AutomationCase, receipts: [AutomationSegmentReceipt]) -> AttemptResult {
        AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true,
            observations: receipts.flatMap(\.observations), receipts: receipts, runID: "run")
    }
    func testRegisteredFixturePinsARealUnsandboxedMacTargetAndRetainsTheIOSTarget() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("Verification/Automation/Fixtures/DuplicateTasks")
        for (relative, digest) in profile.sourceDigests {
            XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: fixture.appendingPathComponent(relative))), digest,
                           "The registered profile must match every reviewed producer and the actual generated project")
        }
        let project = fixture.appendingPathComponent("DuplicateTasks.xcodeproj")
        let intake = try AutomationApplicationIntake.assess(project)
        XCTAssertEqual(Set(intake.candidates.map(\.name)), ["DuplicateTasks", "DuplicateTasksMac"])
        let bytes = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let mac = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "DuplicateTasksMac" })
        let listID = try XCTUnwrap(mac["buildConfigurationList"] as? String)
        let configurations = try XCTUnwrap(objects[listID]?["buildConfigurations"] as? [String])
        XCTAssertEqual(configurations.count, 2)
        for identifier in configurations {
            let settings = try XCTUnwrap(objects[identifier]?["buildSettings"] as? [String: Any])
            XCTAssertEqual(settings["SDKROOT"] as? String, "macosx")
            XCTAssertEqual(settings["ENABLE_APP_SANDBOX"] as? String, "NO")
            XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String, profile.bundleID)
            XCTAssertNil(settings["TARGETED_DEVICE_FAMILY"])
        }
    }
    func testPriorIOSOnlyProjectRecipeCannotBeRelabelledAsNativeMacDurability() throws {
        XCTAssertEqual(profile.id, "duplicate-tasks-json.v2")
        let old = AutomationDurableStateReader(profileID: "duplicate-tasks-json.v1", catalogDigest: reader.catalogDigest,
            hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest,
            app: app, target: target, environmentID: "fixture", sourceManifestPath: reader.sourceManifestPath,
            sourceFiles: reader.sourceFiles, declaration: reader.declaration)
        XCTAssertThrowsError(try old.validateIdentity())
    }
    func testSameActualStorageObserverPassesCorrectSaveAndRejectsOmittedSaveAndWrongRecord() throws {
        let root = try directory(), file = root.appendingPathComponent("state.json"), plan = try plan()
        let frozenSubject = plan.execution, frozenObservers = plan.observations
        for (savedSelected, savedProtected, expected) in [(true, false, AttemptResult.Summary.passed), (false, false, .assertionFailed), (false, true, .assertionFailed)] {
            // The subject may claim success in memory; only actual disk bytes enter this observer.
            try document(selected: savedSelected, protected: savedProtected).write(to: file)
            let (bytes, outputs) = try reader.snapshot(program: .init(operations: [query]), storageURL: file)
            let receipts = try evidence(plan: plan, document: bytes, outputs: outputs)
            XCTAssertEqual(assessment(plan, receipts: receipts).summary, expected)
            XCTAssertEqual(plan.execution, frozenSubject); XCTAssertEqual(plan.observations, frozenObservers)
        }
    }
    func testReaderDoesNotWriteOrRepairAndFencesChangedSnapshot() throws {
        let root = try directory(), file = root.appendingPathComponent("state.json"), original = try document(selected: false)
        try original.write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        _ = try reader.snapshot(program: .init(operations: [query]), storageURL: file)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertThrowsError(try reader.snapshot(program: .init(operations: [query]), storageURL: file, afterFirstRead: {
            try self.document(selected: true).write(to: file, options: .atomic)
        }))
        try original.write(to: file)
        XCTAssertThrowsError(try reader.snapshot(program: .init(operations: [query]), storageURL: file, afterFirstRead: {
            try original.write(to: file, options: .atomic) // Equal bytes at a replaced inode are still a raced pathname.
        }))
    }
    func testRejectsSymlinkAmbiguousKeysDuplicateIDsAndMissingProtectedEntity() throws {
        let root = try directory(), file = root.appendingPathComponent("state.json"), link = root.appendingPathComponent("link.json")
        try document(selected: true).write(to: file)
        // Establish a passing read first so a path-admission failure cannot make
        // every negative assertion appear to test key/identity validation.
        XCTAssertNoThrow(try reader.snapshot(program: .init(operations: [query]), storageURL: file))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try reader.snapshot(program: .init(operations: [query]), storageURL: link))
        for text in [
            "{\"records\":[],\"records\":[],\"control\":\"correct\",\"executionCount\":0}",
            String(decoding: try document(selected: true), as: UTF8.self).replacingOccurrences(of: "protected", with: "selected")
        ] {
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try reader.snapshot(program: .init(operations: [query]), storageURL: file))
        }
        var absent = query; absent.queryIDs = ["missing-protected"]
        try document(selected: true).write(to: file)
        XCTAssertThrowsError(try reader.snapshot(program: .init(operations: [absent]), storageURL: file))
    }
    func testCorrelatedDurableReceiptRejectsDifferentScopeRecipeOutputAndLeaseOrder() throws {
        let plan = try plan(), root = try directory(), file = root.appendingPathComponent("state.json")
        try document(selected: true).write(to: file)
        let (bytes, outputs) = try reader.snapshot(program: .init(operations: [query]), storageURL: file)
        let valid = try evidence(plan: plan, document: bytes, outputs: outputs)
        XCTAssertEqual(assessment(plan, receipts: valid).summary, .passed)
        var mismatches: [[AutomationSegmentReceipt]] = []
        var changed = valid; changed[1].scope.runId = "other"; mismatches.append(changed)
        changed = valid; changed[1].environmentID = "other"; mismatches.append(changed)
        changed = valid; changed[1].verifiedOutputs = [:]; mismatches.append(changed)
        // Keep the actual false output and matching proof, but lie in the visible
        // observation. It must never be promoted to a passing durable predicate.
        let falseBytes = try document(selected: false)
        try falseBytes.write(to: file)
        let (_, falseOutputs) = try reader.snapshot(program: .init(operations: [query]), storageURL: file)
        var tampered = try evidence(plan: plan, document: falseBytes, outputs: falseOutputs)
        tampered[1].observations[0].value = valid[1].observations[0].value
        mismatches.append(tampered)
        changed = valid; changed[0].scope.leaseGeneration = 3; mismatches.append(changed)
        changed = valid; changed[1].durableStateRead = nil; mismatches.append(changed)
        changed = valid; changed.append(valid[1]); mismatches.append(changed)
        changed = valid; changed[1].durableStateRead = .init(scope: valid[1].scope, planDigest: String(repeating: "c", count: 64),
            recipeDigest: String(repeating: "d", count: 64), documentDigest: AutomationArtifactRegistry.digest(bytes), outputsDigest: try AutomationDurableStateReadReceipt.outputsDigest(outputs)); mismatches.append(changed)
        for receipts in mismatches { XCTAssertNotEqual(assessment(plan, receipts: receipts).summary, .passed) }
    }
    func testProfileScopeAndMappingAreNotCallerSelectedDurabilityAndOrdinaryQueriesStayAppState() throws {
        try reader.validateIdentity()
        var schema = profile.schema(); schema.storagePath = "/arbitrary/copy.json"
        let counterfeit = AutomationDurableStateReader(profileID: profile.id, catalogDigest: reader.catalogDigest, hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest, app: app, target: target, environmentID: "fixture",
            sourceManifestPath: reader.sourceManifestPath, sourceFiles: reader.sourceFiles, declaration: schema)
        XCTAssertThrowsError(try counterfeit.validateIdentity())
        let traversal = AutomationDurableStateReader(profileID: profile.id, catalogDigest: reader.catalogDigest,
            hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest,
            app: app, target: target, environmentID: "fixture", sourceManifestPath: "/fixture/source/../source-manifest.json",
            sourceFiles: reader.sourceFiles, declaration: reader.declaration)
        XCTAssertThrowsError(try traversal.validateIdentity())
        XCTAssertThrowsError(try reader.verifyDeclarationAndProduct()) // No fabricated installed product qualification.
        var durable = try plan(), segment = durable.observations[0]
        segment.effects.insert(.fixtureWrite)
        XCTAssertThrowsError(try reader.validate(plan: durable, segment: segment))
        segment = durable.observations[0]; segment.kind = .systemQuery
        XCTAssertThrowsError(try reader.validate(plan: durable, segment: segment))
        durable.observations[0].kind = .systemQuery; durable.observations[0].durableStateReader = nil
        for index in durable.requirements.indices { durable.requirements[index].proof = .appState }
        let root = try directory(), file = root.appendingPathComponent("state.json")
        try document(selected: true).write(to: file)
        let (_, outputs) = try reader.snapshot(program: .init(operations: [query]), storageURL: file)
        let observation = AutomationObservation(id: "read", app: app, target: target, environmentID: "fixture", attemptID: "attempt", stepID: "read",
            route: .systemQuery, proof: .appState, value: outputs["records"]!)
        XCTAssertEqual(AutomationAssessment.assess(plan: durable, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true,
            observations: [observation]).summary, .passed)
    }

    private func artifacts(for reader: AutomationDurableStateReader) throws -> AutomationPreparedMacBuildArtifacts {
        let fields: [String: Any] = ["schemaVersion": 1, "hostProductDigest": reader.hostProductDigest, "xctestrunDigest": reader.hostXctestrunDigest,
            "catalogDigest": reader.catalogDigest, "catalogSurfaceDigest": String(repeating: "f", count: 64), "hostTemplateDigest": String(repeating: "a", count: 64)]
        return try JSONDecoder().decode(AutomationPreparedMacBuildArtifacts.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func testCompatibleChangedProductRebindsReaderWhilePreservingOracleAndActualStorageProjection() throws {
        var beforeApp = app; beforeApp.productDigestVersion = 2
        let beforeReader = AutomationDurableStateReader(profileID: reader.profileID, catalogDigest: reader.catalogDigest,
            hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest,
            app: beforeApp, target: target, environmentID: "fixture", sourceManifestPath: reader.sourceManifestPath,
            sourceFiles: reader.sourceFiles, declaration: reader.declaration)
        var before = try plan(); before.app = beforeApp
        before.provenance.removeValue(forKey: "apple.macHostProductDigest"); before.provenance.removeValue(forKey: "apple.macXctestrunDigest")
        before.preparedMacBuildArtifacts = try artifacts(for: beforeReader)
        before.observations[0].durableStateReader = beforeReader
        let baseline = try AutomationFrozenCase(plan: before)
        var afterApp = beforeApp; afterApp.productDigest = String(repeating: "1", count: 64)
        afterApp.sourceManifestDigest = String(repeating: "2", count: 64); afterApp.canonicalBundlePath = "/after/Product.app"
        let afterReader = AutomationDurableStateReader(profileID: reader.profileID, catalogDigest: String(repeating: "3", count: 64),
            hostProductDigest: String(repeating: "4", count: 64), hostXctestrunDigest: String(repeating: "5", count: 64),
            app: afterApp, target: target, environmentID: "fixture", sourceManifestPath: "/after/source-manifest.json",
            sourceFiles: Dictionary(uniqueKeysWithValues: profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }.map { ("/after/source/" + $0.key, $0.value) }), declaration: reader.declaration)
        var after = before; after.app = afterApp; after.revision += 1; after.preparedMacBuildArtifacts = try artifacts(for: afterReader)
        after = try AutomationDurableStateReader.replacingReaders(in: after, with: afterReader)
        let candidate = try AutomationFrozenCase(plan: after)
        try AutomationFixContract.validate(baseline: baseline, candidate: candidate)
        XCTAssertEqual(baseline.oracleDigest, candidate.oracleDigest); XCTAssertEqual(baseline.contractDigest, candidate.contractDigest)
        XCTAssertEqual(beforeReader.declaration, afterReader.declaration)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: baseline, app: afterApp)) // App bytes alone cannot qualify the changed reader.
        let root = try directory(), file = root.appendingPathComponent("state.json")
        for (current, saved, expected) in [(before, false, AttemptResult.Summary.assertionFailed), (after, true, .passed)] {
            try document(selected: saved).write(to: file)
            let (bytes, outputs) = try current.observations[0].durableStateReader!.snapshot(program: .init(operations: [query]), storageURL: file)
            XCTAssertEqual(assessment(current, receipts: try evidence(plan: current, document: bytes, outputs: outputs)).summary, expected)
        }
        var changedSchema = afterReader.declaration; changedSchema.propertyFields["completed"] = "other"
        let unknown = AutomationDurableStateReader(profileID: reader.profileID, catalogDigest: afterReader.catalogDigest,
            hostProductDigest: afterReader.hostProductDigest, hostXctestrunDigest: afterReader.hostXctestrunDigest, app: afterApp,
            target: target, environmentID: "fixture", sourceManifestPath: afterReader.sourceManifestPath, sourceFiles: afterReader.sourceFiles, declaration: changedSchema)
        XCTAssertThrowsError(try AutomationDurableStateReader.replacingReaders(in: after, with: unknown))
    }
    func testFrozenSourceVerificationSurvivesOriginalEditButRejectsChangedRetainedProducer() throws {
        let root = try directory(), original = root.appendingPathComponent("original"), session = root.appendingPathComponent("retained")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("Verification/Automation/Fixtures/DuplicateTasks")
        for relative in profile.sourceDigests.keys {
            let destination = original.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(relative), to: destination)
        }
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        var capturedApp = app; capturedApp.sourceManifestDigest = try manifest.digest
        let frozen = AutomationDurableStateReader(profileID: reader.profileID, catalogDigest: reader.catalogDigest,
            hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest,
            app: capturedApp, target: target, environmentID: "fixture", sourceManifestPath: session.appendingPathComponent("source-manifest.json").path,
            sourceFiles: Dictionary(uniqueKeysWithValues: profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }.map { (session.appendingPathComponent("source/" + $0.key).path, $0.value) }), declaration: reader.declaration)
        try Data("changed original checkout".utf8).write(to: original.appendingPathComponent("App/TaskRepository.swift"))
        // Associated-host generation rewrites the captured project; the original
        // reviewed project fingerprint remains authoritative in the manifest.
        try Data("host-rewritten project".utf8).write(to: session.appendingPathComponent("source/DuplicateTasks.xcodeproj/project.pbxproj"))
        XCTAssertNoThrow(try frozen.verifyFrozenSources())
        // An alias is rejected at actual verification even when its lexical
        // shape and expected source fingerprints are otherwise well formed.
        let linkedSession = root.appendingPathComponent("retained-alias")
        try FileManager.default.createSymbolicLink(at: linkedSession, withDestinationURL: session)
        let aliased = AutomationDurableStateReader(profileID: reader.profileID, catalogDigest: reader.catalogDigest,
            hostProductDigest: reader.hostProductDigest, hostXctestrunDigest: reader.hostXctestrunDigest,
            app: capturedApp, target: target, environmentID: "fixture", sourceManifestPath: linkedSession.appendingPathComponent("source-manifest.json").path,
            sourceFiles: Dictionary(uniqueKeysWithValues: profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }.map { (linkedSession.appendingPathComponent("source/" + $0.key).path, $0.value) }), declaration: reader.declaration)
        XCTAssertThrowsError(try aliased.verifyFrozenSources())
        try Data("changed frozen producer".utf8).write(to: session.appendingPathComponent("source/App/TaskRepository.swift"))
        XCTAssertThrowsError(try frozen.verifyFrozenSources())
    }
    private actor NoSubjectDispatch: AutomationRouteDriver {
        func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
            throw AutomationContractError.missingEvidence("No subject runtime in storage contract tests")
        }
        func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
            throw AutomationContractError.missingEvidence("No subject runtime in storage contract tests")
        }
        func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
            .init(commandsDrained: false, runnerTerminated: false)
        }
    }
    func testDriverRejectsStaleLeaseWrongScopeAndRepeatedIssueWithoutTouchingSubject() async throws {
        let plan = try plan(), root = try directory(), segment = plan.observations[0]
        let leases = AutomationDeviceLeaseManager(), artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "fixture", effects: [.observe], maximumActions: 1, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = AutomationDurableStateRouteDriver(underlying: NoSubjectDispatch(), approval: approval, leases: leases, artifacts: artifacts)
        let stale = try await leases.acquire(runID: "run", target: target, control: .system)
        try await leases.release(stale, commandsDrained: true, ownedRunnerTerminated: true)
        let current = try await leases.acquire(runID: "run", target: target, control: .system)
        let staleScope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: segment.id, leaseGeneration: stale.generation)
        do { try await driver.acquire(plan: plan, segment: segment, scope: staleScope, lease: stale); XCTFail("Stale lease admitted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let abandoned = await driver.release(scope: staleScope, lease: stale)
        XCTAssertTrue(abandoned.commandsDrained)
        var scope = AutomationScope(runID: "other", attemptID: "attempt", segmentID: segment.id, leaseGeneration: current.generation)
        do { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: current); XCTFail("Foreign run admitted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        scope.runId = "run"
        try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: current)
        do { _ = try await driver.execute(plan: plan, segment: segment, scope: scope, lease: current); XCTFail("Synthetic product produced durable evidence") }
        catch { } // Exact source/product revalidation fails before any subject or data-file access.
        do { _ = try await driver.execute(plan: plan, segment: segment, scope: scope, lease: current); XCTFail("Read issue was retried") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let released = await driver.release(scope: scope, lease: current)
        XCTAssertTrue(released.commandsDrained); XCTAssertTrue(released.runnerTerminated)
        try await leases.release(current, commandsDrained: released.commandsDrained, ownedRunnerTerminated: released.runnerTerminated)
    }

}
#endif
