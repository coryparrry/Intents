# Lean check: scenario release gate

`LeanScenarioRelease.lean` models the **passed** branch of
`ScenarioReleaseCheckEvaluator.report` in `ScenarioComparison.swift`. It checks
the decision that determines whether an Intent Lab scenario has enough current,
successful evidence to gate a release.

## Source mapping

| Lean input | Swift source condition |
|---|---|
| `validDigest`, `identityMatches` | The frozen definition digest is valid, and the run's scenario ID, version, and digest match it. |
| `completed`, `xctestExitCode` | The scenario completed, and XCTest exited with code zero. |
| `requiredLanes`, `requiredLanesPassed` | At least one lane is required; every required lane has results, and each result completed and passed. |
| `hasRequiredObservableAssertion` | A required assertion applies to at least one required lane. |
| `requiredRecordsComplete` | Every required assertion has exactly one passing recorded result in every applicable required lane result. |
| `comparison`, `comparisonAllowed` | No comparison was supplied, or the supplied comparison is directly comparable. |

The model treats Swift's `ScenarioOutcome.passed` and
`ScenarioExecutionStatus.completed` as Boolean fields. It assumes the scenario
definition has already passed `ScenarioValidator`, including its unique
assertion ID check. It does not model report messages, timestamps, or the
distinction between failed and incomplete reports; those do not affect whether
the report passes.

## Checked properties

- A missing run cannot pass.
- A passing report implies a current scenario identity, completed execution,
  successful XCTest exit, compatible comparison, passed required lanes, and
  complete required assertion records.
- Concrete checks reject absent or duplicate required assertion records,
  missing required lanes, absent XCTest exit evidence, and incompatible
  comparisons; both absent and compatible comparisons can pass.
- A failed optional lane does not block an otherwise passing required lane.
- The old gate admits a concrete missing assertion counterexample; the new
  gate rejects it. `ScenarioContractsTests` checks this against the Swift code.

Run from this directory after installing `elan`:

```sh
lean LeanScenarioRelease.lean
```

The nearby `lean-toolchain` pins Lean 4.34.1. Lean verifies this hand-written
model. It does not establish that the Swift implementation is equivalent to
the model or verify the importer, digest computation, persistence, or device
execution. The Swift scenario contract tests cover the production release gate.

## Worklog (2026-09-24)

1. Inspected the release evaluator, evidence importer, and existing contract tests.
2. Modeled the pass decision and found that the old gate allowed an absent
   required assertion result on a passed lane.
3. Made the release evaluator require one passing record per required assertion.
4. Checked the Lean file and ran the focused Swift regression and all 28
   `ScenarioContractsTests`; all passed.
5. Independent review found an omitted no-comparison case in the model. Added
   it and reran the Lean check successfully.
