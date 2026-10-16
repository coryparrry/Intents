#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import IntentsAutomationCore

final class AutomationInstalledSubjectVerifierTests: XCTestCase {
    private let mac = TargetIdentity(id: "mac", kind: .nativeMac, loginSession: "test")
    private let simulator = TargetIdentity(id: "6F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B", kind: .simulator)
    private let physical = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
    private let unavailable = AutomationContractError.missingEvidence("Installed product bytes unavailable for this target")

    private func bundle(identifier: String = "example.Subject") throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/installed-subject-" + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try writeInfo(identifier: identifier, root: root)
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: root.appendingPathComponent("Contents/MacOS/Subject"))
        return root
    }
    private func writeInfo(identifier: String, root: URL) throws {
        let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": identifier, "CFBundleExecutable": "Subject"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
    }
    private func macApp(_ root: URL?, digest: String?, bundleID: String = "example.Subject") -> AppIdentity {
        var app = AppIdentity(logicalID: "subject", bundleID: bundleID, platform: "macos", productDigest: digest)
        app.canonicalBundlePath = root?.path; app.productDigestVersion = 2
        return app
    }
    private func verifier(_ workspace: URL = URL(fileURLWithPath: "/private/tmp")) -> AutomationInstalledSubjectVerifier {
        AutomationInstalledSubjectVerifier(developerDirectory: URL(fileURLWithPath: "/private/tmp/missing-developer-" + UUID().uuidString), workspace: workspace)
    }
    private func simulatorBundle(identifier: String = "example.Subject") throws -> (URL, AppIdentity) {
        let root = try bundle(identifier: identifier)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Contents/Info.plist"), to: root.appendingPathComponent("Info.plist"))
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios")
        app.productDigestVersion = 2
        app.productDigest = try AutomationProductDigest.compute(bundle: root, version: 2)
        return (root, app)
    }
    private func simulatorVerifier(_ root: URL, query: InstalledSubjectQuery, maximum: Duration? = nil,
                                   budget: AutomationCampaignBudget? = nil) -> AutomationInstalledSubjectVerifier {
        var verifier = AutomationInstalledSubjectVerifier(developerDirectory: root, workspace: root, campaignBudget: budget)
        if let maximum { verifier.maximumQueryDuration = maximum }
        verifier.runQuery = { try await query.run($0, $1, $2, $3, $4) }
        return verifier
    }
    private func assertRefuses(_ app: AppIdentity, on target: TargetIdentity, with expected: AutomationContractError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await verifier().verify(app: app, target: target); XCTFail("Accepted \(app.bundleID) on \(target.kind)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, expected, file: file, line: line) }
    }

    func testMatchingNativeMacBundleIsAccepted() async throws {
        let root = try bundle()
        try await verifier(root).verify(app: macApp(root, digest: AutomationProductDigest.compute(bundle: root, version: 2)), target: mac)
    }
    func testIdentityMustNameABundleForTheTargetPlatform() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        var iosOnMac = macApp(root, digest: digest); iosOnMac.platform = "ios"
        await assertRefuses(iosOnMac, on: mac, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest), on: simulator, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest), on: physical, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest, bundleID: ""), on: mac, with: .invalidIdentity)
        await assertRefuses(AppIdentity(logicalID: "subject", bundleID: "", platform: "ios"), on: simulator, with: .invalidIdentity)
    }
    func testNativeMacDigestRequiresAnExistingCanonicalBundlePath() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        await assertRefuses(macApp(nil, digest: digest), on: mac, with: .invalidIdentity)
        await assertRefuses(macApp(root.appendingPathComponent("Missing.app"), digest: digest), on: mac, with: .invalidIdentity)
    }
    func testChangedBundleBytesConflictWithTheApprovedDigest() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,1]).write(to: root.appendingPathComponent("Contents/MacOS/Subject"))
        XCTAssertNotEqual(digest, try AutomationProductDigest.compute(bundle: root, version: 2))
        await assertRefuses(macApp(root, digest: digest), on: mac, with: .conflictingOperation)
        let stale = try bundle()
        await assertRefuses(macApp(stale, digest: String(repeating: "0", count: 64)), on: mac, with: .conflictingOperation)
    }
    func testMatchingDigestForADifferentBundleIdentifierConflicts() async throws {
        let root = try bundle(identifier: "example.Foreign")
        let digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        await assertRefuses(macApp(root, digest: digest, bundleID: "example.Subject"), on: mac, with: .conflictingOperation)
        try writeInfo(identifier: "example.Subject", root: root)
        let rebuilt = try AutomationProductDigest.compute(bundle: root, version: 2)
        XCTAssertNotEqual(digest, rebuilt)
        await assertRefuses(macApp(root, digest: digest, bundleID: "example.Foreign"), on: mac, with: .conflictingOperation)
        try await verifier(root).verify(app: macApp(root, digest: rebuilt), target: mac)
    }
    func testDigestOnTargetsWithoutReadableInstalledBytesIsRefused() async {
        let digest = String(repeating: "a", count: 64)
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: digest)
        await assertRefuses(app, on: physical, with: unavailable)
        await assertRefuses(app, on: .init(id: "booted", kind: .simulator), with: unavailable)
        await assertRefuses(AppIdentity(logicalID: "subject", bundleID: "example Subject;rm", platform: "ios", productDigest: digest), on: simulator, with: unavailable)
    }
    func testUndigestedSubjectsAreAcceptedOnlyOffPhysicalTargets() async throws {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios")
        try await verifier().verify(app: app, target: simulator)
        try await verifier().verify(app: app, target: .init(id: "not-a-udid", kind: .simulator))
        try await verifier().verify(app: macApp(nil, digest: nil), target: mac)
        await assertRefuses(app, on: physical, with: .missingEvidence("Physical apps require positive installed-bundle presence evidence"))
    }
    func testSimulatorQueryUsesDefaultOrApprovedBudgetAndExactInstalledSubject() async throws {
        let (root, app) = try simulatorBundle()
        for maximum in [nil, .seconds(600)] as [Duration?] {
            let query = InstalledSubjectQuery(path: root.path + "\n")
            try await simulatorVerifier(root, query: query, maximum: maximum).verify(app: app, target: simulator)
            let calls = await query.calls
            XCTAssertEqual(calls.count, 1)
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call.executable.path, "/usr/bin/xcrun")
            XCTAssertEqual(call.arguments, ["simctl", "get_app_container", simulator.id, app.bundleID, "app"])
            XCTAssertEqual(call.directory, root)
            XCTAssertEqual(call.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": root.path,
                                               "HOME": root.path, "TMPDIR": root.path])
            XCTAssertEqual(call.timeout, maximum ?? .seconds(15))
        }
    }
    func testSimulatorQueryClampsToRemainingCampaignAndRefusesExpiredCampaign() async throws {
        let (root, app) = try simulatorBundle()
        let start = ContinuousClock.now
        let clock = Mutex(start)
        var limits = AutomationCampaignLimits(); limits.wallClockSeconds = 100
        let budget = try AutomationCampaignBudget(limits: limits, now: { clock.withLock { $0 } })
        clock.withLock { $0 = start.advanced(by: .seconds(70)) }
        let query = InstalledSubjectQuery(path: root.path)
        let verifier = simulatorVerifier(root, query: query, maximum: .seconds(600), budget: budget)
        try await verifier.verify(app: app, target: simulator)
        let calls = await query.calls
        XCTAssertEqual(calls.map(\.timeout), [.seconds(30)])
        clock.withLock { $0 = start.advanced(by: .seconds(100)) }
        do { try await verifier.verify(app: app, target: simulator); XCTFail("Expired campaign queried installed bytes") }
        catch { XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted("wall clock")) }
        let finalCalls = await query.calls
        XCTAssertEqual(finalCalls.count, 1)
    }
    func testApprovedQueryBudgetStillRequiresMatchingBytesAndBundleIdentifier() async throws {
        for foreignIdentifier in [false, true] {
            let (root, approved) = try simulatorBundle(identifier: foreignIdentifier ? "example.Foreign" : "example.Subject")
            var app = approved
            if !foreignIdentifier { app.productDigest = String(repeating: "0", count: 64) }
            let query = InstalledSubjectQuery(path: root.path)
            do {
                try await simulatorVerifier(root, query: query, maximum: .seconds(600)).verify(app: app, target: simulator)
                XCTFail("Accepted mismatching installed subject")
            } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
            let calls = await query.calls
            XCTAssertEqual(calls.count, 1)
        }
    }
    func testQueryTimeoutPropagatesWithoutRetry() async throws {
        let (root, app) = try simulatorBundle(), query = InstalledSubjectQuery(path: "", failure: .timedOut)
        do {
            try await simulatorVerifier(root, query: query, maximum: .seconds(600)).verify(app: app, target: simulator)
            XCTFail("Accepted timed out lookup")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let calls = await query.calls
        XCTAssertEqual(calls.map(\.timeout), [.seconds(600)])
    }
    func testApprovedQueryBudgetDoesNotAcceptFailedOrMalformedLookupEvidence() async throws {
        let (root, app) = try simulatorBundle()
        let results: [(String, Int32, Bool)] = [("", 0, false), ("relative.app", 0, false),
            (root.path + "\n/another.app", 0, false), (String(repeating: "/", count: 4097), 0, false),
            (root.path, 1, false), (root.path, 0, true)]
        for (path, status, truncated) in results {
            let query = InstalledSubjectQuery(path: path, exitStatus: status, logsTruncated: truncated)
            do {
                try await simulatorVerifier(root, query: query, maximum: .seconds(600)).verify(app: app, target: simulator)
                XCTFail("Accepted failed or malformed installed lookup")
            } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Installed product identity unavailable")) }
            let calls = await query.calls
            XCTAssertEqual(calls.count, 1)
        }
    }
    func testCancellationBeforeOrDuringQueryIsNotAcceptedOrRetried() async throws {
        let (root, app) = try simulatorBundle(), target = simulator
        for beforeQuery in [true, false] {
            let query = InstalledSubjectQuery(path: root.path, cancelDuringQuery: !beforeQuery)
            let verifier = simulatorVerifier(root, query: query, maximum: .seconds(600))
            let task = Task {
                if beforeQuery { withUnsafeCurrentTask { $0?.cancel() } }
                try await verifier.verify(app: app, target: target)
            }
            do { try await task.value; XCTFail("Accepted cancelled lookup") }
            catch { XCTAssertTrue(error is CancellationError) }
            let calls = await query.calls
            XCTAssertEqual(calls.count, beforeQuery ? 0 : 1)
        }
    }
}

private actor InstalledSubjectQuery {
    struct Call: Sendable {
        var executable: URL
        var arguments: [String]
        var directory: URL
        var environment: [String: String]
        var timeout: Duration
    }
    private(set) var calls: [Call] = []
    let path: String
    let failure: AutomationRPCError?
    let cancelDuringQuery: Bool
    let exitStatus: Int32
    let logsTruncated: Bool
    init(path: String, failure: AutomationRPCError? = nil, cancelDuringQuery: Bool = false,
         exitStatus: Int32 = 0, logsTruncated: Bool = false) {
        self.path = path; self.failure = failure; self.cancelDuringQuery = cancelDuringQuery
        self.exitStatus = exitStatus; self.logsTruncated = logsTruncated
    }
    func run(_ executable: URL, _ arguments: [String], _ directory: URL, _ environment: [String: String],
             _ timeout: Duration) throws -> AutomationOwnedCommand.Result {
        calls.append(.init(executable: executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout))
        if let failure { throw failure }
        if cancelDuringQuery { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(exitStatus: exitStatus, stdout: Data(path.utf8), stderr: Data(), logsTruncated: logsTruncated)
    }
}
#endif
