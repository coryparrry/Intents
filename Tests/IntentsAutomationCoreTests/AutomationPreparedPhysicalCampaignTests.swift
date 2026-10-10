#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedPhysicalCampaignTests: XCTestCase, @unchecked Sendable {
    typealias Controller = AutomationPhysicalRunnerVerifier.Controller
    typealias Observation = AutomationPhysicalRunnerVerifier.BatchObservation
    private static let device = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"
    private let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)

    struct Harness {
        let root: URL, session: URL, attempts: URL, developer: URL, subject: URL
        let prepared: AutomationPreparedApplication
        let plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile
        let leases: AutomationDeviceLeaseManager
    }

    private actor Device {
        enum Mode { case released, releaseUnverified }
        let mode: Mode
        var inspections = 0, drains = 0
        init(_ mode: Mode = .released) { self.mode = mode }
        func inspect(_ target: TargetIdentity, _ controllers: [Controller]) throws -> Observation {
            inspections += 1
            if mode == .releaseUnverified, inspections > 1 { throw AutomationContractError.terminationUnverified }
            return .init(targetID: target.id, deviceIdentifier: AutomationPreparedPhysicalCampaignTests.device,
                controllers: controllers.map { .init(controller: $0, absent: true) },
                appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
        }
        func drain() -> Bool { drains += 1; return true }
        func counts() -> (inspections: Int, drains: Int) { (inspections, drains) }
    }

    private actor Installer {
        let stopSucceeds: Bool
        var runs = 0, stops = 0
        init(stopSucceeds: Bool = true) { self.stopSucceeds = stopSucceeds }
        func run() throws -> AutomationOwnedCommand.Result {
            runs += 1
            throw AutomationContractError.missingEvidence("synthetic physical install failure")
        }
        func stop() -> Bool { stops += 1; return stopSucceeds }
        func counts() -> (runs: Int, stops: Int) { (runs, stops) }
    }

    private func components(_ device: Device = Device(), _ installer: Installer = Installer()) -> AutomationPreparedPhysicalCampaign.Components {
        .init(deviceRelease: { _, _, controllers in
            try AutomationPhysicalDeviceReleaseVerifier(controllers: controllers,
                inspect: { try await device.inspect($0, $1) }, drain: { await device.drain() })
        }, installer: { state, developer in
            try AutomationPhysicalApplicationInstaller(workspace: state, developerDirectory: developer, commands: .init(
                run: { _, _, _ in try await installer.run() }, stop: { await installer.stop() },
                logs: { .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false) }))
        })
    }

    private func fixture(includesSiri: Bool = true, register: Bool = true) async throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("prepared-physical-campaign-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session"), attempts = root.appendingPathComponent("attempts")
        let developer = root.appendingPathComponent("Developer")
        for directory in [session, attempts, developer] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        let subject = session.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.Subject",
            "CFBundleExecutable": "Subject", "CFBundleSupportedPlatforms": ["iPhoneOS"]], format: .binary, options: 0)
            .write(to: subject.appendingPathComponent("Info.plist"))
        try AutomationPhysicalExecutableTests.binary().write(to: subject.appendingPathComponent("Subject"))
        try Data("synthetic resource".utf8).write(to: subject.appendingPathComponent("Resource.txt"))
        let app = try AutomationInstalledUIApplication(bundleURL: subject, target: target).app

        let host = session.appendingPathComponent("OwnedHost-Runner.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Host.xctrunner", "CFBundleExecutable": "OwnedHost-Runner"],
            format: .xml, options: 0).write(to: host.appendingPathComponent("Info.plist"))
        try Data("synthetic payload".utf8).write(to: host.appendingPathComponent("OwnedHost-Runner"))
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "IsUITestBundle": true, "TestHostPath": "__TESTROOT__/OwnedHost-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app"]
        let xctestrun = try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry], format: .xml, options: 0)
        let testFile = session.appendingPathComponent("host.xctestrun"); try xctestrun.write(to: testFile)

        let sources = session.appendingPathComponent("generated-host/OwnedHost/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        var records: [String: String] = [:]
        for file in AutomationHostGenerator.physicalTemplateFiles {
            try FileManager.default.copyItem(at: templates.appendingPathComponent(file), to: sources.appendingPathComponent(file))
            records[file] = AutomationArtifactRegistry.digest(try Data(contentsOf: templates.appendingPathComponent(file)))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]

        let hostRecord = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: testFile.path,
            xctestrunDigest: AutomationArtifactRegistry.digest(xctestrun), subjectProductPath: subject.path, hostBundlePath: host.path,
            hostProductDigest: try AutomationProductDigest.compute(bundle: host, version: 1), hostBundleID: "example.Host.xctrunner", testTarget: "OwnedHost")
        let generated = AutomationGeneratedHost(projectPath: "synthetic", scheme: "OwnedHost", targetID: "HOST", bundleID: hostRecord.hostBundleID,
            configuration: "Debug", templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(records)), includesSiri: includesSiri)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: session.path, files: [], directories: [], excludedPaths: []),
            generatedHost: generated, host: hostRecord, catalog: catalog,
            buildLogPath: session.appendingPathComponent("build.log").path, buildLogTruncated: false)
        if register { await AutomationPreparedCodecAuthority.shared.register(prepared) }

        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let capabilities = CapabilityProfile(records: ["apple.entity.query": .init(state: .available, reason: "test", probeVersion: "test", evidence: []),
            "siri.recognizedText.api": .init(state: .available, reason: "test", probeVersion: "test", evidence: []),
            "siri.actualRoute": .init(state: .unknown, reason: "unqualified", probeVersion: "test", evidence: [])])
        let plan = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title",
            recordName: "Approved disposable task", stateProperty: "completed", initialState: false, expectedState: true,
            request: "Complete Approved disposable task in Example", approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return .init(root: root, session: session, attempts: attempts, developer: developer, subject: subject, prepared: prepared,
            plan: plan, approval: approval, capabilities: capabilities, leases: AutomationDeviceLeaseManager())
    }

    private func approved(_ plan: AutomationCase, _ approval: RunApproval) throws -> RunApproval {
        var approval = approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan); return approval
    }

    private func run(_ h: Harness, prepared: AutomationPreparedApplication? = nil, plan: AutomationCase? = nil,
                     approval: RunApproval? = nil, attemptID: String = "attempt", qualify: Bool = true,
                     components: AutomationPreparedPhysicalCampaign.Components) async throws -> AutomationAttemptReport {
        let plan = plan ?? h.plan, approval = approval ?? h.approval
        var authority: AutomationSiriRouteAuthority?
        if qualify { authority = try? AutomationSiriRouteAuthority(plan: plan, approval: approval) }
        return try await AutomationPreparedPhysicalCampaign.run(prepared: prepared ?? h.prepared, plan: plan, approval: approval,
            capabilities: h.capabilities, attemptID: attemptID, root: h.attempts, developer: h.developer, leases: h.leases,
            runtime: nil, campaignBudget: nil, siriAuthority: authority, components: components)
    }

    private func assertNothingReserved(_ h: Harness, _ device: Device, _ installer: Installer, allowStateDirectory: String? = nil,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.attempts.path)
        XCTAssertEqual(Set(entries), Set([allowStateDirectory].compactMap { $0 }), file: file, line: line)
        if let allowStateDirectory {
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.attempts.appendingPathComponent(allowStateDirectory + "/journal.json").path), file: file, line: line)
        }
        let absent = try await h.leases.campaignAbsent(target: target); XCTAssertTrue(absent, file: file, line: line)
        let deviceCounts = await device.counts(), installerCounts = await installer.counts()
        XCTAssertEqual(deviceCounts.inspections, 0, file: file, line: line); XCTAssertEqual(installerCounts.runs, 0, file: file, line: line)
    }

    private func assertRetained(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async throws {
        let absent = try await h.leases.campaignAbsent(target: target); XCTAssertFalse(absent, file: file, line: line)
        do { try await h.leases.releaseCampaign(runID: h.approval.runID, target: target); XCTFail("Held lease must fence the campaign", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy, file: file, line: line) }
        do { try await h.leases.reserveCampaign(runID: "next-run", target: target); XCTFail("Retained device must stay reserved", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy, file: file, line: line) }
    }

    private func persistedReport(_ h: Harness, _ attemptID: String = "attempt") throws -> AutomationAttemptReport {
        try JSONDecoder().decode(AutomationAttemptReport.self,
            from: Data(contentsOf: h.attempts.appendingPathComponent(attemptID + "/report.json")))
    }

    func testIdentityAndApprovalDenialsPrecedeStateAndDeviceReservation() async throws {
        let h = try await fixture()
        var otherApp = h.plan; otherApp.app.logicalID = "other-subject"
        var reusable = h.approval; reusable.disposable = false
        var withoutSiri = h.prepared; withoutSiri.generatedHost.includesSiri = false
        let otherApproval = try approved(otherApp, h.approval)
        let attempts: [(String, AutomationPreparedApplication?, AutomationCase?, RunApproval?)] = [
            ("../escape", nil, nil, nil), ("", nil, nil, nil), ("has space", nil, nil, nil),
            (String(repeating: "a", count: 129), nil, nil, nil), ("attempt", withoutSiri, nil, nil),
            ("attempt", nil, nil, reusable), ("attempt", nil, otherApp, otherApproval)]
        for (index, (attemptID, prepared, plan, approval)) in attempts.enumerated() {
            let device = Device(), installer = Installer()
            do {
                _ = try await run(h, prepared: prepared, plan: plan, approval: approval, attemptID: attemptID,
                    qualify: false, components: components(device, installer))
                XCTFail("denial \(index) was admitted")
            } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity, "denial \(index)") }
            try await assertNothingReserved(h, device, installer)
        }
    }

    func testUnregisteredPreparationIsRefusedBeforeStateOrDeviceReservation() async throws {
        let h = try await fixture(register: false), device = Device(), installer = Installer()
        do { _ = try await run(h, components: components(device, installer)); XCTFail("Unregistered preparation admitted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Prepare the exact physical host in this process before running")) }
        try await assertNothingReserved(h, device, installer)
    }

    func testSiriOutsideSubjectAndUIWithoutRuntimeAreRefusedBeforeStateOrDeviceReservation() async throws {
        let h = try await fixture()
        // Use a valid query subject so Siri qualification cannot reject the plan
        // before the cleanup/observation conditions under test are reached.
        var base = h.plan
        base.execution = h.plan.setup[0]
        base.execution.id = "subject-query"; base.execution.phase = .subject
        base.setup = []; base.observations = []; base.cleanup = []
        base.setupChecks = nil; base.requirements = []
        try PlanValidator.validate(base, approval: approved(base, h.approval), capabilities: h.capabilities)

        var lateSiri = base
        var siri = AutomationSegment(id: "late-siri", kind: .siriText, phase: .cleanup, operation: "submitRecognizedText",
            requiredCapabilities: ["siri.recognizedText.api"], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        siri.siriProgram = .init(request: "Open the approved fixture")
        lateSiri.cleanup.append(siri)
        var uiWithoutRuntime = base
        var observer = AutomationSegment(id: "ui-check", kind: .ui, phase: .observe, operation: "observe",
            requiredCapabilities: [], effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        observer.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty,
            locator: .init(.testId, "status"), property: "text")])
        uiWithoutRuntime.observations.append(observer)
        try PlanValidator.validate(uiWithoutRuntime, approval: approved(uiWithoutRuntime, h.approval), capabilities: h.capabilities)

        let denials: [(String, AutomationCase, AutomationContractError)] = [
            ("Siri cleanup", lateSiri, .invalidPlan("Siri requires one approved physical recognised-text subject request")),
            ("UI observation without runtime", uiWithoutRuntime, .missingEvidence("Mixed physical checks require the signed UI runtime")),
        ]
        for (name, plan, expected) in denials {
            let device = Device(), installer = Installer()
            let approval = try approved(plan, h.approval)
            do {
                _ = try await run(h, plan: plan, approval: approval, qualify: false, components: components(device, installer))
                XCTFail("\(name) admitted")
            } catch { XCTAssertEqual(error as? AutomationContractError, expected, name) }
            try await assertNothingReserved(h, device, installer)
        }
    }

    func testRuntimeProvenanceWithoutRuntimeIsRefusedBeforeJournalOrDeviceReservation() async throws {
        let h = try await fixture()
        for key in ["ui.runtimeTeamID", "ui.runtimeManifestDigest"] {
            var plan = h.plan; plan.provenance[key] = key == "ui.runtimeTeamID" ? "TEAMID1234" : String(repeating: "e", count: 64)
            let device = Device(), installer = Installer(), attemptID = "provenance-" + String(key.count)
            do {
                _ = try await run(h, plan: plan, approval: try approved(plan, h.approval), attemptID: attemptID, components: components(device, installer))
                XCTFail("\(key) admitted without a runtime")
            } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation, key) }
            try await assertNothingReserved(h, device, installer, allowStateDirectory: attemptID)
            try FileManager.default.removeItem(at: h.attempts.appendingPathComponent(attemptID))
        }
    }

    func testInstallFailureWithProvedCleanupReleasesLeaseAndCampaign() async throws {
        let h = try await fixture(), device = Device(), installer = Installer()
        let report = try await run(h, components: components(device, installer))
        XCTAssertEqual(report.attemptID, "attempt")
        XCTAssertEqual(report.result.summary, .infrastructureFailed)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.result.subjectCompleted)
        XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.receipts.isEmpty)
        XCTAssertEqual(try persistedReport(h), report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.attempts.appendingPathComponent("attempt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.attempts.appendingPathComponent("attempt/journal.json").path))
        let installerCounts = await installer.counts(), deviceCounts = await device.counts()
        XCTAssertEqual(installerCounts.runs, 1); XCTAssertEqual(installerCounts.stops, 2)
        XCTAssertEqual(deviceCounts.inspections, 2); XCTAssertEqual(deviceCounts.drains, 2)
        let absent = try await h.leases.campaignAbsent(target: target); XCTAssertTrue(absent)
        try await h.leases.reserveCampaign(runID: "next-run", target: target)
        try await h.leases.releaseCampaign(runID: "next-run", target: target)
        do { _ = try await run(h, components: components()); XCTFail("A recorded attempt directory must not be reused") }
        catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
    }

    func testUndrainedInstallerRetainsLeaseAndCampaignAsUnresolved() async throws {
        let h = try await fixture(), device = Device(), installer = Installer(stopSucceeds: false)
        let report = try await run(h, components: components(device, installer))
        XCTAssertEqual(report.result.summary, .unresolved)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.resourcesReleased); XCTAssertTrue(report.receipts.isEmpty)
        XCTAssertEqual(try persistedReport(h), report)
        let installerCounts = await installer.counts(); XCTAssertEqual(installerCounts.runs, 1); XCTAssertEqual(installerCounts.stops, 2)
        try await assertRetained(h)
    }

    func testUnverifiedControllerReleaseRetainsLeaseAndCampaignAsUnresolved() async throws {
        let h = try await fixture(), device = Device(.releaseUnverified), installer = Installer()
        let report = try await run(h, components: components(device, installer))
        XCTAssertEqual(report.result.summary, .unresolved)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.resourcesReleased); XCTAssertTrue(report.receipts.isEmpty)
        XCTAssertEqual(try persistedReport(h), report)
        let deviceCounts = await device.counts(); XCTAssertEqual(deviceCounts.inspections, 2)
        try await assertRetained(h)
    }

    func testFailedQualifiedRerunRevokesRecordedSiriAuthority() async throws {
        let h = try await fixture(), plan = h.plan, approval = h.approval
        func records(_ id: String, _ completed: Bool) -> AutomationValue {
            .array([.object(["entity": .entity(typeID: "TaskEntity", value: id),
                "properties": .object(["title": .text("Approved disposable task"), "completed": .bool(completed)])])])
        }
        let observation = AutomationObservation(id: plan.observations[0].id, app: plan.app, target: plan.target,
            environmentID: plan.environmentID, attemptID: "qualification", stepID: plan.observations[0].id,
            route: .systemQuery, proof: .appState, value: records("real-id", true))
        let segments = plan.setup + [plan.execution] + plan.observations
        let receipts = segments.enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: "qualification", segmentID: segment.id,
                leaseGeneration: index + 1), app: plan.app, target: plan.target, segmentID: segment.id,
                route: segment.kind, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [],
                artifact: segment.kind == .siriText ? "synthetic-submission-artifact" : nil,
                verifiedOutputs: segment.kind == .systemQuery ? ["record": records("real-id", segment.phase == .observe)] : nil,
                environmentID: plan.environmentID)
        }
        let result = AutomationAssessment.assess(plan: plan, attemptID: "qualification", subjectDispatched: true,
            subjectCompleted: true, observations: [observation], receipts: receipts, runID: approval.runID)
        XCTAssertEqual(result.summary, .passed)
        let passing = AutomationAttemptReport(attemptID: "qualification", result: result, receipts: receipts, resourcesReleased: true)
        try await AutomationSiriQualificationAuthority.shared.record(prepared: h.prepared, plan: plan, approval: approval, report: passing,
            submission: .init(runner: .init(pid: 42, startIdentity: "1:2"), executablePath: "/synthetic",
                requestDigest: plan.execution.siriProgram!.requestDigest, osBuild: "24B5028f"))
        let recorded = await AutomationSiriQualificationAuthority.shared.admission(prepared: h.prepared, plan: plan, approval: approval)
        XCTAssertEqual(recorded?.isQualification, false)

        let report = try await run(h, qualify: false, components: components())
        XCTAssertEqual(report.result.summary, .infrastructureFailed); XCTAssertTrue(report.resourcesReleased)
        let revoked = await AutomationSiriQualificationAuthority.shared.admission(prepared: h.prepared, plan: plan, approval: approval)
        XCTAssertNil(revoked)
    }

    func testCampaignReleaseAlwaysChecksEveryControllerAndRejectsForeignOrDuplicateScopes() async throws {
        let controllers = [Controller(bundleID: "example.Host.xctrunner", executableName: "OwnedHost-Runner"),
                           Controller(bundleID: "example.UI.xctrunner", executableName: "UI-Runner"),
                           Controller(bundleID: "example.Sidecar", executableName: "Sidecar")]
        actor Spy {
            var scopes: [[String]] = []
            func inspect(_ target: TargetIdentity, _ controllers: [Controller]) -> Observation {
                scopes.append(controllers.map(\.bundleID))
                return .init(targetID: target.id, deviceIdentifier: AutomationPreparedPhysicalCampaignTests.device,
                    controllers: controllers.map { .init(controller: $0, absent: true) },
                    appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
            }
            func calls() -> [[String]] { scopes }
        }
        let spy = Spy(), ids = controllers.map(\.bundleID)
        let release = AutomationPhysicalCampaignRelease(verifier: try AutomationPhysicalDeviceReleaseVerifier(controllers: controllers,
            inspect: { await spy.inspect($0, $1) }, drain: { true }), identifiers: ids)
        for invalid in [["example.Foreign"], [ids[0], ids[0]], ids + ["example.Foreign"]] {
            do { try await release.prepare(target: target, controllerBundleIDs: invalid); XCTFail("\(invalid) prepared") }
            catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        }
        let calls = await spy.calls(); XCTAssertTrue(calls.isEmpty)
        let unprepared = await release.verifyReleased(target: target, controllerBundleIDs: [])
        XCTAssertFalse(unprepared)

        try await release.prepare(target: target, controllerBundleIDs: [])
        for subset in [[], [ids[0]], [ids[2], ids[1]], ids] {
            let released = await release.verifyReleased(target: target, controllerBundleIDs: subset)
            XCTAssertTrue(released, "\(subset)")
        }
        let before = await spy.calls().count
        for invalid in [["example.Foreign"], [ids[1], ids[1]]] {
            let released = await release.verifyReleased(target: target, controllerBundleIDs: invalid)
            XCTAssertFalse(released, "\(invalid)")
        }
        let after = await spy.calls()
        XCTAssertEqual(after.count, before); XCTAssertEqual(after.count, 5)
        XCTAssertTrue(after.allSatisfy { $0 == ids }, "Every check must inspect the complete campaign controller set")
    }

    private static func inventory(arguments: [String], bundleID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "jsonVersion": 5,
            "commandType": "devicectl.device.info.apps", "arguments": arguments], "result": ["deviceIdentifier": device,
            "defaultAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true,
            "apps": [["bundleIdentifier": bundleID, "url": "file:///private/var/containers/Bundle/Application/Example/Subject.app"]]]])
    }

    private actor Inventory {
        let bundleID: String
        var calls = 0
        init(_ bundleID: String) { self.bundleID = bundleID }
        func run(_ invocation: AutomationPhysicalRunnerVerifier.InventoryInvocation) throws -> AutomationOwnedCommand.Result {
            calls += 1
            let index = try XCTUnwrap(invocation.arguments.firstIndex(of: "--json-output"))
            try AutomationPreparedPhysicalCampaignTests.inventory(arguments: invocation.arguments, bundleID: bundleID)
                .write(to: URL(fileURLWithPath: invocation.arguments[index + 1]), options: .withoutOverwriting)
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func count() -> Int { calls }
    }

    private func subjectVerifier(_ h: Harness, installedBundleID: String = "example.Subject") throws
        -> (AutomationPreparedPhysicalSubjectVerifier, Inventory, AutomationInstalledUIApplication) {
        let selected = try AutomationInstalledUIApplication.preparedPhysicalProduct(h.prepared)
        let args = ["devicectl", "device", "info", "apps", "--device", target.id, "--include-all-apps",
            "--json-output", "/private/tmp/discovery.json", "--timeout", "10", "--quiet"]
        let installed = try AutomationPhysicalInstalledUIApplication(bundleID: installedBundleID, target: target,
            inventory: .parse(Self.inventory(arguments: args, bundleID: installedBundleID), targetID: target.id))
        let commands = Inventory(installedBundleID)
        let positive = try AutomationPhysicalInstalledSubjectVerifier(selected: installed, workspace: h.root, developerDirectory: h.developer,
            commands: .init(run: { invocation, _ in try await commands.run(invocation) }, stop: { true }))
        return (.init(selected: selected, installed: installed, verifier: positive), commands, selected)
    }

    func testPreparedSubjectVerifierBindsSelectedBytesAndInstalledIdentity() async throws {
        let h = try await fixture()
        let (verifier, commands, selected) = try subjectVerifier(h)
        try await verifier.verify(app: selected.app, target: target)
        let verified = await commands.count(); XCTAssertEqual(verified, 1)

        var otherApp = selected.app; otherApp.logicalID = "other-subject"
        let otherTarget = TargetIdentity(id: "00008140-0000000000000000", kind: .physical)
        for (app, candidate) in [(otherApp, target), (selected.app, otherTarget)] {
            do { try await verifier.verify(app: app, target: candidate); XCTFail("Mismatched identity verified") }
            catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        }
        let afterMismatch = await commands.count(); XCTAssertEqual(afterMismatch, 1)

        let (foreign, foreignCommands, _) = try subjectVerifier(h, installedBundleID: "example.Other")
        do { try await foreign.verify(app: selected.app, target: target); XCTFail("Foreign installed bundle verified") }
        catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
        let foreignCalls = await foreignCommands.count(); XCTAssertEqual(foreignCalls, 0)

        try Data("changed resource".utf8).write(to: h.subject.appendingPathComponent("Resource.txt"))
        do { try await verifier.verify(app: selected.app, target: target); XCTFail("Changed selected bytes verified") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        let afterChange = await commands.count(); XCTAssertEqual(afterChange, 1)
    }
}
#endif
