-- Executable model of the pass branch in ScenarioReleaseCheckEvaluator.report.
-- Keep the inputs and gates aligned with ScenarioComparison.swift.
import Lean

namespace ScenarioRelease

inductive Lane where
  | appFeature | intentIntegration | siri
  deriving BEq, DecidableEq, Repr

structure Assertion where
  id : Nat
  required : Bool
  applicableLanes : List Lane
  deriving Repr

structure AssertionResult where
  id : Nat
  passed : Bool
  deriving Repr

structure LaneResult where
  lane : Lane
  completed : Bool
  passed : Bool
  assertions : List AssertionResult
  deriving Repr

structure Definition where
  validDigest : Bool
  requiredLanes : List Lane
  assertions : List Assertion
  deriving Repr

structure Run where
  identityMatches : Bool
  completed : Bool
  xctestExitCode : Option Int
  comparison : Option Bool
  lanes : List LaneResult
  deriving Repr

def requiredIDs (d : Definition) (lane : Lane) : List Nat :=
  (d.assertions.filter fun a => a.required && a.applicableLanes.contains lane).map (·.id)

def hasRequiredObservableAssertion (d : Definition) : Bool :=
  d.assertions.any fun a =>
    a.required && d.requiredLanes.any (fun lane => a.applicableLanes.contains lane)

def requiredLanesPassed (d : Definition) (r : Run) : Bool :=
  d.requiredLanes.all fun lane =>
    let results := r.lanes.filter (fun result => result.lane == lane)
    !results.isEmpty && results.all (fun result => result.completed && result.passed)

-- The earlier Swift gate only rejected an assertion result explicitly marked failed.
-- An absent required result could therefore pass this check.
def legacyRequiredRecordsPassed (d : Definition) (r : Run) : Bool :=
  !(r.lanes.any fun result =>
    d.requiredLanes.contains result.lane &&
      result.assertions.any (fun assertion =>
        (requiredIDs d result.lane).contains assertion.id && !assertion.passed))

def requiredRecordsComplete (d : Definition) (r : Run) : Bool :=
  r.lanes.all fun result =>
    if d.requiredLanes.contains result.lane then
      (requiredIDs d result.lane).all fun id =>
        let records := result.assertions.filter (fun assertion => assertion.id == id)
        records.length == 1 && records.all (fun assertion => assertion.passed)
    else true

def comparisonAllowed (r : Run) : Bool :=
  match r.comparison with
  | none => true
  | some comparable => comparable

def commonGates (d : Definition) (r : Run) : Bool :=
  d.validDigest && r.identityMatches && r.completed &&
    r.xctestExitCode == some 0 && !d.requiredLanes.isEmpty &&
    hasRequiredObservableAssertion d && requiredLanesPassed d r &&
    comparisonAllowed r

def legacyReportPassed (d : Definition) (run : Option Run) : Bool :=
  match run with
  | none => false
  | some r => commonGates d r && legacyRequiredRecordsPassed d r

def reportPassed (d : Definition) (run : Option Run) : Bool :=
  match run with
  | none => false
  | some r => commonGates d r && requiredRecordsComplete d r

theorem noRunCannotPass (d : Definition) : reportPassed d none = false := by
  rfl

theorem passRequiresCompleteAssertions (d : Definition) (r : Run)
    (h : reportPassed d (some r) = true) : requiredRecordsComplete d r = true := by
  simp only [reportPassed, Bool.and_eq_true] at h
  exact h.2

theorem passRequiresAllRequiredLanes (d : Definition) (r : Run)
    (h : reportPassed d (some r) = true) : requiredLanesPassed d r = true := by
  simp only [reportPassed, commonGates, Bool.and_eq_true] at h
  exact h.1.1.2

theorem passRequiresCurrentSuccessfulRun (d : Definition) (r : Run)
    (h : reportPassed d (some r) = true) :
    d.validDigest = true ∧ r.identityMatches = true ∧ r.completed = true ∧
      r.xctestExitCode = some 0 ∧ comparisonAllowed r = true := by
  simp only [reportPassed, commonGates, Bool.and_eq_true] at h
  simp_all

def sampleDefinition : Definition := {
  validDigest := true
  requiredLanes := [.intentIntegration]
  assertions := [{ id := 1, required := true, applicableLanes := [.intentIntegration] }]
}

def passingIntent : LaneResult := {
  lane := .intentIntegration
  completed := true
  passed := true
  assertions := [{ id := 1, passed := true }]
}

def passingRun : Run := {
  identityMatches := true
  completed := true
  xctestExitCode := some 0
  comparison := none
  lanes := [passingIntent]
}

def missingAssertionRun : Run := {
  passingRun with lanes := [{ passingIntent with assertions := [] }]
}

def duplicateAssertionRun : Run := {
  passingRun with lanes := [{ passingIntent with assertions :=
    [{ id := 1, passed := true }, { id := 1, passed := true }] }]
}

def optionalFailureRun : Run := {
  passingRun with lanes := passingRun.lanes ++ [{
    lane := .appFeature, completed := true, passed := false, assertions := []
  }]
}

-- Concrete counterexample to the old gate and regression checks for the new one.
example : legacyReportPassed sampleDefinition (some missingAssertionRun) = true := by decide
example : reportPassed sampleDefinition (some missingAssertionRun) = false := by decide
example : reportPassed sampleDefinition (some duplicateAssertionRun) = false := by decide
example : reportPassed sampleDefinition (some passingRun) = true := by decide
example : reportPassed sampleDefinition (some optionalFailureRun) = true := by decide
example : reportPassed sampleDefinition (some { passingRun with xctestExitCode := none }) = false := by decide
example : reportPassed sampleDefinition (some { passingRun with comparison := some true }) = true := by decide
example : reportPassed sampleDefinition (some { passingRun with comparison := some false }) = false := by decide
example : reportPassed sampleDefinition (some { passingRun with lanes := [] }) = false := by decide

end ScenarioRelease
