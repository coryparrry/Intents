import Foundation

struct MCPIntentInstallationInput: Decodable, Sendable {
  var projectPath: String
  var workspacePath: String?
  var scheme: String
  var applicationTargetID: String
  var uiTestTargetID: String?
  var appBundleID: String
  var packageSource: String?
  var packageRevision: String?
  var mode: String
  var declarationBase64: String
}
struct MCPIntentInstallationPreview {
  let input: MCPIntentInstallationInput
  let request: IntentLabInstallationRequest
  let plan: IntentLabInstallationPlan
  let digest: String
}

@MainActor enum MCPIntentInstallation {
  static func execute(
    _ call: MCPControlCall, control: EvaluationAppControl, service: MCPControlService
  ) throws -> MCPToolPayload {
    switch call.name {
    case "eval_intent_install_inspect":
      let url = URL(filePath: try call.text("projectPath"))
      let inspection = try IntentLabProjectInstaller.inspect(projectURL: url)
      func targets(_ values: [IntentLabProjectTarget]) -> MCPJSONValue {
        .array(values.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
      }
      return MCPControlService.read([
        "applications": targets(inspection.applications),
        "testTargets": targets(inspection.uiTestTargets),
        "schemes": try .encode(inspection.sharedSchemes),
      ])
    case "eval_intent_install_preview":
      guard service.installations.count < 10 else {
        throw EvaluationStoreError.resourceConflict(
          "Ten installation previews are retained. Restart after preserving needed previews to release their session state."
        )
      }
      let input = try call.value("requestJSON", as: MCPIntentInstallationInput.self)
      guard ["basic", "siri"].contains(input.mode),
        let declaration = Data(base64Encoded: input.declarationBase64),
        declaration.count <= 1_048_576
      else { throw MCPToolInputError.invalidArguments }
      let package: URL
      if let source = input.packageSource {
        if source.hasPrefix("https://") {
          guard let url = URL(string: source) else { throw MCPToolInputError.invalidArguments }
          package = url
        } else {
          package = URL(filePath: source)
        }
      } else {
        package = IntentLabPackageRevisionManifest.packageURL
      }
      let request = IntentLabInstallationRequest(
        projectURL: URL(filePath: input.projectPath),
        workspaceURL: input.workspacePath.map { URL(filePath: $0) }, scheme: input.scheme,
        applicationTargetID: input.applicationTargetID, uiTestTargetID: input.uiTestTargetID,
        packageURL: package, packageRevision: input.packageRevision,
        packageProduct: input.mode == "siri" ? "IntentLabCoreTesting" : "IntentLabTesting",
        consumerSource: input.mode == "siri"
          ? IntentLabConsumerTemplates.siri : IntentLabConsumerTemplates.basic,
        declarationData: declaration)
      let plan = try IntentLabProjectInstaller().preview(request)
      let id = try call.id("operationID")
      _ = try IntentLabProjectInstaller.validateDeclaration(
        declaration, targetBundleIdentifier: input.appBundleID, testTargetName: plan.targetName)
      let changes = MCPJSONValue.array(
        plan.changes.map {
          .object([
            "path": .string($0.url.path), "summary": .string($0.summary),
            "beforeDigest": $0.beforeDigest.map(MCPJSONValue.string) ?? .null,
            "afterDigest": .string($0.afterDigest),
            "proposedText": .string(String(decoding: $0.proposed, as: UTF8.self)),
          ])
        })
      let digest = ProductionCodec.digest(Data(try changes.jsonText().utf8))
      guard try changes.jsonText().utf8.count <= 786_432 else {
        throw EvaluationStoreError.resourceConflict(
          "Installation preview exceeds 768 KiB; inspect this project locally.")
      }
      service.installations[id] = .init(input: input, request: request, plan: plan, digest: digest)
      return MCPControlService.committed([
        "previewID": .string(id.uuidString), "previewDigest": .string(digest),
        "supported": .bool(plan.supported), "changes": changes,
        "manualSteps": try .encode(plan.manualSteps),
      ])
    case "eval_intent_install_apply":
      try MCPControlService.confirm(call)
      let id = try call.id("previewID")
      guard let preview = service.installations[id],
        preview.digest == (try call.text("previewDigest"))
      else {
        throw EvaluationStoreError.resourceConflict(
          "Installation preview is missing or changed. Preview again and review its exact proposed files."
        )
      }
      let receipt = try IntentLabProjectInstaller().apply(preview.plan)
      let verification = try IntentLabProjectInstaller().verify(preview.request)
      guard verification.installed else {
        throw EvaluationStoreError.invalidSuite(
          "Support files changed but verification failed: \(verification.missing.joined(separator:", "))"
        )
      }
      let declaration = try IntentLabProjectInstaller.validateDeclaration(
        preview.request.declarationData, targetBundleIdentifier: preview.input.appBundleID,
        testTargetName: preview.plan.targetName)
      let inspection = try IntentLabProjectInstaller.inspect(projectURL: preview.request.projectURL)
      let product = inspection.uiTestTargets.first(where: { $0.name == preview.plan.targetName })
      let lab = control.scenarios
      lab.selectContainer(preview.request.workspaceURL ?? preview.request.projectURL)
      if ![ScenarioDefinition.stableSchemaVersion, ScenarioDefinition.reusableSchemaVersion]
        .contains(lab.draft.schemaVersion)
      {
        lab.startReusableCheck()
      }
      lab.recordInstalledIntegration(
        .init(id: declaration.id, version: declaration.version, digest: declaration.digest),
        appBundleID: preview.input.appBundleID, projectPath: preview.input.projectPath,
        scheme: preview.input.scheme, testTarget: preview.plan.targetName,
        applicationProductID: "\(preview.input.projectPath)#\(preview.input.applicationTargetID)",
        testProductID: product.map { "\(preview.input.projectPath)#\($0.id)" })
      lab.projectTrusted = false
      lab.invalidatePreflight()
      service.installations[id] = nil
      return MCPControlService.committed([
        "changedFiles": try .encode(receipt.changedFiles.map(\.path)),
        "alreadyInstalled": .bool(receipt.alreadyInstalled),
        "intentRevision": .string(try MCPDeviceControl.revision(lab)),
      ])
    default: throw MCPToolInputError.unknownTool
    }
  }
}

enum IntentLabConsumerTemplates {
  static let basic = """
    import XCTest
    import IntentLabTesting

    @available(macOS 27.0, iOS 27.0, *)
    @MainActor
    final class IntentLabScenarioTests: XCTestCase {
        func testIntentLabScenario() throws {
            try IntentLabScenarioRunner.run(testCase: self, integration: IntentLabBasicIntegration())
        }

        func testIntentLabConnection() throws {
            try IntentLabScenarioRunner.checkConnection(testCase: self, integration: IntentLabBasicIntegration())
        }
    }
    """

  static let siri = """
    import XCTest
    import IntentLabCoreTesting

    @available(macOS 27.0, iOS 27.0, *)
    @MainActor
    final class IntentLabScenarioTests: XCTestCase {
        func testIntentLabScenario() throws {
            try IntentLabSiriScenarioRunner.run(testCase: self, integration: IntentLabAppAdapter())
        }

        func testIntentLabConnection() throws {
            try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: IntentLabAppAdapter())
        }
    }
    """

}
