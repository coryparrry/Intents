#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPreparedMacContractTests {
    func testOptionalDiagnosticSelectsOnlySupportedFixedSamplesAndDoesNotChangeCatalog() async throws {
        let h = try fixture()
        let catalog = ApplicationSurfaceCatalog(app: h.host.app, systemActions: [
            .init(id: "Probe", typeName: "Probe", title: "Probe", parameters: [
                .init(name: "title", family: "text", optional: false),
                .init(name: "record", family: "entity", optional: false),
                .init(name: "choice", family: "enum", optional: false)
            ], parametersComplete: true, compiled: true, registered: false, executed: false)
        ], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        var prepared = AutomationPreparedApplication(source: .init(sourceRoot: h.root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: h.host.testTarget, targetID: h.host.testTarget,
                bundleID: h.host.hostBundleID, configuration: "Debug", templateDigest: String(repeating: "d", count: 64)),
            host: h.host, catalog: catalog, buildLogPath: "synthetic", buildLogTruncated: false)
        let selection = try XCTUnwrap(AutomationInputConversionDiagnostic.selection(prepared: prepared, actionID: "Probe"))
        XCTAssertEqual(selection.parameterNames, ["title"])
        XCTAssertEqual(prepared.catalog, catalog)
        XCTAssertNil(AutomationInputConversionDiagnostic.selection(prepared: prepared, actionID: "foreign"))
        prepared.host.target = .init(id: UUID().uuidString, kind: .simulator)
        XCTAssertNil(AutomationInputConversionDiagnostic.selection(prepared: prepared, actionID: "Probe"))
    }
}

final class AutomationInputConversionDiagnosticPresentationTests: XCTestCase {
    func testCleanupFailureNeverReportsSuccessfulConversion() {
        let result = AutomationInputConversionDiagnostic.result(resourcesReleased: false, succeeded: true,
            failure: "runner still present", parameterNames: ["title"])
        XCTAssertFalse(result.resourcesReleased)
        XCTAssertTrue(result.message.contains("target remains held"))
        XCTAssertTrue(result.message.contains("runner still present"))
        XCTAssertFalse(result.message.contains("matched"))
    }
    func testConversionFailureRemainsAReadableDiagnosticResult() {
        let result = AutomationInputConversionDiagnostic.result(resourcesReleased: true, succeeded: false,
            failure: "Input adapter readback mismatch", parameterNames: ["title"])
        XCTAssertTrue(result.resourcesReleased)
        XCTAssertEqual(result.message, "Input conversion check failed: Input adapter readback mismatch")
    }
    func testMissingReceiptDoesNotReportSuccessfulConversion() {
        let result = AutomationInputConversionDiagnostic.result(resourcesReleased: true, succeeded: false,
            failure: nil, parameterNames: ["title"])
        XCTAssertTrue(result.message.contains("did not return readback evidence"))
    }
}
#endif
