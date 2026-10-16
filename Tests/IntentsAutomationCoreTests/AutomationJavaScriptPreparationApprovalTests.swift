#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationJavaScriptPreparationApprovalTests: XCTestCase {
    private func recipe() -> AutomationMetroAutomaticRecipe {
        .init(sourceRoot: "/source", appRelativePath: "app", delegateRelativePath: "app/ios/App/AppDelegate.swift",
              delegateSHA256: String(repeating: "a", count: 64), expoConfigModuleRelativePath: "app/node_modules/@expo/metro-config",
              metroModuleRelativePath: "app/node_modules/metro", metroConfigRelativePath: nil, nodePath: "/installed/node",
              nodeSHA256: String(repeating: "b", count: 64), inputs: [:], bundleRoot: ".expo/.virtual-metro-entry")
    }
    private func advanced() -> AutomationServedJavaScriptProfile {
        .init(schemaVersion: 1, executablePath: "/installed/node", executableSHA256: String(repeating: "a", count: 64),
              scriptRelativePath: "server.js", scriptSHA256: String(repeating: "b", count: 64), arguments: [],
              bundleURL: "http://127.0.0.1:8081/index.bundle", bundleSHA256: String(repeating: "c", count: 64),
              nativeBindingRelativePath: "binding.json", qualificationEvidence: "fixture", recipeRelativePath: "recipe.json")
    }
    func testAutomaticAndAdvancedServerChoicesCannotBeCombined() {
        let approval = AutomationBuildApproval(sourceRoot: "/source", candidateID: "app", configuration: "Debug",
            target: .init(id: "sim", kind: .simulator), servedJavaScriptProfile: advanced(), automaticMetroRecipe: recipe())
        XCTAssertThrowsError(try approval.validateJavaScriptApproval())
    }
    func testAutomaticRecipeMustBeApprovedThroughItsDedicatedChoice() {
        var profile = advanced(); profile.automaticMetro = recipe()
        let approval = AutomationBuildApproval(sourceRoot: "/source", candidateID: "app", configuration: "Debug",
            target: .init(id: "sim", kind: .simulator), servedJavaScriptProfile: profile)
        XCTAssertThrowsError(try approval.validateJavaScriptApproval())
    }
    func testServedJavaScriptRejectsNonSimulatorTargetsBeforeBuilding() {
        for kind in [TargetIdentity.Kind.nativeMac, .physical] {
            let approval = AutomationBuildApproval(sourceRoot: "/source", candidateID: "app", configuration: "Debug",
                target: .init(id: "target", kind: kind), automaticMetroRecipe: recipe())
            XCTAssertThrowsError(try approval.validateJavaScriptApproval()) { error in
                XCTAssertTrue(String(describing: error).contains("requires an iOS Simulator"))
            }
        }
    }
    func testReviewedAutomaticSimulatorAndBundledReleaseRemainAdmissible() throws {
        let automatic = AutomationBuildApproval(sourceRoot: "/source", candidateID: "app", configuration: "Debug",
            target: .init(id: "sim", kind: .simulator), automaticMetroRecipe: recipe())
        try automatic.validateJavaScriptApproval()
        let bundled = AutomationBuildApproval(sourceRoot: "/source", candidateID: "app", configuration: "Release",
            target: .init(id: "mac", kind: .nativeMac))
        try bundled.validateJavaScriptApproval()
    }
}
#endif
