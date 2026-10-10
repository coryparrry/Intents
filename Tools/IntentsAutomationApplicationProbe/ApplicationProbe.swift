#if os(macOS)
import Foundation
import IntentsAutomationCore

/// Exercises the product planner and runner with an explicit disposable integration profile.
@main struct ApplicationProbe {
    struct Profile: Decodable {
        var preparedPath: String
        var actionID: String
        var inputs: [String: AutomationActionInput]
        var declaredEffects: AutomationActionEffectDeclaration
        var approval: RunApproval
        var capabilities: CapabilityProfile
        var attemptID: String
        var supportRoot: String
        var developerDirectory: String
        var allowBootAndInstall: Bool
        var plan: AutomationCase?
        var runtimeBundlePath: String?
        var runtimeTeamID: String?
        var approveExactCase: Bool?
        var recipeCandidate: AutomationSetupRecipeCandidate?
        var recipeReuse: RecipeReuse?
        var freshFixtureQualification: FreshFixtureQualification?
        var reproduceQualifiedFailure: Bool?
        var freshRecordWorkflow: FreshRecordWorkflow?
    }
    struct FreshRecordWorkflow: Decodable {
        var instruction: String
        var endpoint: String
        var namePrefix: String
        var nameProperty: String
        var stateProperty: String
        var initialState: Bool
        var expectedState: Bool
        var localeIdentifier: String
        var context: AutomationFreshEntityContext?
    }
    struct FreshFixtureQualification: Decodable {
        var repeatAttemptID: String
        var bindings: [AutomationFreshFixtureBinding]
    }
    struct FreshFixtureReceipt: Encodable {
        var fixtureDigest: String
        var context: AutomationRecipeContext
        var attemptIDs: [String]
        var reportDigests: [String]
        let trust = "Live engineering qualification metadata; reading this file grants no authority"
    }
    struct FreshFixtureOutput: Encodable {
        var attempts: [AutomationAttemptReport]
        var qualification: FreshFixtureReceipt
        var reproduction: AutomationReproductionReport?
    }
    struct RecipeReuse: Decodable {
        var text: String
        var consumingParameter: String
        var attemptID: String
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, ["--profile", "--plan-profile"].contains(CommandLine.arguments[1]) else { throw AutomationContractError.invalidIdentity }
            let planningOnly = CommandLine.arguments[1] == "--plan-profile"
            let bytes = try read(CommandLine.arguments[2], maximumBytes: 1_048_576)
            let profile = try JSONDecoder().decode(Profile.self, from: bytes)
            let prepared = try JSONDecoder().decode(AutomationPreparedApplication.self,
                from: read(profile.preparedPath, maximumBytes: 16 * 1024 * 1024))
            guard (profile.runtimeBundlePath == nil) == (profile.runtimeTeamID == nil) else { throw AutomationContractError.invalidIdentity }
            let runtime = profile.runtimeBundlePath.map { AutomationUIRuntime(bundleURL: URL(fileURLWithPath: $0), expectedTeamID: profile.runtimeTeamID!) }
            var plan: AutomationCase
            if let fresh = profile.freshRecordWorkflow {
                guard profile.approveExactCase == true, profile.plan == nil, profile.inputs.isEmpty,
                      profile.recipeCandidate == nil, let runtime else { throw AutomationContractError.invalidIdentity }
                plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: profile.actionID,
                    instruction: fresh.instruction, endpoint: fresh.endpoint, namePrefix: fresh.namePrefix,
                    nameProperty: fresh.nameProperty, stateProperty: fresh.stateProperty, initialState: fresh.initialState,
                    expectedState: fresh.expectedState, approval: profile.approval, capabilities: profile.capabilities,
                    localeIdentifier: fresh.localeIdentifier, context: fresh.context, purpose: .simulatorDraft)
                plan.provenance.merge(["ui.preparedHostDigest": prepared.host.hostProductDigest,
                    "ui.preparedXctestrunDigest": prepared.host.xctestrunDigest,
                    "ui.preparedCatalogDigest": try AutomationRecipeContext.catalogDigest(prepared.catalog),
                    "ui.hostTemplateDigest": prepared.generatedHost.templateDigest,
                    "ui.runtimeManifestDigest": try AutomationRuntimeBundle.verifiedManifestDigest(bundleURL: runtime.bundleURL,
                        stateDirectory: URL(fileURLWithPath: profile.supportRoot).appendingPathComponent("runtime-preview"), expectedTeamID: runtime.expectedTeamID),
                    "ui.runtimeTeamID": runtime.expectedTeamID]) { _, value in value }
                plan.id = "fresh." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
            } else {
                plan = try profile.plan ?? AutomationTemplatePlanner.compile(catalog: prepared.catalog, actionID: profile.actionID,
                    inputs: profile.inputs, declaredEffects: profile.declaredEffects, approval: profile.approval, capabilities: profile.capabilities, purpose: .review)
            }
            var approval = profile.approval
            if profile.approveExactCase == true { approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan) }
            guard profile.recipeReuse == nil || profile.recipeCandidate != nil else { throw AutomationContractError.invalidIdentity }
            guard profile.reproduceQualifiedFailure != true || profile.freshFixtureQualification != nil else {
                throw AutomationContractError.missingEvidence("Reproduction requires new live fixture qualification in this invocation")
            }
            if let qualification = profile.freshFixtureQualification {
                guard profile.approveExactCase == true, profile.recipeCandidate == nil,
                      qualification.repeatAttemptID != profile.attemptID,
                      qualification.repeatAttemptID.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
                try AutomationQualifiedFreshFixture.validateProposal(bindings: qualification.bindings, plan: plan,
                    approval: approval, capabilities: profile.capabilities)
            }
            if planningOnly {
                // Engineering inspection only. No runner, lease, device action,
                // qualification token or dispatch authority is constructed.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(plan))
                return
            }
            let runner = try AutomationApplicationRunner(supportRoot: URL(fileURLWithPath: profile.supportRoot),
                developerDirectory: URL(fileURLWithPath: profile.developerDirectory))
            let report = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: profile.capabilities,
                attemptID: profile.attemptID, allowBootAndInstall: profile.allowBootAndInstall, uiRuntime: runtime,
                qualifyingFreshBindings: profile.freshFixtureQualification?.bindings)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let qualification = profile.freshFixtureQualification {
                guard completeForFreshQualification(report) else { throw AutomationContractError.missingEvidence("First attempt is incomplete; no fixture repetition is authorised") }
                if profile.reproduceQualifiedFailure == true {
                    guard report.result.summary == .assertionFailed, report.result.assessed, report.result.evidenceComplete else {
                        throw AutomationContractError.missingEvidence("Select an assessed original failure before reproduction")
                    }
                }
                try await runner.validateFreshFixtureAttempt(bindings: qualification.bindings)
                let repeated = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: profile.capabilities,
                    attemptID: qualification.repeatAttemptID, allowBootAndInstall: profile.allowBootAndInstall, uiRuntime: runtime,
                    qualifyingFreshBindings: qualification.bindings)
                guard completeForFreshQualification(repeated) else { throw AutomationContractError.missingEvidence("Second attempt did not complete; no fixture authority is minted") }
                let fixture = try await runner.qualifyFreshFixture(bindings: qualification.bindings)
                let receipt = FreshFixtureReceipt(fixtureDigest: fixture.fixtureDigest, context: fixture.context,
                    attemptIDs: fixture.qualificationAttemptIDs, reportDigests: fixture.qualificationReportDigests)
                let file = URL(fileURLWithPath: profile.supportRoot).appendingPathComponent(profile.attemptID).appendingPathComponent("fresh-fixture-qualification.json")
                try encoder.encode(receipt).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                var reproduction: AutomationReproductionReport?
                if profile.reproduceQualifiedFailure == true {
                    let casesRoot = URL(fileURLWithPath: profile.supportRoot).appendingPathComponent("Cases")
                    let cases = try AutomationCaseStore(root: casesRoot), frozen = try AutomationFrozenCase(plan: plan)
                    var repeatApproval = approval; repeatApproval.runID = approval.runID + "-reproduction"
                    let executor = AutomationApplicationCampaignExecutor(runner: runner, prepared: prepared,
                        capabilities: profile.capabilities, allowBootAndInstall: profile.allowBootAndInstall, uiRuntime: runtime)
                    let result = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: report.attemptID,
                        approval: repeatApproval, capabilities: profile.capabilities, limits: .firstCampaign, executor: executor, fixture: fixture)
                    reproduction = result
                    try await AutomationReproductionArchive(caseStoreRoot: casesRoot).save(result)
                }
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(FreshFixtureOutput(attempts: [report, repeated], qualification: receipt, reproduction: reproduction)) + Data([10]))
                if reproduction?.complete == false { Foundation.exit(1) }
                return
            }
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(report) + Data([10]))
            if !report.executionSucceeded { Foundation.exit(1) }
            if let candidate = profile.recipeCandidate {
                let recipe = try await runner.qualifyRecipe(candidate)
                let metadata = ["id": candidate.id, "version": String(candidate.version), "attemptID": recipe.qualificationAttemptID,
                                "reportDigest": recipe.qualificationReportDigest, "scope": "visible exact-label text path"]
                let file = URL(fileURLWithPath: profile.supportRoot).appendingPathComponent("recipe-qualification.json")
                try encoder.encode(metadata).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                if let reuse = profile.recipeReuse {
                    var reuseApproval = profile.approval; reuseApproval.approvedCaseDigest = nil
                    let next = try AutomationTemplatePlanner.compile(catalog: prepared.catalog, actionID: profile.actionID,
                        inputs: profile.inputs, declaredEffects: profile.declaredEffects, approval: reuseApproval, capabilities: profile.capabilities,
                        recipe: recipe, recipeContext: recipe.context, recipeText: reuse.text, consumingParameter: reuse.consumingParameter)
                    guard profile.approveExactCase == true else { throw AutomationContractError.missingEvidence("Recipe reuse needs exact-case approval") }
                    reuseApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(next)
                    let repeated = try await runner.run(prepared: prepared, plan: next, approval: reuseApproval,
                        capabilities: profile.capabilities, attemptID: reuse.attemptID, allowBootAndInstall: profile.allowBootAndInstall, uiRuntime: runtime)
                    if !repeated.executionSucceeded { Foundation.exit(1) }
                }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Application execution failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
    private static func completeForFreshQualification(_ report: AutomationAttemptReport) -> Bool {
        report.resourcesReleased && report.result.subjectCompleted && !report.result.subjectDispatchUncertain &&
            report.result.evidenceComplete && [.passed, .assertionFailed, .executedUnassessed].contains(report.result.summary)
    }
    private static func read(_ path: String, maximumBytes: Int) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= maximumBytes else { throw AutomationContractError.invalidIdentity }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AutomationContractError.invalidIdentity }
        return data
    }
}
#else
@main struct ApplicationProbe { static func main() {} }
#endif
