import Foundation
import Testing
@testable import FoundationEvals

struct JudgeCredentialBindingTests {
    @Test func storedCredentialCannotFollowImportedConnectionMetadata() throws {
        let saved = EvaluationJudgeConnection(id: UUID(), name: "Saved", kind: .customCompatible,
            baseURL: "https://judge.example/v1", modelID: "fixture")
        let bytes = try EvaluationJudgeCredentialBinding.encode("fixture-secret", for: saved)
        #expect(try EvaluationJudgeCredentialBinding.decode(bytes, for: saved) == "fixture-secret")
        for replacement in ["https://attacker.example/v1", "https://judge.example/v2"] {
            var imported = saved; imported.baseURL = replacement
            #expect(throws: EvaluationCompatibleJudgeError.self) { try EvaluationJudgeCredentialBinding.decode(bytes, for: imported) }
        }
        var changed = saved; changed.kind = .openRouter
        #expect(throws: EvaluationCompatibleJudgeError.self) { try EvaluationJudgeCredentialBinding.decode(bytes, for: changed) }
        changed = saved; changed.id = UUID()
        #expect(throws: EvaluationCompatibleJudgeError.self) { try EvaluationJudgeCredentialBinding.decode(bytes, for: changed) }
        changed = saved; changed.modelID = "another-model"
        #expect(try EvaluationJudgeCredentialBinding.decode(bytes, for: changed) == "fixture-secret")
    }
    @Test func legacyCredentialRequiresExplicitRebinding() throws {
        let saved = EvaluationJudgeConnection(id: UUID(), name: "Saved", kind: .customCompatible,
            baseURL: "https://judge.example/v1", modelID: "fixture")
        let legacy = Data("fixture-secret".utf8)
        #expect(throws: EvaluationCompatibleJudgeError.self) { try EvaluationJudgeCredentialBinding.decode(legacy, for: saved) }
        #expect(legacy == Data("fixture-secret".utf8))
        let rebound = try EvaluationJudgeCredentialBinding.encode("fixture-secret", for: saved)
        #expect(try EvaluationJudgeCredentialBinding.decode(rebound, for: saved) == "fixture-secret")
    }
}
