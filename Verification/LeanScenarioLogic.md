# Lean checks: scenario outcomes and device recovery

`LeanScenarioLogic.lean` models scenario assertion outcomes, the overall
result across required lanes (`ScenarioResultEvaluator` in
`ScenarioValidation.swift`), and device quarantine
(`ScenarioExecutionRecoveryPolicy.requiresQuarantine` in
`ScenarioExecutionRecovery.swift`). The release gate has a separate model in
`LeanScenarioRelease.lean`.

## Scenario outcome checks

The model scopes assertions to one lane before evaluation, as Swift does. It
abstracts observation lookup as `observed` and value equality as
`equalsExpected`. Lean proves that incomplete execution is not observed,
required deterministic failures and missing required semantic observations
fail, observed required semantic evidence needs review, and adding an optional
assertion cannot change the outcome. Concrete checks exercise matching,
missing, mismatched, semantic, optional, and mixed failure evidence.

## Required-lane aggregation

Lean proves that a failed required lane determines the overall result even if
another required lane is incomplete or needs review. It also proves that a
result from an optional lane cannot change the overall result. Concrete checks
cover missing lanes, incomplete execution, review, all-pass results, and the
absence of a required outcome assertion. The model reproduces a counterexample
to the former Swift loop: an incomplete Intent lane hid a later failed Siri
lane. A Swift regression test failed on that loop and passes after aggregation
checks all required lanes for failures first.

## Recovery checks

Lean proves that no failure quarantines a device before launch, a build
failure never quarantines it, and every other modeled failure quarantines it
after launch. All seven Swift failure cases are represented.

Run from this directory with the pinned `lean-toolchain`:

```sh
lean LeanScenarioLogic.lean
lean LeanScenarioRelease.lean
```

These proofs cover hand-written models of the decisions, not a formal
translation of the Swift implementation. `ScenarioContractsTests` checks the
production methods, including assertion outcomes, required-lane priority,
and recovery. The models do not cover observation parsing, persistence,
actual device termination, or fixture readiness.

## Worklog (2026-09-24)

1. Matched the two models to the current Swift branches and existing tests.
2. Added Lean theorems and concrete checks for outcome and recovery decisions.
3. Added Swift contract cases for missing, mismatched, optional, semantic, and
   incomplete scenario evidence.
4. Review identified two untested Swift cases: a build failure after launch
   and deterministic failure alongside observed semantic evidence. Added both
   and reran the Lean check and all 29 `ScenarioContractsTests`; all passed.
5. Added the required-lane aggregation model. Its counterexample exposed a
   later failure hidden by an earlier incomplete or review-needed lane. Changed
   Swift aggregation to give failures priority across required lanes.
6. Replaced a flaky scheduler-yield wait in the cancellation test with a
   time-bounded wait. Lean checks and all 30 scenario contract tests passed.
