-- Executable models of ScenarioResultEvaluator and
-- ScenarioExecutionRecoveryPolicy.requiresQuarantine.
import Lean

namespace ScenarioOutcome

inductive Outcome where
  | passed | failed | needsReview | notObserved | notApplicable
  deriving BEq, DecidableEq, Repr

-- An assertion is already scoped to the lane being evaluated. `observed`
-- means its observation key exists; `equalsExpected` means the observed value equals
-- the approved expected value for a deterministic assertion.
structure Assertion where
  required : Bool
  semantic : Bool
  observed : Bool
  equalsExpected : Bool
  deriving Repr

def failedRequiredDeterministic (assertions : List Assertion) : Bool :=
  assertions.any fun a =>
    a.required && !a.semantic && (!a.observed || !a.equalsExpected)

def missingRequiredSemantic (assertions : List Assertion) : Bool :=
  assertions.any fun a => a.required && a.semantic && !a.observed

def hasRequiredSemantic (assertions : List Assertion) : Bool :=
  assertions.any fun a => a.required && a.semantic

def evaluate (completed : Bool) (assertions : List Assertion) : Outcome :=
  if !completed then .notObserved
  else if failedRequiredDeterministic assertions || missingRequiredSemantic assertions then .failed
  else if hasRequiredSemantic assertions then .needsReview
  else .passed

theorem incompleteIsNotObserved (assertions : List Assertion) :
    evaluate false assertions = .notObserved := by
  rfl

theorem requiredDeterministicFailureCannotPass (assertions : List Assertion)
    (h : failedRequiredDeterministic assertions = true) :
    evaluate true assertions = .failed := by
  simp [evaluate, h]

theorem missingSemanticFails (assertions : List Assertion)
    (h : missingRequiredSemantic assertions = true) :
    evaluate true assertions = .failed := by
  simp [evaluate, h]

theorem observedSemanticNeedsAssessment (assertions : List Assertion)
    (hNoDeterministicFailure : failedRequiredDeterministic assertions = false)
    (hNoMissingSemantic : missingRequiredSemantic assertions = false)
    (hSemantic : hasRequiredSemantic assertions = true) :
    evaluate true assertions = .needsReview := by
  simp [evaluate, hNoDeterministicFailure, hNoMissingSemantic, hSemantic]

theorem optionalAssertionDoesNotChangeOutcome (completed : Bool)
    (assertions : List Assertion) (optional : Assertion)
    (hOptional : optional.required = false) :
    evaluate completed (assertions ++ [optional]) = evaluate completed assertions := by
  simp [evaluate, failedRequiredDeterministic, missingRequiredSemantic,
    hasRequiredSemantic, List.any_append, hOptional]

def requiredExact : Assertion := {
  required := true, semantic := false, observed := true, equalsExpected := true
}

def requiredRubric : Assertion := {
  required := true, semantic := true, observed := true, equalsExpected := false
}

example : evaluate true [requiredExact] = .passed := by decide
example : evaluate true [{ requiredExact with observed := false }] = .failed := by decide
example : evaluate true [{ requiredExact with equalsExpected := false }] = .failed := by decide
example : evaluate true [requiredRubric] = .needsReview := by decide
example : evaluate true [{ requiredRubric with observed := false }] = .failed := by decide
example : evaluate true [requiredRubric,
  { requiredExact with equalsExpected := false }] = .failed := by decide
example : evaluate true [requiredExact,
  { required := false, semantic := false, observed := false, equalsExpected := false }] = .passed := by decide

end ScenarioOutcome

namespace ScenarioOverall

open ScenarioOutcome (Outcome)

inductive Lane where
  | appFeature | intentIntegration | siri
  deriving BEq, DecidableEq, Repr

structure LaneResult where
  lane : Lane
  completed : Bool
  outcome : Outcome
  deriving Repr

def requiredResults (requiredLanes : List Lane) (results : List LaneResult) : List LaneResult :=
  results.filter fun result => requiredLanes.contains result.lane

def overall (requiredLanes : List Lane) (hasRequiredAssertion : Bool)
    (results : List LaneResult) : Outcome :=
  if requiredLanes.isEmpty || !hasRequiredAssertion then .needsReview
  else
    let relevant := requiredResults requiredLanes results
    if relevant.any (fun result => result.outcome == .failed) then .failed
    else if requiredLanes.any (fun lane => !relevant.any (fun result => result.lane == lane)) then .notObserved
    else if relevant.any (fun result => !result.completed || result.outcome == .notObserved) then .notObserved
    else if relevant.any (fun result => result.outcome == .needsReview) then .needsReview
    else if !relevant.all (fun result => result.outcome == .passed) then .notObserved
    else .passed

-- The former Swift loop returned on the first required lane with a problem.
-- An incomplete or review-needed lane could hide a later failed required lane.
def legacyLanes : List Lane → List LaneResult → Outcome
  | [], _ => .passed
  | lane :: remaining, results =>
      let matching := results.filter (fun result => result.lane == lane)
      if matching.isEmpty then .notObserved
      else if matching.any (fun result => result.outcome == .failed) then .failed
      else if matching.any (fun result => !result.completed || result.outcome == .notObserved) then .notObserved
      else if matching.any (fun result => result.outcome == .needsReview) then .needsReview
      else if !matching.all (fun result => result.outcome == .passed) then .notObserved
      else legacyLanes remaining results

def legacyOverall (requiredLanes : List Lane) (hasRequiredAssertion : Bool)
    (results : List LaneResult) : Outcome :=
  if requiredLanes.isEmpty || !hasRequiredAssertion then .needsReview
  else legacyLanes requiredLanes results

theorem failedRequiredLaneDominates (requiredLanes : List Lane)
    (hasRequiredAssertion : Bool) (results : List LaneResult)
    (hRequired : requiredLanes.isEmpty = false)
    (hAssertion : hasRequiredAssertion = true)
    (hFailed : (requiredResults requiredLanes results).any
      (fun result => result.outcome == .failed) = true) :
    overall requiredLanes hasRequiredAssertion results = .failed := by
  simp [overall, hRequired, hAssertion, hFailed]

theorem optionalLaneDoesNotChangeOverall (requiredLanes : List Lane)
    (hasRequiredAssertion : Bool) (results : List LaneResult)
    (optional : LaneResult) (hOptional : requiredLanes.contains optional.lane = false) :
    overall requiredLanes hasRequiredAssertion (results ++ [optional]) =
      overall requiredLanes hasRequiredAssertion results := by
  simp [overall, requiredResults, List.filter_append, hOptional]

def incompleteIntent : LaneResult := {
  lane := .intentIntegration, completed := false, outcome := .notObserved
}

def reviewIntent : LaneResult := {
  lane := .intentIntegration, completed := true, outcome := .needsReview
}

def passedIntent : LaneResult := {
  lane := .intentIntegration, completed := true, outcome := .passed
}

def passedSiri : LaneResult := {
  lane := .siri, completed := true, outcome := .passed
}

def failedSiri : LaneResult := {
  lane := .siri, completed := true, outcome := .failed
}

def failedOptionalFeature : LaneResult := {
  lane := .appFeature, completed := true, outcome := .failed
}

def requiredLanes : List Lane := [.intentIntegration, .siri]

example : legacyOverall requiredLanes true [incompleteIntent, failedSiri] = .notObserved := by decide
example : overall requiredLanes true [incompleteIntent, failedSiri] = .failed := by decide
example : legacyOverall requiredLanes true [reviewIntent, failedSiri] = .needsReview := by decide
example : overall requiredLanes true [reviewIntent, failedSiri] = .failed := by decide
example : overall requiredLanes true [passedIntent, passedSiri] = .passed := by decide
example : overall requiredLanes true [passedIntent, passedSiri, failedOptionalFeature] = .passed := by decide
example : overall requiredLanes true [passedIntent] = .notObserved := by decide
example : overall requiredLanes true [incompleteIntent, passedSiri] = .notObserved := by decide
example : overall requiredLanes true [reviewIntent, passedSiri] = .needsReview := by decide
example : overall [] true [passedIntent] = .needsReview := by decide
example : overall requiredLanes false [passedIntent, passedSiri] = .needsReview := by decide

end ScenarioOverall

namespace ScenarioRecovery

inductive Failure where
  | buildFailure | cancellation | timeout | deviceDisconnect
  | incompleteResultBundle | invalidEvidence | unexpected
  deriving BEq, DecidableEq, Repr

def requiresQuarantine (deviceTestLaunched : Bool) (failure : Failure) : Bool :=
  match failure with
  | .buildFailure => false
  | .cancellation | .timeout | .deviceDisconnect
  | .incompleteResultBundle | .invalidEvidence | .unexpected => deviceTestLaunched

theorem noQuarantineBeforeLaunch (failure : Failure) :
    requiresQuarantine false failure = false := by
  cases failure <;> rfl

theorem buildFailureNeverQuarantines (launched : Bool) :
    requiresQuarantine launched .buildFailure = false := by
  rfl

theorem uncertainPostLaunchFailureQuarantines (failure : Failure)
    (h : failure ≠ .buildFailure) :
    requiresQuarantine true failure = true := by
  cases failure <;> simp_all [requiresQuarantine]

end ScenarioRecovery
