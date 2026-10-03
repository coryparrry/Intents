-- Abstract state model of XCTestEvidenceImporter.importEvidence's admission
-- checks and ScenarioImportLedger.record. Content and path checks are inputs.
import Lean

namespace EvidenceAdmission

structure Ledger where
  invocationIDs : List Nat
  nonces : List Nat
  artifactIDs : List Nat
  deriving Repr, DecidableEq

structure Envelope where
  invocationID : Nat
  nonce : Nat
  artifactIDs : List Nat
  schemaValid : Bool
  journalActive : Bool
  identityValid : Bool
  oneTestExecuted : Bool
  laneResultsValid : Bool
  artifactsValid : Bool
  deriving Repr

def checksPass (e : Envelope) : Bool :=
  e.schemaValid && e.journalActive && e.identityValid &&
    e.oneTestExecuted && e.laneResultsValid && e.artifactsValid

def replayFree (ledger : Ledger) (e : Envelope) : Bool :=
  !ledger.invocationIDs.contains e.invocationID &&
    !ledger.nonces.contains e.nonce &&
    e.artifactIDs.all (fun id => !ledger.artifactIDs.contains id)

-- The Swift ledger is mutated only after every validation step succeeds.
def importEvidence (ledger : Ledger) (e : Envelope) : Bool × Ledger :=
  if checksPass e && replayFree ledger e then
    (true, {
      invocationIDs := e.invocationID :: ledger.invocationIDs
      nonces := e.nonce :: ledger.nonces
      artifactIDs := e.artifactIDs ++ ledger.artifactIDs
    })
  else (false, ledger)

theorem rejectionPreservesLedger (ledger : Ledger) (e : Envelope)
    (h : (importEvidence ledger e).1 = false) :
    (importEvidence ledger e).2 = ledger := by
  cases hChecks : checksPass e && replayFree ledger e <;>
    simp [importEvidence, hChecks] at h ⊢

theorem replayedInvocationCannotBeAccepted (ledger : Ledger) (e : Envelope)
    (h : ledger.invocationIDs.contains e.invocationID = true) :
    (importEvidence ledger e).1 = false := by
  have hReplay : replayFree ledger e = false := by
    simp only [replayFree, h, Bool.not_true, Bool.false_and]
  simp [importEvidence, hReplay]

theorem replayedNonceCannotBeAccepted (ledger : Ledger) (e : Envelope)
    (h : ledger.nonces.contains e.nonce = true) :
    (importEvidence ledger e).1 = false := by
  have hReplay : replayFree ledger e = false := by
    simp only [replayFree, h, Bool.not_true, Bool.false_and, Bool.and_false]
  simp [importEvidence, hReplay]

theorem acceptedRecordsInvocation (ledger : Ledger) (e : Envelope)
    (h : (importEvidence ledger e).1 = true) :
    ((importEvidence ledger e).2.invocationIDs).contains e.invocationID = true := by
  unfold importEvidence at h ⊢
  split at h <;> simp_all

def emptyLedger : Ledger := { invocationIDs := [], nonces := [], artifactIDs := [] }

def validEnvelope : Envelope := {
  invocationID := 7
  nonce := 11
  artifactIDs := [17]
  schemaValid := true
  journalActive := true
  identityValid := true
  oneTestExecuted := true
  laneResultsValid := true
  artifactsValid := true
}

example : (importEvidence emptyLedger validEnvelope).1 = true := by decide
example : (importEvidence emptyLedger { validEnvelope with oneTestExecuted := false }).2 = emptyLedger := by decide
example : (importEvidence emptyLedger { validEnvelope with identityValid := false }).1 = false := by decide
example : (importEvidence (importEvidence emptyLedger validEnvelope).2 validEnvelope).1 = false := by decide
example : (importEvidence { emptyLedger with artifactIDs := [17] } validEnvelope).1 = false := by decide

end EvidenceAdmission
