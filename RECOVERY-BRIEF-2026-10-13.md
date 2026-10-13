# Recovery review, 2026-10-13: brief for Codex

Reviewer: Claude, for the user.

Basis: source and evidence review of:
- `origin/main` at `c9972a3e6` (PR 134 merged);
- PR 135 (`codex/recovery-phase2-20261013` at `8f0234c26`);
- the live checkout at `~/Developer/Projects/Intents`;
- the evidence in `Verification/Recovery-Phase2-20261013/` and `Verification/Trials-20261011/`.

Nothing was executed. The findings come from reading code and evidence files.

Read this before continuing `RECOVERY-PLAN-2026-10-12.md`. The plan has been amended to match, and every change is marked *Amended 2026-10-13* (see section 6).

---

## 1. Summary

- **Do not merge PR 135 yet.**
  - PR 135 adds two host template files, which changes the host-template digest.
  - The codec gate grants typed inputs only for two hard-coded digests.
  - Once PR 135 merges, the app will refuse every App Intent with a typed parameter or result, on every Mac.
  - Land Phase 1 first as its own PR, then rebase PR 135.
- **The Phase 2 acceptance did not go through the app's capability path.**
  - Both passing runs used `IntentsAutomationApplicationProbe` profiles that list the needed capabilities as already available.
  - That proves the in-host driver works. It does not show that the app can run the workflow.
- **No iPhone run has used the new route.** The 2026-10-11 iPhone pass was Intent Lab. App automation still allows only simulators for UI workflows.
- **Phase 3 has not started**, but most of its fixture exists: DuplicateTasks has been committed since PR 75.
- **The plan and the Phase 2 and Oct 11 evidence are not committed anywhere.** They exist only in the dirty live checkout.
- **The user's goal is wider than the fixture.**
  - The user wants to test any of their iPhone apps, including the quality of AI answers, the way the FlipBook Private Cloud Compute work did.
  - The plan now has a real-apps phase (4A) and a separate AI-evaluation track (Track B).

## 2. Findings

### F1. PR 135 switches off typed App Intent runs in the app

Paths below are on the PR 135 branch.

- **The gate.** `Sources/IntentsAutomationCore/AutomationSimulatorCodecQualification.swift:72-77`: `enrich` grants `apple.codec.*` only when `prepared.generatedHost.templateDigest` equals one of two hard-coded values:
  - `3d754425…` (`qualified`, line 35);
  - `0f812ac7…` (`legacyQualified`, line 26).

  Otherwise it returns the capabilities unchanged. Line 44 also requires the exact macOS, Xcode, runtime and framework context.
- **What PR 135 changes.**
  - PR 135's only template changes add `Integration/AutomationHost/UIHostPlan.swift` and `UIStepTests.swift`. PR 134 changed no templates.
  - The host prepared from the PR 135 templates has `templateDigest` `815a51c0…`, according to `Verification/Recovery-Phase2-20261013/debug-templates-prepared.json`.
- **Nothing else grants codec capabilities.** No other non-test code grants `apple.codec.*`. The app itself grants only:
  - `apple.intent.invoke` (`FoundationEvals/FoundationEvals/Stores/AutomationNativeFreshFixtures.swift:20`);
  - `apple.entity.query` (`Sources/IntentsAutomationCore/AutomationEntityQuery.swift:30`).
- **The validator refuses.** `Sources/IntentsAutomationCore/AutomationPlan.swift:181-182`: outside `.review`, a segment whose `apple.codec.*` requirements are unavailable throws `missingEvidence`.

**Result after merge.** The app refuses every plan with a typed parameter or result, on every Mac. For example, `CompleteTaskIntent(task:)` needs `apple.codec.entity`. On `main` today, those runs work only on this Mac's exact macOS (`26B5101f`), Xcode (`27A266a`) and simulator runtime. RC1 predicted this.

### F2. The Phase 2 acceptance used supplied capabilities

- **The profiles.** `debug-bundle-run-profile.json` and `mixed-run-profile-3.json` contain `capabilities.records` for these five capabilities, each marked `available` with `probeVersion: "phase2-e2e"`:
  - `apple.intent.invoke`
  - `apple.entity.query`
  - `apple.codec.entity`
  - `apple.codec.text`
  - `apple.codec.bool`
- **How the probe uses them.** `Tools/IntentsAutomationApplicationProbe/ApplicationProbe.swift:119` passes `profile.capabilities` straight to `runner.run`, and `enrich` keeps grants the caller supplied.
- **What the runs prove.** They prove the XCUITest driver, the receipts and the cleanup. They do not prove the app path.
- **The plan's Phase 2 acceptance is not met.** It asks for the workflow to work from a Debug build of Intents. The probe used templates copied out of that build, but it did not run through the app.

### F3. Phase 1 has not started

These are all unchanged on the PR 135 branch:
- the fingerprint records (`AutomationSimulatorCodecQualification.swift:26-40`, checked at line 44);
- the generator allow-list (`AutomationSurfaceCatalog.swift:39`);
- the process-local authority (`AutomationPreparedCodecAuthority.swift`).

### F4. No iPhone run has used the new route

- **The Oct 11 evidence is Intent Lab.** `Verification/Trials-20261011/physical/` uses `IntentLabFixture` and `IntentLabScenarioTests` with route `appShortcut`. It does not exercise App automation or the XCUITest host.
- **The app blocks physical UI runs.** In PR 135, `FoundationEvals/FoundationEvals/Stores/AppAutomationStore.swift:232-234` requires source targets to be prepared for `.simulator`, and UI workflows need a simulator UDID.
- **The runner itself is ready.** It has physical branches (`AutomationApplicationRunner.swift:142, 163`), but the app cannot reach them.

### F5. Phase 3 has not started

- **No end-to-end CI job or CLI.** No CI job prepares a fixture and runs plans; `ci.yml` has only the `changes`, `quality`, `regression` and `build` jobs. There is no `intents-automation` CLI.
- **RC9 is out of date about the fixture.** RC9 says DuplicateTasks "is not in the repository". It has been committed since PR 75 (`f8de88e`), at `Verification/Automation/Fixtures/DuplicateTasks`.
- **What the fixture has.** `TaskEntity`, `TaskQuery`, `CompleteTaskIntent(task:)`, and the UI identifiers `task.title`, `task.owner`, `task.add`, `fixture.control` and `fixture.reset`.
- **What it lacks.** Codec echo intents and an App Shortcut.

### F6. The plan and the evidence are uncommitted

- **Not committed:**
  - `RECOVERY-PLAN-2026-10-12.md` is on neither `main` nor the PR 135 branch.
  - `Verification/Recovery-Phase2-20261013/` and `Verification/Trials-20261011/` are not on `main`.
  - Only Phase 0's worklog is on `main`.
- **The live checkout's state:**
  - It is on `codex/local-workspace-20261001`.
  - Its merge base with `main` is `b60b097d9`, from 2026-09-20.
  - It has about 650 uncommitted entries, many of them unmerged v3 files.

### F7. The status report overstated readiness

The 2026-10-13 summary to the user had three problems:
- It said the Phase 2 work "remains local", but it was already PR 135.
- It listed the Intent Lab iPhone pass next to the new route without saying they are different systems.
- It left out F1 and F2.

As a result, the user could not tell what actually works.

## 3. What to do, in order

1. **Hold PR 135.** If it is merged anyway, don't cut a release (release PR 130, 1.5.0) until Phase 1 lands.
2. **Do Phase 1 as its own PR on `main`.** The plan's Phase 1 has been amended accordingly.
   1. Start with a failing test. Prepare a host from templates that include `UIStepTests.swift`, with no capabilities supplied. A plan that needs `apple.codec.entity` must pass `PlanValidator` after `capabilitiesForExecution`.
   2. Make the test pass by doing Phase 1.
   3. Remove the profile `capabilities` field from `IntentsAutomationApplicationProbe`. The CLI must resolve capabilities the same way the app does.
3. **Rebase PR 135 on Phase 1.**
   1. Rerun the DuplicateTasks mixed workflow and the deliberate assertion failure, this time without supplied capabilities.
   2. Update the PR description to say so.
4. **Commit this plan and this brief** with the Phase 1 PR, plus one short README per phase. Keep raw logs and profile JSON out of git.
5. **Continue in the plan's order: Phase 3, Phase 4, Phase 4A, then Phase 5.** Track B runs in parallel; it neither blocks the automation phases nor depends on them.

## 4. Reporting rules

Apply these to every status update you give the user:
- **Which route ran:** the Intents app, the CLI, or Intent Lab.
- **Where it ran:** simulator, iPhone or Mac. Say whether CI reproduces it or it ran once on this Mac.
- **Where the change is:** merged, released, or only in a PR or the local checkout.
- **What counts as a pass:** a run with hand-supplied capabilities, or any other pre-granted authority, is a driver check, not a pass. Say so.
- **Wording:** use plain words. Avoid internal terms such as assessed, qualified, authority or evidence-complete.

## 5. The user's goal

The user wants Intents to test any of their iPhone apps on the real iPhone. FlipBook is one example, not the target. That goal covers three jobs:

| Job | Route | Phases |
|---|---|---|
| Do the screens work? | XCUITest host steps | 2, 4, 4A |
| Do App Intents and Siri work? | The same host, plus Intent Lab's Siri bridge | 1, 4 |
| Are the AI answers good? | An in-app hook through the `FoundationEvalsDeveloper` SDK, with results graded in Intents | Track B |

The FlipBook thread did the third job.
- Its 23 iPhone cases worked because FlipBook ran them itself, in a debug-only mode (`FlipBook/Services/ApplePCCDeviceVerification.swift`), and emitted structured results.
- Don't route AI answer quality through screen steps. The answers are long and vary between runs, the inputs include photos, and grading needs known facts.

## 6. Plan changes made

The following changes were made to `RECOVERY-PLAN-2026-10-12.md`, each marked *Amended 2026-10-13*. Nothing else in the plan changed.

- A note at the top pointing here.
- An RC9 correction: the fixture is committed.
- Rules 7 and 8: one capability path for the app and the CLI, and plain-language status reports.
- Phase 1:
  - status: required before PR 135 merges;
  - a failing-test-first step;
  - removal of probe capabilities;
  - interim acceptance until Phase 3 exists.
- Phase 2: status, the supplied-capabilities caveat, and the no-source limitation.
- Phase 3: start from the committed DuplicateTasks fixture.
- Phase 4:
  - the first iPhone run is the fixture workflow;
  - device preflight checks;
  - no quarantine on the iPhone;
  - extended acceptance.
- New Phase 4A: real apps on the iPhone (FlipBook plus one app the user picks).
- New Track B: AI answer quality on the iPhone through the SDK, starting with FlipBook's existing cases.
- Section 6: added done criteria and human-only steps.
- Section 7: new index rows.
