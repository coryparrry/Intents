#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeCodecQualificationTests: XCTestCase, @unchecked Sendable {
    private final class MutableQualificationClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: ContinuousClock.Instant
        init(_ instant: ContinuousClock.Instant) { current = instant }
        func now() -> ContinuousClock.Instant { lock.withLock { current } }
        func advance(to instant: ContinuousClock.Instant) { lock.withLock { current = instant } }
    }
    private actor PendingContextValidation {
        var suspended = false
        private var resumeValidation: CheckedContinuation<Void, Never>?
        private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
        func validate() async {
            await withCheckedContinuation { continuation in
                suspended = true; resumeValidation = continuation
                suspensionWaiters.forEach { $0.resume() }; suspensionWaiters = []
            }
        }
        func waitUntilSuspended() async {
            if suspended { return }
            await withCheckedContinuation { suspensionWaiters.append($0) }
        }
        func resume() { resumeValidation?.resume(); resumeValidation = nil }
    }
    func testCodecProofExpiringDuringPendingContextValidationCannotGrant() async throws {
        let start = ContinuousClock.now, expires = start.advanced(by: .seconds(600))
        let clock = MutableQualificationClock(start), validation = PendingContextValidation()
        let result = Task {
            try await AutomationNativeCodecQualification.validateBeforeExpiry("live-proof", expires: expires,
                now: { clock.now() }, validation: { await validation.validate() })
        }
        await validation.waitUntilSuspended()
        clock.advance(to: expires.advanced(by: .nanoseconds(1)))
        await validation.resume()
        let observed = try await result.value
        XCTAssertNil(observed, "Successful validation cannot resurrect a proof which expired while awaiting it")
    }
    func testCurrentCodecProofSurvivesAwaitedContextValidation() async throws {
        let start = ContinuousClock.now, clock = MutableQualificationClock(start)
        let result = try await AutomationNativeCodecQualification.validateBeforeExpiry("live-proof", expires: start.advanced(by: .seconds(600)),
            now: { clock.now() }, validation: { clock.advance(to: start.advanced(by: .seconds(1))) })
        XCTAssertEqual(result, "live-proof")
    }

    func testNativeTemplateOverridesPreserveSharedSimulatorTemplates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/AutomationHost")
        var simulator: [String: String] = [:], native: [String: String] = [:]
        XCTAssertEqual(Set(AutomationHostGenerator.templateFiles), Set(["AutomationDateCodec.swift", "AutomationDurationCodec.swift",
            "AutomationCalendarCodec.swift", "AutomationURLCodec.swift", "AutomationIntentFileCodec.swift", "HostPlan.swift", "HostFixtureRegistration.swift", "HostReceipt.swift",
            "IntentDefinitionsHost.swift", "SegmentTests.swift", "UIHostPlan.swift", "UIStepTests.swift", "HostInputAdapterProbePlan.swift", "InputAdapterProbeTests.swift"]))
        XCTAssertEqual(AutomationHostGenerator.nativeTemplateOverrides, Set(["HostInputAdapterProbePlan.swift", "InputAdapterProbeTests.swift", "HostReceipt.swift", "SegmentTests.swift"]))
        XCTAssertEqual(Set(AutomationHostGenerator.physicalTemplateFiles), Set(AutomationHostGenerator.templateFiles + ["SiriSubmissionTests.swift"]))
        for file in AutomationHostGenerator.templateFiles {
            let simulatorPath = AutomationHostGenerator.templateRelativePath(file, macOS: false)
            XCTAssertEqual(simulatorPath, file)
            let nativePath = AutomationHostGenerator.templateRelativePath(file, macOS: true)
            simulator[file] = AutomationArtifactRegistry.digest(try Data(contentsOf: root.appendingPathComponent(simulatorPath)))
            native[file] = AutomationArtifactRegistry.digest(try Data(contentsOf: root.appendingPathComponent(nativePath)))
            if AutomationHostGenerator.nativeTemplateOverrides.contains(file) { XCTAssertNotEqual(simulator[file], native[file]) }
            else { XCTAssertEqual(simulator[file], native[file]) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(AutomationArtifactRegistry.digest(try encoder.encode(simulator)), "be6701e885f4be88188f838a7d147572a8eca0fe6c4e8fa2b3c5003a4e2b25d9")
        XCTAssertNotEqual(AutomationArtifactRegistry.digest(try encoder.encode(native)), AutomationArtifactRegistry.digest(try encoder.encode(simulator)))
    }

    func testNilNativeReviewsPreserveLegacyWireAndFrozenDigest() throws {
        let app = AppIdentity(logicalID: "test", bundleID: "test", platform: "macos")
        let plan = AutomationCase(id: "test", app: app, target: .init(id: "test", kind: .nativeMac, loginSession: "test"), environmentID: "test",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "test", requiredCapabilities: [], effects: [.observe]))
        let original = try JSONEncoder().encode(plan)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertNil(fields["nativeInputAdapterReviews"])
        let restored = try JSONDecoder().decode(AutomationCase.self, from: original)
        XCTAssertNil(restored.nativeInputAdapterReviews)
        XCTAssertEqual(try AutomationFrozenCase.planDigest(restored), try AutomationFrozenCase.planDigest(plan))
    }

    func testFreshTestModuleMetadataDoesNotClaimThePrebuiltRunnerWasRecompiled() throws {
        let observation = AutomationAppleRuntimeObservation(processOSVersion: "test", processOSBuild: "test", architecture: "arm64",
            sdkPlatform: "macosx", xcodeBuild: "27A266a", sdkBuild: "26A425", frameworkPath: "/test/framework",
            frameworkSHA256: String(repeating: "a", count: 64), frameworkUUID: String(repeating: "b", count: 32),
            frameworkCPUType: 0x0100000c, frameworkCPUSubtype: 0)
        let runner: [String: Any] = ["DTPlatformName": "macosx", "DTXcodeBuild": "27A259", "DTSDKBuild": "26A384"]
        let compiled: [String: Any] = ["DTPlatformName": "macosx", "DTXcodeBuild": "27A266a", "DTSDKBuild": "26A425"]
        XCTAssertNoThrow(try AutomationMacAppleRuntimeSnapshot.validateBuildMetadata(runner: runner, tests: compiled, subject: compiled, observation: observation))
        XCTAssertThrowsError(try AutomationMacAppleRuntimeSnapshot.validateBuildMetadata(runner: compiled, tests: runner, subject: compiled, observation: observation))
        XCTAssertThrowsError(try AutomationMacAppleRuntimeSnapshot.validateBuildMetadata(runner: runner, tests: compiled, subject: runner, observation: observation))
        var unknownRunner = runner; unknownRunner.removeValue(forKey: "DTSDKBuild")
        XCTAssertThrowsError(try AutomationMacAppleRuntimeSnapshot.validateBuildMetadata(runner: unknownRunner, tests: compiled, subject: compiled, observation: observation))
    }

    func testApprovedLiveReadOnlyNativeAdapterWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_NATIVE_CODEC_LIVE_PROFILE"] else {
            throw XCTSkip("Requires a reviewed exact native prepared-app probe profile")
        }
        struct Profile: Decodable {
            let preparedApplicationPath: String, developerDirectory: String, supportRoot: String
            let actionID: String, parameterNames: [String], reviewedProbeDigest: String
        }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let prepared = try JSONDecoder().decode(AutomationPreparedApplication.self, from: Data(contentsOf: URL(fileURLWithPath: profile.preparedApplicationPath)))
        let root = URL(fileURLWithPath: profile.supportRoot)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: profile.developerDirectory))
        let review = try await runner.reviewNativeInputAdapters(prepared: prepared, actionID: profile.actionID, parameterNames: profile.parameterNames)
        XCTAssertEqual(review.probeDigest, profile.reviewedProbeDigest)
        let report = try await runner.qualifyNativeInputAdapters(prepared: prepared, actionID: profile.actionID, parameterNames: profile.parameterNames,
            reviewedProbeDigest: profile.reviewedProbeDigest, runID: "native-adapter-live", attemptID: "read-only-round-trip")
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("native-adapter-report.json"))
        XCTAssertTrue(report.resourcesReleased); XCTAssertNil(report.failure)
        XCTAssertNotNil(report.receiptDigest); XCTAssertFalse(report.qualifiedCapabilities.isEmpty)
    }

    func testNativeGrantRefreshStripsEveryPositiveCodecDeclarationButPreservesGates() {
        let version = AutomationNativeCodecQualification.probeVersion
        let records: [String: CapabilityProfile.Record] = [
            "apple.codec.entity": .init(state: .available, reason: "stale", probeVersion: version, evidence: ["old"]),
            "apple.codec.integer": .init(state: .available, reason: "simulator", probeVersion: "simulator-codec-canary-2", evidence: ["simulator"]),
            "apple.codec.bool": .init(state: .unavailable, reason: "veto", probeVersion: version, evidence: []),
            "apple.codec.date": .init(state: .consentRequired, reason: "consent", probeVersion: version, evidence: []),
            "apple.codec.text": .init(state: .available, reason: "caller", probeVersion: "caller", evidence: ["caller"]),
            "ui.nativeMac": .init(state: .available, reason: "ui", probeVersion: version, evidence: ["ui"])
        ]
        let result = AutomationNativeCodecQualification.strippingGrants(.init(records: records))
        XCTAssertNil(result.records["apple.codec.entity"]); XCTAssertNil(result.records["apple.codec.integer"])
        XCTAssertNil(result.records["apple.codec.text"])
        for key in ["apple.codec.bool", "apple.codec.date", "ui.nativeMac"] { XCTAssertEqual(result.records[key], records[key]) }
    }
    func testSerializedUnfamiliarCodecAvailabilityNeverBecomesNativeAuthority() throws {
        for version in ["", "caller", "old-native-authority", "third-party", "host-v2", "source-build", AutomationNativeCodecQualification.probeVersion] {
            let profile = CapabilityProfile(records: [
                "apple.codec.entity": .init(state: .available, reason: "declared", probeVersion: version, evidence: [String(repeating: "a", count: 64)]),
                "apple.intent.invoke": .init(state: .available, reason: "host", probeVersion: "host-v2", evidence: ["host"]),
                "apple.codec.bool": .init(state: .unknown, reason: "unknown", probeVersion: version, evidence: [])
            ])
            let restored = try JSONDecoder().decode(CapabilityProfile.self, from: JSONEncoder().encode(profile))
            let stripped = AutomationNativeCodecQualification.strippingGrants(restored)
            XCTAssertFalse(stripped.supports(["apple.codec.entity"]), version)
            XCTAssertEqual(stripped.records["apple.intent.invoke"], profile.records["apple.intent.invoke"])
            XCTAssertEqual(stripped.records["apple.codec.bool"], profile.records["apple.codec.bool"])
        }
    }

    func testQualificationAppliesOnlyRequiredProvedMembersWithoutOverridingConsentOrVeto() {
        let keys = ["apple.codec.entity", "apple.codec.bool", "apple.codec.integer", "apple.codec.date"]
        var profile = CapabilityProfile()
        profile.records[keys[0]] = .init(state: .unknown, reason: "unknown", probeVersion: "caller", evidence: [])
        profile.records[keys[1]] = .init(state: .unavailable, reason: "veto", probeVersion: "caller", evidence: [])
        profile.records[keys[2]] = .init(state: .consentRequired, reason: "consent", probeVersion: "caller", evidence: [])
        let result = AutomationNativeCodecQualification.applying(profile, required: Set(keys),
            members: ["entity": ["CompleteTaskIntent:task"], "bool": ["Other:value"], "integer": ["Other:count"], "date": [], "decimal": ["Other:decimal"]], evidence: ["exact-receipt"])
        XCTAssertTrue(result.supports([keys[0]])); XCTAssertEqual(result.records[keys[0]]?.evidence, ["exact-receipt"])
        XCTAssertEqual(result.records[keys[1]], profile.records[keys[1]]); XCTAssertEqual(result.records[keys[2]], profile.records[keys[2]])
        XCTAssertNil(result.records[keys[3]]); XCTAssertNil(result.records["apple.codec.decimal"])
    }
}
#endif
