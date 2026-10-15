#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeCodecComparisonTests: XCTestCase {
    private func prepared(after: Bool) throws -> AutomationPreparedApplication {
        let label = after ? "after" : "before"
        let source = AutomationSourceManifest(sourceRoot: "/private/tmp/" + label + "-source", files: [], directories: [], excludedPaths: [])
        var app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "macos",
            productDigest: String(repeating: after ? "b" : "a", count: 64))
        app.canonicalBundlePath = "/private/tmp/" + label + "/Fixture.app"
        app.sourceManifestDigest = try source.digest; app.sourceSyntaxIndexDigest = String(repeating: after ? "e" : "d", count: 64)
        app.productDigestVersion = 2; app.configuration = "Debug"; app.architecture = "arm64"; app.owningModule = "Fixture"
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
        let host = AutomationPreparedAppleHost(app: app, target: target,
            xctestrunPath: "/private/tmp/" + label + "/host.xctestrun", xctestrunDigest: String(repeating: after ? "2" : "1", count: 64),
            subjectProductPath: app.canonicalBundlePath!, hostBundlePath: "/private/tmp/" + label + "/Host-Runner.app",
            hostProductDigest: String(repeating: after ? "4" : "3", count: 64), hostBundleID: "example.Host", testTarget: "Host", hostProductDigestVersion: 2)
        var catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "CompleteTaskIntent", typeName: "CompleteTaskIntent", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true,
            compiled: true, registered: false, executed: false, resultFamily: "noValue")], systemDiscoveryComplete: true, uiDiscoveryComplete: false, gaps: [])
        catalog.entities = [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: [:], propertyTitles: [:])]
        return .init(source: source,
            generatedHost: .init(projectPath: "/private/tmp/" + label + "/Fixture.xcodeproj", scheme: "Host", targetID: "Host", bundleID: "example.Host",
                configuration: "Debug", templateDigest: String(repeating: "f", count: 64)),
            host: host, catalog: catalog, buildLogPath: "/private/tmp/" + label + "/build.log", buildLogTruncated: false)
    }
    private func baseline(reviews: Bool) throws -> AutomationFrozenCase {
        let prepared = try prepared(after: false)
        var plan = AutomationCase(id: "native-codec-comparison", app: prepared.host.app, target: prepared.host.target, environmentID: "native-test",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete selected task",
                requiredCapabilities: ["apple.intent.invoke", "apple.codec.entity"], effects: [.observe]))
        plan.execution.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTaskIntent",
            parameters: ["task": .entity(typeID: "TaskEntity", value: "selected-task")], resultCodec: "noValue")])
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        if reviews { plan = try AutomationNativeInputAdapterPlanning.attachReviews(to: plan, prepared: prepared, capabilities: .init()) }
        return try .init(plan: plan)
    }
    func testActualPreparedCandidateRegeneratesReviewProofAndKeepsBusinessContract() throws {
        let before = try baseline(reviews: true), prepared = try prepared(after: true)
        let after = try AutomationFixContract.candidate(from: before, prepared: prepared)
        let beforeReview = try XCTUnwrap(before.plan.nativeInputAdapterReviews?.first), afterReview = try XCTUnwrap(after.plan.nativeInputAdapterReviews?.first)
        XCTAssertEqual(afterReview.app, prepared.host.app); XCTAssertNotEqual(afterReview.app, beforeReview.app)
        XCTAssertNotEqual(afterReview.probeDigest, beforeReview.probeDigest)
        XCTAssertEqual(afterReview.actionID, beforeReview.actionID); XCTAssertEqual(afterReview.parameterNames, beforeReview.parameterNames)
        XCTAssertEqual(afterReview.fixedSamples, beforeReview.fixedSamples); XCTAssertEqual(afterReview.purpose, beforeReview.purpose)
        XCTAssertEqual(before.contractDigest, after.contractDigest); XCTAssertEqual(before.oracleDigest, after.oracleDigest)
        XCTAssertNotEqual(before.digest, after.digest)
        try AutomationFixContract.validate(baseline: before, candidate: after)
        let rebound = try AutomationNativeInputAdapterPlanning.attachReviews(to: after.plan, prepared: prepared, capabilities: .init())
        XCTAssertEqual(rebound, after.plan)
    }
    func testCandidateWithoutActualPreparedSourceCannotReuseNativeProbeProof() throws {
        let before = try baseline(reviews: true), app = try prepared(after: true).host.app
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: before, app: app))
    }
    func testLegacyNilReviewsStayAbsentThroughPreparedCandidateAndRoundTrip() throws {
        let before = try baseline(reviews: false), after = try AutomationFixContract.candidate(from: before, prepared: prepared(after: true))
        XCTAssertNil(after.plan.nativeInputAdapterReviews)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(after.plan)) as? [String: Any])
        XCTAssertNil(fields["nativeInputAdapterReviews"])
        let restored = try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(after.plan))
        XCTAssertEqual(try AutomationFrozenCase.planDigest(restored), after.digest)
        XCTAssertEqual(before.contractDigest, after.contractDigest)
    }
    func testBuildProjectionRetainsProbeActionParametersPurposeAndSamples() throws {
        let before = try baseline(reviews: true), after = try AutomationFixContract.candidate(from: before, prepared: prepared(after: true))
        let original = try XCTUnwrap(after.plan.nativeInputAdapterReviews?.first)
        for variant in ["action", "parameters", "samples", "purpose", "target", "staleApp", "removed"] {
            var plan = after.plan
            var samples = original.fixedSamples
            let names = variant == "parameters" ? ["otherTask"] : original.parameterNames
            if variant == "parameters" { samples = ["otherTask": samples["task"]!] }
            if variant == "samples" { samples["task"] = [.entity(typeID: "TaskEntity", value: "different-probe-reference")] }
            var target = original.target
            if variant == "target" { target.loginSession = "another-login" }
            plan.nativeInputAdapterReviews = variant == "removed" ? nil : [.init(probeDigest: original.probeDigest,
                app: variant == "staleApp" ? before.plan.app : original.app, target: target,
                actionID: variant == "action" ? "OtherTaskIntent" : original.actionID, parameterNames: names,
                purpose: variant == "purpose" ? "Perform the selected action" : original.purpose, fixedSamples: samples)]
            XCTAssertThrowsError(try AutomationFixContract.validate(baseline: before, candidate: .init(plan: plan)), variant)
        }
    }
    func testChangedCandidateParameterSchemaCannotReuseTheBaselineProbe() throws {
        let before = try baseline(reviews: true)
        var prepared = try prepared(after: true)
        prepared.catalog.systemActions[0].parameters[0].name = "otherTask"
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: before, prepared: prepared))
    }
}
#endif
