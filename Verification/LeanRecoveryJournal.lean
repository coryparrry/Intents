-- Single-device state model of XcodeTestExecutor journal and reservation rules.
-- `readinessProven` is the caller's attestation, not device-observed proof.
import Lean

namespace RecoveryJournal

inductive Phase where
  | preparing | running | cancelling | stopped | recoveryRequired
  deriving BEq, DecidableEq, Repr

inductive Reservation where
  | free | reserved | quarantined
  deriving BEq, DecidableEq, Repr

structure State where
  phase : Option Phase
  reservation : Reservation
  active : Bool
  deriving Repr, DecidableEq

def idle : State := { phase := none, reservation := .free, active := false }

-- The reservation is acquired while saving the initial journal. A failed save
-- releases the reservation owned by that invocation.
def persistPreparing (state : State) (saveSucceeded : Bool) : State :=
  if saveSucceeded then { state with phase := some .preparing, reservation := .reserved }
  else state

def launch (state : State) : State :=
  { state with phase := some .running, reservation := .reserved, active := true }

def finishEvidenceValidation (state : State) (accepted : Bool) : State :=
  if accepted then { state with phase := some .stopped, reservation := .free, active := false }
  else { state with phase := some .recoveryRequired, reservation := .quarantined, active := false }

def cancel (state : State) : State :=
  if state.active then
    { state with phase := some .recoveryRequired, reservation := .quarantined, active := false }
  else state

def reconcile (state : State) : State :=
  match state.phase with
  | some .preparing | some .running | some .cancelling | some .recoveryRequired =>
      { state with phase := some .recoveryRequired, reservation := .quarantined, active := false }
  | some .stopped | none => state

def clearQuarantine (state : State) (readinessProven : Bool) : State :=
  if readinessProven && !state.active && state.reservation == .quarantined then
    { state with phase := some .stopped, reservation := .free }
  else state

theorem failedInitialSavePreservesFreeReservation (state : State)
    (hFree : state.reservation = .free) :
    (persistPreparing state false).reservation = .free := by
  simpa [persistPreparing] using hFree

theorem unprovenReadinessCannotClear (state : State) :
    clearQuarantine state false = state := by
  simp [clearQuarantine]

theorem activeExecutionCannotBeCleared (state : State)
    (hActive : state.active = true) :
    clearQuarantine state true = state := by
  simp [clearQuarantine, hActive]

theorem reservedExecutionCannotBeCleared (state : State)
    (hReserved : state.reservation = .reserved) :
    clearQuarantine state true = state := by
  cases state with
  | mk phase reservation active =>
      cases reservation <;> simp_all [clearQuarantine]
      intro _
      decide

theorem rejectedEvidenceQuarantines (state : State) :
    (finishEvidenceValidation state false).reservation = .quarantined := by
  rfl

theorem acceptedEvidenceReleases (state : State) :
    (finishEvidenceValidation state true).reservation = .free := by
  rfl

theorem interruptedRunningJournalQuarantines (state : State)
    (hRunning : state.phase = some .running) :
    (reconcile state).reservation = .quarantined := by
  simp [reconcile, hRunning]

example : (persistPreparing idle false).reservation = .free := by decide
example : (persistPreparing idle true).reservation = .reserved := by decide
example : (reconcile (launch (persistPreparing idle true))).reservation = .quarantined := by decide
example : (clearQuarantine (reconcile (launch idle)) false).reservation = .quarantined := by decide
example : (clearQuarantine (reconcile (launch idle)) true).reservation = .free := by decide
example : (clearQuarantine (persistPreparing idle true) true).reservation = .reserved := by decide

end RecoveryJournal

namespace ReservationOwnership

inductive Reservation where
  | free | reserved (invocationID : Nat) | quarantined
  deriving BEq, DecidableEq, Repr

structure State where
  reservation : Reservation
  clearing : Bool
  active : Bool
  deriving Repr, DecidableEq

def initialSaveCompleted (state : State) (invocationID : Nat)
    (saveSucceeded : Bool) : State :=
  if saveSucceeded then state
  else if state.reservation == .reserved invocationID then
    { state with reservation := .free }
  else state

def canBeginClear (state : State) (readinessProven : Bool) : Bool :=
  readinessProven && !state.active && !state.clearing &&
    state.reservation == .quarantined

def beginClear (state : State) (readinessProven : Bool) : State :=
  if canBeginClear state readinessProven then { state with clearing := true }
  else state

def preflightAvailable (state : State) : Bool :=
  state.reservation == .free && !state.clearing && !state.active

def finishClear (state : State) : State :=
  if state.clearing && !state.active && state.reservation == .quarantined then
    { state with reservation := .free, clearing := false }
  else { state with clearing := false }

theorem failedSavePreservesDifferentOwner (state : State) (savingID otherID : Nat)
    (hDifferent : savingID ≠ otherID) :
    (initialSaveCompleted { state with reservation := .reserved otherID }
      savingID false).reservation = .reserved otherID := by
  have hNotSame : otherID ≠ savingID := by
    intro hSame
    exact hDifferent hSame.symm
  have hNotEqual : (Reservation.reserved otherID == Reservation.reserved savingID) = false := by
    change (otherID == savingID) = false
    simp [hNotSame]
  simp [initialSaveCompleted, hNotEqual]

theorem secondClearCannotClaim (state : State)
    (hClearing : state.clearing = true) :
    beginClear state true = state := by
  simp [beginClear, canBeginClear, hClearing]

theorem clearingBlocksPreflight (state : State)
    (hClearing : state.clearing = true) :
    preflightAvailable state = false := by
  simp [preflightAvailable, hClearing]

def quarantined : State := {
  reservation := .quarantined, clearing := false, active := false
}

example : (beginClear quarantined true).clearing = true := by decide
example : (beginClear (beginClear quarantined true) true).clearing = true := by decide
example : preflightAvailable (beginClear quarantined true) = false := by decide
example : (finishClear (beginClear quarantined true)).reservation = .free := by decide

end ReservationOwnership
