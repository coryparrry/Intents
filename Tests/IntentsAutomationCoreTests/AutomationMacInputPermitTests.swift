#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacInputPermitTests: XCTestCase {
    func testApprovedPublicFillBindsExactCodeUnitsAndCannotAuthorizeAnotherInputKind() throws {
        let permit = try XCTUnwrap(AutomationMacInputPermit(approvedAction: .object([
            "kind": .string("fill"), "value": .string("e\u{0301}🙂"), "sensitive": .bool(false)])))
        XCTAssertTrue(permit.matches(nativeAction: .object(["kind": .string("ordinaryFill"), "value": .string("e\u{0301}🙂")])))
        XCTAssertFalse(permit.matches(nativeAction: .object(["kind": .string("ordinaryFill"), "value": .string("é🙂")])))
        XCTAssertFalse(permit.matches(nativeAction: .object(["kind": .string("press")])))
        XCTAssertFalse(permit.matches(nativeAction: .object(["kind": .string("scroll"), "direction": .string("down")])))
    }
    func testSecretMalformedAndOversizedPolicyActionsNeverCreateAnOrdinaryPermit() {
        let actions: [AutomationJSON] = [.object(["kind": .string("fillSecret"), "referenceID": .string(UUID().uuidString), "sinkID": .string("sink")]),
            .object(["kind": .string("fill"), "value": .string("private"), "sensitive": .bool(true)]),
            .object(["kind": .string("fill"), "value": .string("nul\0"), "sensitive": .bool(false)]),
            .object(["kind": .string("fill"), "value": .string(String(repeating: "x", count: 16385)), "sensitive": .bool(false)]),
            .object(["kind": .string("tap"), "extra": .bool(true)])]
        for action in actions {
            XCTAssertNil(AutomationMacInputPermit(approvedAction: action))
        }
    }
    func testScrollDirectionAndTapPermitsCannotCrossNativeActionKinds() throws {
        let scroll = try XCTUnwrap(AutomationMacInputPermit(approvedAction: .object(["kind": .string("swipe"), "direction": .string("down")])))
        XCTAssertTrue(scroll.matches(nativeAction: .object(["kind": .string("scroll"), "direction": .string("down")])))
        XCTAssertFalse(scroll.matches(nativeAction: .object(["kind": .string("scroll"), "direction": .string("up")])))
        let tap = try XCTUnwrap(AutomationMacInputPermit(approvedAction: .object(["kind": .string("tap")])))
        XCTAssertTrue(tap.matches(nativeAction: .object(["kind": .string("press")])))
        XCTAssertFalse(tap.matches(nativeAction: .object(["kind": .string("ordinaryFill"), "value": .string("public")])))
        XCTAssertNil(AutomationMacInputPermit(approvedAction: .object(["kind": .string("swipe"), "direction": .string("invalid")])))
    }
    func testWholeProgramCapabilityAndLiteralPreflightPrecedesAnyInput() throws {
        var program = AutomationUIProgram(operations: [.init(id: "tap", kind: .tap, locator: .init(.testId, "open")),
            .init(id: "fill", kind: .fillBinding, locator: .init(.role, "textbox"), binding: "text"),
            .init(id: "scroll", kind: .scroll, direction: "down")], bindings: ["text": "Public"])
        try program.validate(phase: .subject)
        XCTAssertThrowsError(try AutomationMacInputCapabilities.tapOnly.validate(program))
        try AutomationMacInputCapabilities.ordinaryFillAndScroll.validate(program)
        program.bindings["text"] = "invalid\0"
        XCTAssertThrowsError(try AutomationMacInputCapabilities.ordinaryFillAndScroll.validate(program))
        XCTAssertNil(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedReceiptSHA256))
        XCTAssertNil(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: String(repeating: "a", count: 64)))
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256), .tapOnly)
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256), .ordinaryFillAndScroll)
    }

    func testDigestVersionIsChosenOnlyFromExactFrozenRuntimeReceipt() {
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedV2ProgramReceiptSHA256), .lexicalV2)
        for receipt in [AutomationPrivateMacDaemonUnit.pinnedReceiptSHA256, AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256, AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256] {
            XCTAssertEqual(AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: receipt), .legacyV1)
        }
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedSecretProgramReceiptSHA256), .lexicalV2)
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedPolicyDiagnosticsProgramReceiptSHA256), .lexicalV2)
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedPolicyDiagnosticsProgramReceiptSHA256), .ordinaryFillAndScroll)
        XCTAssertNil(AutomationPrivateMacDaemonUnit.programDigestVersion(receiptSHA256: String(repeating: "a", count: 64)))
        XCTAssertEqual(AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedV2ProgramReceiptSHA256), .ordinaryFillAndScroll)
    }

}
#endif
