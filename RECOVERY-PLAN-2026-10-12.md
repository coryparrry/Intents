# App automation and intent testing: root-cause report and recovery plan

Date: 2026-10-12. Basis: source review of `main` at `4a7b0fc`, the repository's own verification records under `Verification/Automation/`, and GitHub Actions logs for CI runs 1153 (`main`) and 1155 (release PR). Nothing here was executed on a Mac.

This document is written for the agent (Codex) that will carry out the fix. Read sections 1–4 for the diagnosis and section 5 for the work.

> **Amended 2026-10-13.** Read [`RECOVERY-BRIEF-2026-10-13.md`](RECOVERY-BRIEF-2026-10-13.md) first. In short:
> - Do not merge PR 135 (Phase 2) before Phase 1. Its new host templates switch off typed App Intent runs in the app.
> - The Phase 2 acceptance ran with capabilities supplied in the probe profiles.
> - No iPhone run has used the new route yet.
>
> Changed sections are marked *Amended 2026-10-13*. Section 5 adds a real-apps phase (4A) and an AI-evaluation track (Track B).

---

## 1. Summary

The app cannot do general intent testing and app automation. There is no single bug behind this. The v3 automation layer, merged in PR #75 (`f8de88e`: 933 files, +129,447 lines), is designed so that **nothing may run until "qualification evidence" exists**. The code only accepts that evidence when it matches one Mac's exact OS, Xcode, simulator runtime and framework hashes, and only inside the same app process that produced it. The runs that would produce it are mostly blocked by other gates.

On top of that design:

- Several routes are switched off in the shipped app: physical-device actions and UI, Mac execution, and installed-app UI on a device.
- UI workflows need a Developer-ID-sealed Node runtime that normal builds never include.
- The v3 Siri route fails on a known iOS 27 XCTest behaviour.
- Any uncertain attempt quarantines the device, and App automation has no way to clear it.
- The definition of "done" includes things no coding agent can do: twelve independent apps, three unfamiliar human testers, a clean Mac, an Intel Mac, and notarized distribution.

So every session ends with "remains unverified", and the next session adds more gates.

The only flow that has worked end to end is the **developer-integrated Intent Lab path**. On 2026-09-26 it passed direct App Intent 1/1 and Siri 3/3 on a physical iPhone (`Verification/INTENT_LAB_E2E_2026-09-26.md`). v3 has since started sharing that path's physical lease store, so v3 failures can now block it too.

**Recommendation:** stop "qualifying" the current v3 architecture. Keep the parts that work: the App Intents host templates, project intake and preparation, the catalog reader, and the saved-case store. Then:

1. Remove the environment fingerprints and process-local authority.
2. Replace the Node/agent-device UI stack with XCUITest steps that run inside the generated host test bundle, which is already a UI-testing bundle aimed at the subject app.
3. Fix Siri using the bridge Intent Lab already proved.
4. Add quarantine recovery.
5. Make a headless CLI plus a simulator end-to-end job in CI the source of truth, so agents can verify without driving the GUI.

---

## 2. What works today, by route

| Route (App automation screen) | Status | Why |
|---|---|---|
| Source app → **iOS Simulator** → System action (App Intent) with **no typed inputs or results** | Can run | Only route with no codec, runtime or device gate |
| Simulator → System action **with typed inputs/results** | Runs only on the original developer Mac snapshot | RC1 fingerprint; RC3 process-local authority |
| Simulator → System action with date, URL, duration, calendar, file or text/bool/decimal/date arrays | Never runs | These codec families were never in the qualified set (RC1) |
| Simulator → **App workflow (UI)** / **Action on a new test record** | Fails in dev and test builds; flaky elsewhere | RC5 sealed runtime; RC8 on-device model controller (2/4); agent-device locator failures (`LOCATOR_NOT_FOUND`, `invalidFixture`) |
| Installed iOS app (no source) → UI workflow | Simulator only; same as above | RC5 |
| **Physical iPhone/iPad** → System action or UI | Disabled | RC4: `canRun` only allows simulator for source targets; runner has no physical UI route in production |
| Physical → **Siri recognised-text** | Wired, but fails on iOS 27 | RC6: XCTest interruption becomes `ambiguousDispatch`, then quarantine; also needs an Xcode that matches the device OS |
| **This Mac** (source or installed Mac app) | Preparation and saved drafts only | RC4: UI says "Mac workflow execution is not available yet"; runner has no Mac route in production |
| Reproduce / Find failures / Check fix | Effectively never | Needs a successful saved UI or fresh-record run first |
| Intent Lab (developer-integrated) direct + Siri | Worked 2026-09-26 | Now shares the v3 physical lease store (RC7) |

Live runs that did pass, all on the developer's Mac with private fixtures:

- A simulator IntegerArray echo through the native UI.
- Ten scalar codec canaries.
- A Mac String setter/readback probe on Xcode 27.2.
- A Mac "prepare and save draft" UI test.

These show the core App Intents host mechanism works. The blockers are the gating and orchestration around it.

---

## 3. Root causes (with code evidence)

### RC1 — Typed App Intent inputs are tied to one machine's exact build fingerprint

`Sources/IntentsAutomationCore/AutomationSimulatorCodecQualification.swift:26-40` hard-codes the only environment in which codec capabilities are granted:

- macOS `26B5101f`
- Xcode `27A266a`
- SDK `24A430`
- runner `27A252a`
- simulator runtime `24A434`
- a SHA-256 of `AppIntentsTesting.framework`
- `arm64`
- ad hoc simulator signing
- host template digest `3d754425…`

`applying(...)` grants `apple.codec.*` only when the live context equals this record exactly (`guard context == qualification.context`).

`PlanValidator.validate` then refuses any segment whose required capabilities are not `.available` (`AutomationPlan.swift:165`; `AutomationCodecRequirements.validate`).

Consequences:

- On any other Mac, after any macOS or Xcode update, or with any other simulator runtime, every action with a typed parameter or typed result is refused.
- Only seven families were ever qualified: text, bool, integer, decimal, enum, entity and integerArray. The rest (date, url, duration, calendarComponents, intentFile, textArray, boolArray, decimalArray, dateArray) are refused everywhere.
- The only way to widen the record is to edit source after a manual live run on that same machine. The shipped app can never qualify itself.

I recomputed the simulator host template digest from the current `Integration/AutomationHost` files and it still equals `3d754425…`. The gate is the environment, not template drift. **Any** edit to those templates would also silently revoke every capability.

### RC2 — The App Intents metadata reader accepts only two Xcode builds

`AutomationSurfaceCatalog.swift:39` sets `observedGenerators = ["27A266a", "27B5028f"]`.

Products built by any other Xcode return "Unknown built metadata format". The result is an empty action catalog: the Action picker is empty and nothing can be tested.

### RC3 — Authority lives only in memory, so a relaunch means a full rebuild

`AutomationPreparedCodecAuthority` is an in-memory actor ("Serialized build metadata cannot grant adapter admission in a new process; saved workflows must prepare again").

It is checked in:

- `AutomationSimulatorCodecQualification.swift:78`
- `AutomationSiriCapabilitySnapshot.swift:17`
- `AutomationPreparedPhysicalCampaign.swift:54`

The Siri route authority (`AutomationSiriQualificationAuthority`) is also process-local and is revoked on any non-pass.

So relaunching, crashing or restarting the app throws away all preparation. Saved cases cannot be re-run without rebuilding, and a failed attempt revokes the authority needed for the next one.

### RC4 — Routes are switched off in the production app

- `AutomationApplicationRunner.swift:35-36`: the only public initializer sets `physicalQualification = nil` and `macQualification = nil`. The only initializer that injects them is `internal` and used only by tests. In the shipped app:
  - Mac UI fails at line 111.
  - Physical installed-app UI fails at line 121.
  - Prepared Mac execution fails at lines 141 and 158.
- `FoundationEvals/FoundationEvals/Stores/AppAutomationStore.swift:196`: `canRun` returns false for any source target whose destination is not `.simulator`, apart from the Siri special case.
- `Views/AutomationSourcePreparationControls.swift:23` tells the user "Mac workflow execution is not available yet".

### RC5 — UI workflows need a sealed Node runtime that normal builds never contain

`Stores/AutomationNativeUIRuntime.swift:34-45` (`bundled`) requires two things:

- The running app has a 10-character Team ID.
- `Contents/Resources/Automation/runtime-manifest.json` exists and verifies.

Otherwise it throws "This app build has no signed UI runtime". Every UI, fresh-record and mixed plan requires this (`AutomationApplicationRunner.swift` `needsUI` branch).

Only the release pipeline stages that runtime, through `script/release.sh`, `automation_seal_app.sh` and `automation_package.sh`. None of these produce it:

- Xcode Run
- `script/build_and_run.sh`
- `xcodebuild test`, which builds the UI-test host app

Previous sessions hand-built "sealed candidates" in `/private/tmp` to get around this.

The runtime itself is a pinned Node 24 binary plus two third-party npm packages, `agent-device@0.21.20` and `e2e@0.17.0`, with local lifecycle patches. It also includes a patched macOS helper and Python staging, sealing and provenance scripts: about 15,000 lines under `Tools/IntentsAutomation`.

This stack drives the subject UI from a **separate** runner process. The code therefore needs a large body of cross-process ownership, release and zombie-inventory logic (leases, kernel PID/start identities, "release proofs"). The worklog's repeated failures come from this layer: runner retained or detached at close, the native pipe closing, `LOCATOR_NOT_FOUND`, and zombie admission blocks.

### RC6 — The v3 Siri route fails on iOS 27, and its toolchain needs conflict

1. `Integration/AutomationHost/SiriSubmissionTests.swift:66` calls `XCUIDevice.shared.siriService.activate(voiceRecognitionText:)` directly with no exception handling.
   - The project documented on 2026-09-26 that on iOS 27 "Siri performs the action while XCTest reports activation timeouts".
   - Intent Lab solved this with `Sources/IntentLabSiriBridge/SiriActivationBridge.m`. It catches `_XCTestCaseInterruptionException` / "Interrupting test" and recovers only when the app shows the completed action.
   - v3 does not use the bridge. The test aborts and `xcodebuild` exits non-zero.
   - `AutomationSiriRouteDriver.swift:134` turns any non-zero exit into `ambiguousDispatch`. The attempt becomes dispatch-uncertain and the device is quarantined (RC7).
2. Toolchains conflict:
   - Physical iOS and Mac targets need the Xcode whose `AppIntentsTesting` matches the device or host OS. Xcode 27.0 on iOS/macOS 27.2 produced zero executed tests because of a missing `resolveValue` symbol.
   - The simulator codec gate (RC1) requires Xcode `27A266a`, which is 27.0.
   - The app captures one `DEVELOPER_DIR` per launch. You cannot use simulator typed inputs and physical Siri or Mac in the same session.

### RC7 — Quarantine without recovery; Intent Lab is caught too

- `AppAutomationStore.swift:110-114, 363`: `retainedUnresolvedNormalReport` is set on any attempt that is not released or is dispatch-uncertain, and **nothing ever clears it**. Every run, search, reproduction and comparison button stays disabled until the app restarts.
- `AutomationDeviceLeaseManager.swift`: campaigns persist in `Automation/target-leases.json`. A campaign left by a dead process makes that target `targetBusy` forever.
  - `reconcile(...)` (line ~277) exists but App automation never calls it. Only Intent Lab's `ScenarioPhysicalRunnerLease.swift:112` does.
  - Lines 96 and 127 serialize **all** physical campaigns. One stuck physical record blocks every device.
- `Services/ScenarioCoordinator.swift:115`: Intent Lab now uses the same `Automation/target-leases.json`. A stuck v3 physical campaign can block the Intent Lab Siri path that used to work.

### RC8 — The UI "AI controller" relies on Apple's on-device model

`AutomationFoundationController.swift` drives arbitrary app UIs with `SystemLanguageModel.default`, using a long rule-heavy instruction block. The repository's own evaluations score it 2/4 progress (CURRENT.md, "Controller is 2/4"). The fresh-record flow chose the right button and then failed the locator re-check before tapping.

A small on-device model is not a reliable navigator, and its output feeds a strict fail-closed pipeline. The usual result is `invalidFixture` or `cannotProceed`.

### RC9 — Agents cannot see a real end-to-end run

- The live e2e tests are opt-in:
  - `testPreparedPureEchoShowsUnassessedNativeEvidence`
  - `testFreshDuplicateRecordsPreserveTheOtherOwner`
  - `testSelectedToolchainPreparesMacCopyAndSavesReviewedDraft`
  - `AutomationFreshWorkflowLiveTests`
- They skip unless a private JSON profile exists in `/private/tmp/foundation-evals-ui-tests/`. They point at a `DuplicateTasks` fixture that is **not in the repository**. CI never runs a live intent or UI automation.
  - *Amended 2026-10-13:* the fixture claim was out of date. `DuplicateTasks` has been committed since PR 75 (`f8de88e`), at `Verification/Automation/Fixtures/DuplicateTasks`. The profiles that drive these tests are still private.
- Local GUI verification depended on macOS Automation Mode. It failed with "Timed out while enabling automation mode", "requires user authentication". The computer-use control pipe closed on navigation, and Xcode MCP needed workspace approvals.
- So agents mostly ran fail-closed unit tests. There are 1,381 XCTest functions under `Tests/`, most proving refusals. Agents recorded "passed" source checkpoints that never exercised the product.

### RC10 — Process: acceptance criteria an agent cannot meet, plus ever-growing gates

- `Verification/Automation/ACCEPTANCE.md` and `CURRENT.md` (M0–M6) require items that are outside any agent's control:
  - twelve independently structured apps, including React Native and Flutter
  - three unfamiliar human onboarding trials
  - a clean Mac and an Intel Mac
  - Developer ID notarization
  - continuity and hardware replay
- Session rules such as "fail closed", "never retry unchanged", "preserve every failure", "do not bypass", plus 175 evidence JSON files, mean each blocker becomes a new gate rather than a fix. `CURRENT.md` is no longer readable as a status page.

### Current CI state

The last `main` push run ([run 38087463169](https://github.com/coryparrry/Intents/actions/runs/38087463169)) failed in "Portable regression tests":

- Test: `AutomationPrivateMacAppleRouteDriverTests.testOwnedLiveRunnerIsAdoptedAndTerminatedBeforeTheLeaseCanRelease`
- Location: `Tests/IntentsAutomationCoreTests/AutomationPrivateMacAppleRunnerReleaseTests.swift:38`
- Error: `terminationUnverified`, from `AutomationDeviceLeaseManager.swift:188`

The same suite passed on the release PR re-run. It is timing-dependent ownership-proof code (RC5).

---

## 4. The "Xcode-picker UI check fails at menu selection"

The check is `FoundationEvalsUITests/AppAutomationUITests/testUnpreparedPhysicalSiriFormKeepsSubmissionDisabled`, which CI runs (`.github/workflows/ci.yml:192`). It:

1. Opens App automation.
2. Uses NSOpenPanel with ⌘⇧G to pick `FoundationEvals.xcodeproj`.
3. Clicks the **Prepare for** popup.
4. Clicks the menu item "Physical iPhone or iPad".

It **passed** on the latest hosted run (release PR run 38087490007, attempt 2: 29.4 s). The failure is intermittent or local. The code has several fragilities that explain a menu-selection failure:

- `AppAutomationUITests.swift:21`: `app.menuItems["Physical iPhone or iPad"].firstMatch.click()` has no `waitForExistence`. The query covers the whole app, not the popup's menu. Other picks in the same test (`What to test`, line ~24) also lack waits.
- `AppAutomationView.swift:67`: the whole "Selected app" group is `.disabled(model.busy)`. `select(_:)` (`AppAutomationStore.swift:608`) runs project intake and catalog reads synchronously on the main actor. A click that arrives while the group is busy or disabled opens no menu.
- `AutomationSourcePreparationControls.swift:14-16`: Simulator menu titles include mutable state (`"\(name) · \(state)"`). Tests that select by exact title break when the simulator boots or shuts down. The worklog records this happening.
- NSOpenPanel driving (⌘⇧G, typing a path, `open-panel`/`OKButton`) is fragile. It already needed a fix for Touch Bar duplicates (`bb2fdd8`).
- On the developer Mac, UI tests also stall at "Timed out while enabling automation mode" unless Automation Mode is pre-authorized (see section 6).

The fix is in Phase 0.

---

## 5. Recovery plan for Codex

### Rules of engagement (apply to every phase)

1. **Every change must turn a failing end-to-end check green, or keep one green.** Do not add new authority gates, fingerprints, "qualification" records or evidence JSON files.
2. Verification is the headless CLI and the simulator e2e CI job (Phase 3). Do not depend on computer-use, Xcode MCP approval or GUI control. Add or fix a UI test only for GUI regressions.
3. When a safety check blocks a legitimate run, replace it with an observable check: exit code, timeout plus kill, or a state read-back. Do not add another proof layer.
4. Move parked code to a branch (`archive/v3-qualification`). Do not leave it compiled and half-enabled.
5. Keep `main` CI green at each merge. One phase per PR, in order.
6. Do not touch the evaluation workbench, telemetry, website or release tooling except where a step names them.
7. *(Amended 2026-10-13.)* A pass counts only if it goes through the code path the app uses. CLI and probe runs must resolve capabilities with the app's own code. Never supply capability records in a profile; a run that does is a driver check, not a pass.
8. *(Amended 2026-10-13.)* Report status in plain language. Say:
   - which route ran: the app, the CLI or Intent Lab;
   - where it ran: simulator, iPhone or Mac, and whether CI reproduces it or it ran once on this Mac;
   - whether the change is merged, released, or only in a PR or the local checkout.

   Commit this plan and a short README per phase with each phase's PR. Keep raw logs and profile JSON out of git.

### Phase 0 — Stabilize (small PR)

Status: **complete, 2026-10-13**. Merged in [PR 134](https://github.com/coryparrry/Intents/pull/134) as `c9972a3e698be8ed68f904a8af57a8379667437f`; [CI is green on main](https://github.com/coryparrry/Intents/actions/runs/38323206793) after one targeted portable-test retry. The local Developer ID signed picker passed 10/10 with `-test-iterations 10`, and cancel/reset/rerun recovery tests passed. Main also passed all 21 selected UI tests and ten picker repetitions. See `Verification/Recovery-Phase0-20261012/WORKLOG.md` for scope, signing and verification details.

1. **CI green.** Fix `testOwnedLiveRunnerIsAdoptedAndTerminatedBeforeTheLeaseCanRelease`: replace the fixed wait with polling until a deadline. Alternatively, do Phase 8's parking of the private-Mac subsystem first, which removes the test with its code. Do not skip or disable the test while its code still ships.
2. **Quarantine recovery in App automation.**
   - Add `AppAutomationStore.clearUnresolvedAttempt()` behind a "Reset device ownership…" confirmation. It should:
     - shut down the simulator (`xcrun simctl shutdown <id>`) for simulator targets;
     - call `AutomationDeviceLeaseManager.reconcile` for campaigns whose owner process is absent;
     - clear `retainedUnresolvedNormalReport`.
   - On store init, automatically reconcile campaigns whose `owner.presence()` is `.absent` or `.replaced`.
   - Remove the "any physical campaign blocks all physical devices" rule at lines 96 and 127. Key physical leases by the CoreDevice UUID, resolved once with `devicectl`.
3. **Separate Intent Lab's lease store** from App automation's, or apply the same automatic reconciliation in `ScenarioCoordinator` (`Services/ScenarioCoordinator.swift:115`), so a v3 failure cannot block Intent Lab.
4. **Stabilize the picker UI test:**
   - Add `.accessibilityIdentifier` values to the `Prepare for`, `Simulator`, `What to test` and `Action` pickers, and stable identifiers to their items (destination raw values; simulator UDIDs instead of name and state).
   - In tests, always `waitForExistence` on the menu item and scope it to the popup (`destination.menuItems[...]`).
   - Add a DEBUG-only launch argument `--automation-select-path <path>` that calls `model.select(URL(fileURLWithPath:))`. Use it in every App automation UI test instead of NSOpenPanel. Keep one test that covers the real panel's cancel path.
   - Move `AutomationApplicationIntake.assess` and the catalog read in `select(_:)` / `selectCandidate()` off the main actor. Set and clear `progress` around them so tests can wait for "not busy".

Acceptance: CI green on `main`. A test cancels an unresolved attempt, resets it and runs again. The picker test passes 10/10 locally with `-test-iterations 10`.

### Phase 1 — Make typed App Intent testing work on any supported Mac

**Execution update, 2026-10-13:** PR 135 had already merged as `f03d36497` before this request. Phase 1 is being delivered as a separate PR from that main commit. The implementation and independent reviews are complete; local Xcode 27.0 mixed-workflow acceptance and automation regressions pass. Xcode 27.2 and the native UI check remain in progress. See [Phase 1 verification](Verification/Recovery-Phase1-20261013/README.md). The original amended instructions below record the intended merge order.

*Amended 2026-10-13.* Status: **not started, and now required before PR 135 merges.**
- PR 135 adds `UIHostPlan.swift` and `UIStepTests.swift` to the host templates, so the prepared host's template digest becomes `815a51c0…`.
- That matches neither hard-coded record, so `enrich` grants no `apple.codec.*` capability on any Mac. In the app, every plan with a typed parameter or result is refused.
- Land this phase as its own PR on `main`, then rebase PR 135 onto it.

1. **Remove the fingerprint gate** (`AutomationSimulatorCodecQualification`):
   - Grant all codec families the host templates implement, whenever the prepared host built and its digests verify.
   - Report conversion failures as ordinary attempt failures with the host's error text. `HostValueBudget.boundedErrorDescription` already carries it.
   - Keep the canary (`InputAdapterProbeTests`) as an optional "Check input conversion" diagnostic button and as a CI test (Phase 3). It must not gate execution.
2. **Remove the generator allow-list** (`AutomationSurfaceCatalog.swift:39`). Parse `extract.actionsdata` by schema `version == 1`. On an unfamiliar generator version, add a gap note ("built with Xcode X; metadata parsed best-effort") instead of returning an empty catalog.
3. **Persist preparation authority.** Replace `AutomationPreparedCodecAuthority` with a check that re-verifies on-disk digests of the prepared subject, host and xctestrun. `AutomationProductDigest.compute` and `verifyGeneratedSources` already exist. On launch, load the most recent prepared record (`AutomationPreparedApplicationRecord`) so saved cases re-run without rebuilding when digests match.
4. **Per-target Xcode selection.**
   - Store the chosen Xcode per destination type (simulator / device / Mac) in settings, and allow overriding per run, instead of one `DEVELOPER_DIR` per launch.
   - Before preparing for a device or Mac, compare the target OS version with the Xcode platform SDK version. If they differ, show "Install Xcode matching iOS X.Y (current: …)".
5. Delete `legacyQualified`/`qualified`, the hard-coded report hashes, and any test that asserts denial for unknown environments.
6. *(Amended 2026-10-13.)* Start with a failing regression test. Prepare a host from the current templates, including `UIStepTests.swift`, with no capabilities supplied. A plan that needs `apple.codec.entity` must pass `PlanValidator` after `capabilitiesForExecution`. Today it throws `missingEvidence`.
7. *(Amended 2026-10-13.)* Remove the `capabilities` field from `IntentsAutomationApplicationProbe` profiles. The probe must call `capabilitiesForExecution` with the same base profile the app builds (`AutomationNativeFreshFixtures.capabilities`).

Acceptance: on the simulator CI job (Phase 3), the fixture's echo intents for **every** codec family run and return exact values with the runner's Xcode, which is not 27A266a.

*Amended 2026-10-13.* Until that job exists, the acceptance for this phase is:
- the item 6 test passes;
- the Phase 2 DuplicateTasks mixed workflow passes through the app's capability path, with no capabilities supplied. The workflow is: UI create, then `CompleteTaskIntent`, then an independent query. Run it twice, once with Xcode 27.0 and once with Xcode 27.2 beta 2 (`/Applications/Xcode-27.2.0-Beta.2.app`).

The test iPhone is on iOS 27.2, so once the gate is gone, a single Xcode that matches the iPhone should serve both the simulator and the device.

### Phase 2 — Replace the Node/agent-device UI stack with in-host XCUITest steps

Status: **completed locally on 2026-10-13**. The mixed simulator case passes in one Xcode test invocation using templates bundled in an ad hoc Intents Debug build with no Team ID. Deliberate UI assertion failure persists with scoped evidence and verified cleanup. Core/native regressions and independent review pass; one unrelated portable startup test passed on isolated retry after failing under parallel load. See [Phase 2 verification](Verification/Recovery-Phase2-20261013/README.md). Physical/Mac UI qualification remains in Phases 4 and 5.

*Amended 2026-10-13:*
- **PR status.** PR 135 is open at `8f0234c26`, with CI green. **Hold the merge until Phase 1 lands** (see Phase 1).
- **What the passes prove.** Both passing runs used `IntentsAutomationApplicationProbe` profiles that supplied `apple.codec.*`, `apple.intent.invoke` and `apple.entity.query` as available. That proves the in-host driver, not the app path. After rebasing on Phase 1, rerun both runs without supplied capabilities.
- **Known limitation.**
  - Removing the sidecar also removed UI workflows for installed apps without source, so UI tests now need the app's Xcode project.
  - That is fine for the user's own apps.
  - If apps without source are needed after Phase 4A, revisit: a generic signed XCUITest runner can drive any installed app by bundle ID.

The generated host (`AutomationHostGenerator.swift`) is already a `com.apple.product-type.bundle.ui-testing` target with `TEST_TARGET_NAME` set to the subject app. It can drive the subject UI with `XCUIApplication` in the same test that invokes intents. That removes:

- the separate runner process;
- the cross-process ownership hand-off;
- the sealed Node runtime;
- the Developer ID requirement.

1. Add `Integration/AutomationHost/UIStepTests.swift` with `testUISteps()`. It reads `INTENTS_AUTOMATION_UI_PLAN_B64`, following the `SegmentTests` pattern. A plan is an ordered list of steps:
   - `launch(arguments, environment)`
   - `tap(query)`
   - `typeText(query, text | binding)`
   - `clearAndType`
   - `swipe(direction, query?)`
   - `waitFor(query, exists|hittable|absent, timeout)`
   - `assert(query, property: label|value|exists|selected, equals)`
   - `screenshot(name)`
   - `invokeIntent(HostOperation)` (reuses `IntentDefinitionsHost.execute`)
   - `query(entity…)`

   A query is `{identifier?, label?, labelContains?, elementType?, index?}`. Each step writes a JSON receipt attachment and a screenshot on failure. The existing `xcresulttool export attachments` import path already handles this.
2. Add a Swift `AutomationXCUITestRouteDriver` in `IntentsAutomationCore`. It writes the plan, runs `xcodebuild test-without-building -only-testing:<host>/UIStepTests/testUISteps` against the prepared xctestrun, applies a timeout (terminate the process group on expiry, then `simctl terminate`), and imports receipts. Mixed UI + intent + query plans run as **one** test invocation.
3. Point the "App workflow" and "Action on a new test record" routes at this driver. The record-creation step list comes from the form fields; no model is needed.
4. Make `AutomationApplicationRunner`'s non-simulator branches use the same driver (Phases 4 and 5), and remove `uiRuntime` from the run APIs.
5. Delete the sidecar route: `AutomationSidecar*.swift`, `AutomationMixedRouteDriver`'s UI-sidecar path, `AutomationRuntimeBundle`, `AutomationNativeUIRuntime`, and `Tools/IntentsAutomation/**`. Remove the automation packaging steps from `script/release.sh`, the `automation_*.sh` scripts, and the related CI routes.

Acceptance:

- A simulator e2e test drives the fixture app's UI to create a record, invokes an intent on it, and reads it back through an entity query. The result is `passed`, all in one xcodebuild invocation.
- This works from an Xcode **Debug** build of Intents with no Team ID.

### Phase 3 — Headless CLI and CI end-to-end job (the source of truth for agents)

1. Add a committed fixture app, `examples/AutomationFixture`, generated with XcodeGen like the other examples. It needs:
   - echo intents for every codec family;
   - a `Task` entity with title, owner and completed fields, plus an entity query;
   - a simple SwiftUI list/add/complete UI with accessibility identifiers;
   - an App Shortcut phrase for Siri.

   This replaces the private `/private/tmp` DuplicateTasks copies.

   *Amended 2026-10-13:* start from the committed `Verification/Automation/Fixtures/DuplicateTasks`. It already has the `Task` entity, the query, `CompleteTaskIntent`, the list/add UI and the accessibility identifiers. Move it to `examples/AutomationFixture`, then add the echo intents for every codec family and the App Shortcut phrase it lacks.
2. Extend `Tools/IntentsAutomationApplicationProbe` into a supported CLI, `intents-automation`, with subcommands:
   - `prepare --project <xcodeproj> --scheme/--target --destination sim:<udid>|device:<id>|mac [--xcode <path>]`
   - `actions` (print catalog)
   - `run --plan plan.json`
   - `show <attempt>`

   It uses the same `AutomationApplicationRunner` and case store as the app, and prints JSON reports.

   *Amended 2026-10-13:* it must also resolve capabilities exactly as the app does. Plans and profiles cannot carry capability records (Phase 1, item 7).
3. Add a CI job, "Automation e2e (simulator)", on the hosted `xcode-27` runner:
   - create a simulator;
   - `prepare` the fixture;
   - run plans for every codec family;
   - run a UI-plus-intent-plus-query workflow;
   - run a deliberately failing assertion that must report `failed`;
   - run a timeout case that must not leave a quarantine.

   Route it in `script/ci_routes.py` whenever `Sources/IntentsAutomationCore`, `Integration/AutomationHost`, `Stores/AppAutomation*` or `examples/AutomationFixture` change.
4. Make the opt-in live UI tests (`AppAutomationUITests` echo and fresh-record tests, `MacPreparationUITests`) use the committed fixture and the `--automation-select-path` launch argument. They should run without private profiles.

Acceptance: the e2e job runs on every relevant PR and is green. Codex can reproduce it locally with one command documented in `docs/wiki/App-automation.md` (new page).

### Phase 4 — Physical devices and Siri

1. **Physical System action and UI:** allow `.physical` in `canRun`. Run through the Phase 2 driver with `-destination platform=iOS,id=<udid>` using the prepared signed host. Development signing uses the subject project's `DEVELOPMENT_TEAM`, which the generator already copies.
2. **Siri:**
   - Make `SiriSubmissionTests` call the ObjC bridge from `IntentLabSiriBridge` (or a copy in the host templates). Treat `_XCTestCaseInterruptionException` / "Interrupting test" as "submitted, outcome pending".
   - Assess the outcome by an entity query before and after **in the same test method**, using the Phase 2 plan with `query` steps. Do not use the XCTest exit code.
   - In `AutomationSiriRouteDriver`, parse receipts even when `xcodebuild` exits 65, and map a missing receipt to `failed` (not `ambiguousDispatch`) when the test reached its dispatch checkpoint.
3. Remove `AutomationSiriQualificationAuthority`, `AutomationSiriRouteAuthority`, the `siri.actualRoute` capability and the `installedBytesVerified` comparison denial. A Siri run with a before/after state check is the assessment.
4. Device release: after the run, `xcrun devicectl device process terminate` the host runner if it is still listed. Don't block future runs on unverifiable remote absence. Record the warning in the report.
5. *(Amended 2026-10-13.)* **The first iPhone run is the CI fixture workflow.**
   - Before Siri, run the same UI + intent + query plan that passes in the Phase 3 job on the iPhone, through the app.
   - Use the Xcode that matches the device OS. The test iPhone is on iOS 27.2, so that is `/Applications/Xcode-27.2.0-Beta.2.app`.
6. *(Amended 2026-10-13.)* **Preflight before install, with one plain-language error per failure.** Check that:
   - the device is paired and trusted;
   - it is unlocked and in Developer Mode;
   - UI Automation is enabled (Settings › Developer);
   - a signing team is set;
   - the device OS matches the selected Xcode's SDK.
7. *(Amended 2026-10-13.)* **Don't quarantine the iPhone.** PR 135 keeps ownership when it cannot confirm that the runner exited. On a physical device, apply item 4 instead: record a warning and don't block the next run.

Acceptance (needs the human's device, see section 6): on the fixture, the Siri phrase "Complete <task> in Automation Fixture" flips `completed` from false to true and reports `passed` three times in a row. A wrong expected value reports `failed`. Neither leaves a quarantine.

*Amended 2026-10-13.* Also required:
- the fixture's UI + intent + query workflow passes 3/3 on the iPhone through the app;
- a wrong expectation reports `failed`;
- no run leaves a quarantine.

An agent can run these checks while the user's iPhone is connected and unlocked.

### Phase 4A — Real apps on the iPhone (added 2026-10-13)

The fixture proves the mechanism. Real apps prove the route isn't fixture-specific, which is the user's actual goal: testing any of their iPhone apps.

1. **Pick the apps.** Use FlipBook (`~/Developer/Projects/FlipBook`) and one other iOS app the user picks.
   - Prepare each from its Xcode project for the iPhone, through the app.
   - Don't edit either checkout. FlipBook has another agent's uncommitted work.
2. **Write the plans.** Write a deterministic step plan for one real flow per app, using its accessibility identifiers. FlipBook has some already, for example `identify.selected-photo` and `analytics.ai.analyse`.
   - Use an app's own test launch settings where it has them, such as FlipBook's `FLIPBOOK_UI_TEST_*` environment.
   - Add any step kinds real apps need. Answering system permission alerts through Springboard is the likely first one.
3. **Fix gaps without new gates.** Turn each gap you find into a fix, not a new gate.

Acceptance:
- for each app, one real flow passes 3/3 on the iPhone through the app;
- a wrong expectation fails;
- nothing is left quarantined.

Phase 5 can follow this phase; the user's priority is the iPhone.

### Phase 5 — Mac targets

1. The generator already supports macOS (`AutomationHostGenerator.swift`: `SDKROOT macosx`). Run the Phase 2 driver with `-destination platform=macOS`, for intents and UI steps.
2. Enable `.nativeMac` in `canRun`. Remove `macQualification`, `AutomationMacUIQualification`, `AutomationPrivateMac*`, `AutomationMacNativeHelperBridge`, the owned daemon/SDK units, and the "Mac drafts only" UI copy.
3. Document that macOS UI steps need Accessibility and Automation Mode permission for the test runner (one-time, section 6).

Acceptance: a Mac build of the fixture (add a macOS target) passes the same intent and UI plan through the CLI and the app.

### Phase 6 — Reproduce and check a fix

1. A saved case is the frozen plan JSON plus the prepared source digest. **Re-run** rebuilds from the current source, runs the same plan and compares assertions and outputs with the saved attempt.
2. Reuse `AutomationFixComparison` but drop the requirements for installed-byte equivalence and "30+30" attempts. Default to N=3 attempts per side, configurable.
3. **Find failures** (phrase variations) stays, using deterministic step plans. Model-generated variations are optional (Phase 7).

Acceptance: the CI e2e job saves a failing case against a deliberately broken fixture variant, then re-runs it against the fixed variant and reports "fixed".

### Phase 7 (optional, after Phases 0–6 are green) — AI-assisted authoring

*Amended 2026-10-13:* this phase uses AI to draft UI steps. Testing an app's own AI features is Track B, which is separate.

- Add "Draft steps with AI". It captures one accessibility snapshot of the launched subject (from a `snapshot` step's attached element tree), sends it with the user's goal to the user's chosen provider, and turns the reply into a reviewable step list.
- Use the app's existing provider settings (on-device, custom HTTP or Core AI). Do not hard-wire `SystemLanguageModel`.
- The saved test is always the reviewed deterministic step list. The model never drives a live run.
- Delete `AutomationFoundationController`, `AutomationGuidedNavigationDecision` and the controller probes, or move them to the archive branch.

### Phase 8 — Park what is no longer used

Move to `archive/v3-qualification`, then delete from `main`:

- `Tools/IntentsAutomation/`, `Tools/IntentsAutomation{Ownership,Execution,Preparation,Controller}Probe/`, and the `automation_*.sh` packaging scripts.
- `Sources/IntentsAutomationCore`:
  - `AutomationSidecar*`
  - `AutomationPrivateMac*`
  - `AutomationMacNativeHelperBridge*`
  - `AutomationRuntimeBundle`
  - `AutomationProcessIdentity`-based whole-UID inventory
  - `AutomationSimulatorCodecQualification`
  - `AutomationPreparedCodecAuthority`
  - `AutomationSiriQualification*`
  - `AutomationSecret*` (credential fill)
  - `AutomationPhysicalUIQualification`
  - `AutomationMacUIQualification`
- The tests that only assert refusals for those files.
- `Verification/Automation/*.json` evidence and `CURRENT.md`, `ACCEPTANCE.md`, `HANDOFF-*`, `CONTINUATION-*` and `FINISH-WORKLOG.md`. Replace them with this document (`Verification/Automation/RECOVERY-PLAN-2026-10-12.md`) plus a short `Verification/Automation/STATUS.md` that lists only the e2e jobs and their latest results.
- `Package.swift` targets and `script/ci_routes.py` entries for the removed code.

Acceptance: `swift test` and `xcodebuild test` pass. `IntentsAutomationCore` is substantially smaller. All e2e jobs stay green.

### Track B — AI answer quality on the iPhone (added 2026-10-13, runs in parallel)

This is what the FlipBook Private Cloud Compute work did: run many known-answer cases through an app's real AI feature on the iPhone, collect structured results, grade them and rerun after changes.

Screen steps are the wrong tool for this job:
- AI answers are long and vary between runs.
- Inputs include photos.
- Grading needs known facts.

Use the `FoundationEvalsDeveloper` SDK instead. It is on `main` but has never run on a phone with a real app. Track B does not block Phases 1–8, and they do not block it.

1. **Prove the transport.** Run `Verification/DeveloperRunnerTestHost` on the iPhone, pair it with Intents, and run its echo feature from the evaluation workbench.
2. **Integrate FlipBook.**
   - Ask the user first: the source is FlipBook's uncommitted `ApplePCC*` work from another thread.
   - In a Debug-only screen, register identify, draft and summary features that call the same production code `ApplePCCDeviceVerification.swift` calls, and embed `DeveloperRunnerView`.
   - The desktop sends only `DeveloperTextFeatureInput` today (`EvaluationDeveloperFeatureAdapter.swift`). Start with a text input that names a bundled fixture photo (`FlipBookTests/Fixtures/PCCResale`). Add binary inputs to the SDK only if that proves insufficient.
3. **Run and grade the cases.**
   - Import FlipBook's existing cases (12 photos, 5 drafts, 6 summaries) as an Intents suite with their expectations, and run it on the iPhone.
   - Grade with deterministic checks first and a judge second.
   - Rerun after a change and compare.
4. **Document it.** Write a short guide, "Testing AI features on iPhone", that generalizes these steps for any app.

Acceptance:
- from Intents, FlipBook's cases run on the iPhone against the real model;
- results are saved and graded in Intents;
- a rerun shows the comparison;
- a wrong expectation fails.

---

## 6. New definition of done (replaces M0–M6)

Automation is done when all of the following are green, on CI where marked, or with one recorded manual run by the human where marked:

1. **CI:** simulator e2e. Every codec family echoes exactly. A UI + intent + query workflow passes. A wrong expectation fails. A timeout cleans up with no quarantine.
2. **CI:** App automation UI tests pass using the committed fixture: select, prepare, run, view saved result, reset ownership.
3. **CI:** CLI `prepare`/`run`/`show` round-trip.
4. **Manual (human):** physical iPhone Siri state check passes 3/3 on the fixture, and a wrong expectation fails.
5. **Manual (human):** Mac fixture intent + UI plan passes.
6. **CI:** Reproduce and Check fix on the broken versus fixed fixture.

*Amended 2026-10-13:*

7. **iPhone** (agent-run on the user's connected iPhone): the fixture's UI + intent + query workflow passes 3/3 through the app (Phase 4).
8. **iPhone:** one real flow each in FlipBook and one other user app passes 3/3 (Phase 4A).
9. **iPhone:** FlipBook's AI cases run from Intents through the SDK, and are saved and graded (Track B).
10. **Everywhere:** no capability is supplied by hand; the CLI and the app share one capability path.

These are **not** in scope for the agent: twelve independent apps, React Native/Flutter, unfamiliar-user trials, Intel, clean-host and notarization qualification. Track them as separate product milestones owned by the human.

### What only the human can do (do these before Phase 4)

- Pre-authorize UI automation on the dev Mac: `sudo automationmodetool enable-automationmode-without-authentication`. Grant Accessibility to Xcode's test runner.
- Install the Xcode whose iOS/macOS SDK matches the test iPhone's iOS and the Mac's macOS. Keep the iPhone connected, unlocked, in Developer Mode, with Siri enabled and the scenario language set.
- Set a development team for the fixture.
- *(Amended 2026-10-13)* On the iPhone, enable UI Automation in Settings › Developer and keep the phone unlocked during runs.
- *(Amended 2026-10-13)* Choose the second app for Phase 4A.
- *(Amended 2026-10-13)* Decide whether Track B may build on FlipBook's uncommitted `ApplePCC*` work.
- *(Amended 2026-10-13)* Approve the merge order: the Phase 1 PR, then PR 135, then release PR 130.

---

## 7. File and line index

| Finding | Location |
|---|---|
| Environment fingerprint | `Sources/IntentsAutomationCore/AutomationSimulatorCodecQualification.swift:26-40, 42-56, 57-139` |
| Capability enforcement | `Sources/IntentsAutomationCore/AutomationPlan.swift:165`; `AutomationCodecRequirements.swift` `validate` |
| Generator allow-list | `Sources/IntentsAutomationCore/AutomationSurfaceCatalog.swift:39, 51` |
| Process-local authority | `AutomationPreparedCodecAuthority.swift`; uses at `AutomationSimulatorCodecQualification.swift:78`, `AutomationSiriCapabilitySnapshot.swift:17`, `AutomationPreparedPhysicalCampaign.swift:54` |
| Disabled routes | `AutomationApplicationRunner.swift:35-36, 111, 121, 141, 158`; `FoundationEvals/FoundationEvals/Stores/AppAutomationStore.swift:196`; `Views/AutomationSourcePreparationControls.swift:23` |
| Sealed runtime requirement | `FoundationEvals/FoundationEvals/Stores/AutomationNativeUIRuntime.swift:34-45`; `script/automation_package.sh`, `automation_seal_app.sh`; absent from `script/build_and_run.sh` |
| Siri iOS 27 abort | `Integration/AutomationHost/SiriSubmissionTests.swift:66`; `AutomationSiriRouteDriver.swift:134`; working bridge `Sources/IntentLabSiriBridge/SiriActivationBridge.m` |
| Quarantine with no clear | `AppAutomationStore.swift:110-114, 363`; `AutomationDeviceLeaseManager.swift:96, 127, ~277` |
| Shared lease store with Intent Lab | `FoundationEvals/FoundationEvals/Services/ScenarioCoordinator.swift:115`; `ScenarioPhysicalRunnerLease.swift` |
| On-device controller | `Sources/IntentsAutomationCore/AutomationFoundationController.swift:10-26` |
| Picker test | `FoundationEvals/FoundationEvalsUITests/AppAutomationUITests.swift:20-25`; `Views/AppAutomationView.swift:67`; `Views/AutomationSourcePreparationControls.swift:14-16` |
| Red CI on `main` | `Tests/IntentsAutomationCoreTests/AutomationPrivateMacAppleRunnerReleaseTests.swift:38`; run 38087463169 |
| Last proven e2e | `Verification/INTENT_LAB_E2E_2026-09-26.md` |
| Probe profiles supply capabilities *(2026-10-13)* | `Tools/IntentsAutomationApplicationProbe/ApplicationProbe.swift:119`; `Verification/Recovery-Phase2-20261013/debug-bundle-run-profile.json`, `mixed-run-profile-3.json` |
| PR 135 changes the template digest *(2026-10-13)* | `Integration/AutomationHost/UIHostPlan.swift`, `UIStepTests.swift`; `debug-templates-prepared.json` (`815a51c0…`); gate at `AutomationSimulatorCodecQualification.swift:72-77` |
| App automation UI is simulator-only *(2026-10-13)* | `FoundationEvals/FoundationEvals/Stores/AppAutomationStore.swift:232-234` (PR 135) |
