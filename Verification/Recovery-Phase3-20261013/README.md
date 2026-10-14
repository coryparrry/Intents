# Phase 3 verification — 2026-10-13

Phase 3 starts from main after PR 136 merged as `f205bc9ba`. This separate PR supplies the supported CLI, committed fixture, simulator CI job and opt-in app UI-test migration. It is not merged or released. Release PR 130 remains held.

## Reproduce

Run `python3 script/automation_e2e.py` from the repository root; see [App automation](../../docs/wiki/App-automation.md). The CLI uses the app's capability resolver and case store, with no supplied capability records. Raw reports, profiles, logs, screenshots and products stay outside git.

The **Automation e2e (simulator)** job must pass for the PR head. It compares exact outputs for all 16 codec families and five empty arrays, requires an assessed UI/intent/query workflow, checks a wrong assertion, then checks a timeout with resource release and an immediate successful rerun. Echo attempts remain `executedUnassessed`; the script checks their returned values independently.

The separate **Input conversion diagnostic (Mac)** job runs the existing live String setter/readback canary. It checks exact readback and release without invoking a business action or granting execution capabilities. Skipped or empty execution cannot satisfy the job.

## Local checks

- Fixture iOS Simulator and Mac targets build with Xcode 27.0; all six model tests pass.
- Supported CLI builds; 19 CLI regressions pass, including capability injection, exact approval, Mac assembly budgets, saved reports and canonical support-folder aliases.
- All 53 Python workflow, routing and driver checks pass.
- Native activation and real Xcode file-export fixes pass 33 native driver tests and 43 host-contract tests plus 53 Mac driver/probe regressions. The full simulator job supplies runtime acceptance; focused tests alone do not satisfy it.
- A real simulator preparation captured 18 actions. The initial saved-preparation reload exposed a `/tmp` alias bug; the fixed CLI reloads that retained catalog without rebuilding.
- Independent fixture/UI, CLI and CI reviews are clean. Current execution evidence is published by the required CI jobs above.

The required workflow runs the CLI on an iOS simulator. The Mac canary proves only setter/readback diagnostic behavior. No iPhone, Mac business subject, Siri or Intent Lab execution is claimed. Opt-in app GUI tests were migrated and source-reviewed; they are separate from the required CLI job.
