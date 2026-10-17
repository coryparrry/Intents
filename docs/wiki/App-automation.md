# App automation

Use `intents-automation` to prepare an app, inspect its actions, run a reviewed plan and read a saved attempt. It uses the same runner, capability resolution and case store as Intents. Plans and profiles must not supply capability records.

## Reproduce the simulator checks

From the repository root, with Xcode and XcodeGen installed:

```sh
python3 script/automation_e2e.py
```

The command generates the committed `examples/AutomationFixture` project, builds the CLI, creates its own simulator and prepares the fixture once. It checks exact returned values for all 16 codec families and empty arrays, runs UI create → App Intent → independent query, checks a deliberately wrong assertion, and checks a timeout followed by a successful run. It shuts down and deletes only its own simulator. Raw reports, profiles, screenshots, products and logs stay outside git.

After preparation, the harness installs the frozen fixture once and disables case-level boot and installation. Before running the contract, it requires the fixture's harmless `EchoTextIntent` to return its exact readiness value. Only that readiness probe can retry, with at most three total attempts, for the matching metadata-not-present error after resource release and without reported dispatch, completion or receipts. The codec, mixed-workflow and negative cases still run once. `registration-readiness.json` records each readiness attempt and its result. Because XCTest can manage app installation again when starting a host, each iOS Simulator fixture host also runs the same fixed echo before any tested operation dispatches. That diagnostic has at most three attempts, with five-second pauses only for the exact fixture metadata-not-present error, and checks the existing host deadline before and after each probe and pause. Separate `intents-fixture-registration-*` attachments record its attempts; tested operations and their receipts remain unchanged. The project compilation flag enables this preflight only for the authored simulator fixture; customer, Mac and physical-device hosts do not invoke it. Individual App Intents calls still rely on the existing outer owned-command timeout for a hard stop.

Use `--xcode <Xcode.app>` to select a toolchain, `--output-root <empty-directory>` to retain a run at a chosen location, and `--build-root <directory>` to reuse an external Swift build cache. Both directories must be outside the checkout; the cache is preserved.

The hosted **Automation e2e (simulator)** job runs the same command on relevant PRs. Echo attempts remain `executedUnassessed`; the script compares their actual returned values exactly. The mixed workflow must have the app's assessed `passed` verdict. The negative checks must report `assertionFailed` and `timedOut`, release resources, and leave no held campaign.

## Reproduce the native Mac checks

Run from an active local Mac GUI login session with Xcode and XcodeGen installed:

```sh
python3 script/automation_mac_e2e.py --xcode /Applications/Xcode.app --build-root /private/tmp/intents-mac-build \
  --signing-team <APPLE_TEAM_ID> --signing-identity <APPLE_DEVELOPMENT_CERTIFICATE_SHA1>
```

Native Mac intent execution requires an installed Apple Development signing identity and matching ten-character team ID. The harness accepts both explicitly and changes signing settings only in its disposable fixture copy. It verifies the prepared app, test runner, and test bundle against the requested certificate fingerprint, Apple trust anchor, and team before running any intent. `signing.json` and the comparison signing files retain actual signature metadata and public certificates. The harness never installs credentials or exports private keys. Ad hoc signing remains available for general Mac UI-only checks; it cannot qualify this intent acceptance contract.

Use `--cli <executable>` to reuse an existing CLI with its resource bundle instead of building it, or `--jobs <count>` to change the default of two Swift build jobs. `--output-root <empty-directory>` retains evidence at a chosen external path. The harness stages disposable fixture copies outside the checkout and prepares `AutomationFixtureMac` with `--destination mac`. It uses the captured GUI login session, ordinary CLI capability resolution, and no simulator.

The five checks compare exact outputs for the 15 supported Mac codec families and empty arrays, run UI creation → App Intent → independent entity query, require a deliberately wrong assertion to fail, and then require another exact echo to succeed. Each attempt must release resources, leave no held campaign, and match its saved CLI report. Echoes remain `executedUnassessed`. Native Mac XCUITest plans do not support `IntentFile` transfer between segments, so this contract excludes the file case and does not qualify that codec. The simulator contract retains its file-transfer check.

The harness also stages a source defect that persists `completed = false`, records one genuine failing task-completion attempt, restores the original source, and compares three fresh attempts against each separately prepared build. Every repeat creates a unique task through the UI and checks its initial state before the intent. A successful harness result requires all three baseline assertions to fail, all three candidate assertions to pass, identical frozen checks, different source and product digests, and the CLI comparison outcome `fixed`. This is finite evidence for that fixture and current Mac session. Raw command logs, prepared products, reports, source hashes, and the comparison remain outside Git in the evidence directory.

## Use the CLI

Build the supported product:

```sh
swift build --jobs 2 --product intents-automation
```

Use the executable in the directory printed by `swift build --show-bin-path`; keep its SwiftPM resource bundle alongside it. Examples below call that executable `intents-automation`.

```sh
intents-automation prepare --project examples/AutomationFixture/AutomationFixture.xcodeproj --scheme AutomationFixture --destination sim:<udid> --support-root <directory>
intents-automation actions --support-root <directory>
intents-automation run --plan <plan.json> --support-root <directory>
intents-automation show <attempt-id> --support-root <directory>
```

Choose a target with `--target` instead of `--scheme`. Destinations are `sim:<udid>`, `device:<id>` or `mac`. `prepare --xcode` selects an Xcode app or developer directory; otherwise preparation uses `DEVELOPER_DIR` or the developer directory selected by `xcode-select -p`. Later runs use the retained preparation toolchain. The default support directory matches the app; `--support-root` isolates tests. `actions` prints the saved catalog, and `show` reads a saved attempt without running the app.

A run request contains a concrete `AutomationCase` plan and explicit install/boot consent. It binds approval to that plan's app, target, environment, effects, budget and digest. The CLI resolves capabilities from the retained preparation and actual execution path. It prints JSON, keeps the runner's verdict, and returns a nonzero status for failed, timed-out or unreleased attempts.

The e2e script provides concrete plan examples in its temporary output. Historical probe-profile and controller-recipe execution modes have been removed; use the commands above with a reviewed deterministic plan.

## Review checks in the app

App automation can inspect a selected app, an IPA archive, a source folder, or a repository checkout. Source preparation can review XcodeGen, Tuist, or a selected packaging script before running it in a frozen source copy. The review binds the selected toolchain and captured dependencies; changing them requires a new review. A recipe is not approval to invoke the app's actions.

After preparation, **Run checks** lists the initial observations and discovered actions that have enough input evidence. Supply typed values or choose a freshly queried entity where required, then choose the actions' effects and review the proposed checks. Missing input or observation evidence remains a visible gap. Successful invocation alone does not establish business correctness.

**Connected app feature** runs a feature registered through an existing trusted connection. Review its app version, feature version, effects, and request before sending it. An expected response stays in Intents for independent comparison. A timeout or disconnect leaves the outcome unresolved and prevents automatic repetition; registration does not verify remote build bytes or model internals.

Physical Siri failure search additionally requires a reviewed disposable record, its initial and expected state, an independent observer, and a matching reset action. Each trial runs the reviewed request and assesses the independently observed state change. Restoration, trials, and confirmation share the reviewed budget, and uncertain submission or release stops the campaign. Local unit tests do not qualify a real device or account.

## Evidence boundaries

The required Phase 3 checks run the CLI on an iOS simulator. They do not qualify iPhone, Siri or Mac subject execution, or Intent Lab. The fixture declares a Siri phrase for the later physical-device phase. Opt-in native UI tests use a staged copy of this same committed fixture and runtime settings, without private profiles. The live setter/readback diagnostic is Mac-only and runs in the separate **Input conversion diagnostic (Mac)** CI job. It checks an authored String parameter without invoking its business action. Simulator echo tests exercise conversion directly; the diagnostic never grants capabilities or gates execution.

## Opt-in app UI checks

Stage a disposable copy of `examples/AutomationFixture` at `/private/tmp/foundation-evals-ui-tests/AutomationFixture` and run XcodeGen there. Set `INTENTS_AUTOMATION_LIVE_UI=1`, `INTENTS_AUTOMATION_SIMULATOR_UUID` to the simulator owned by the test run, and optionally `INTENTS_AUTOMATION_DEVELOPER_DIR`. The tests select the staged project with `--automation-select-path`; the Mac preparation test needs no simulator ID. Shut down any simulator you booted after the run. These app UI checks remain opt-in and separate from the required CLI simulator job.

## CI Mac development signing

The live Mac UI fixture and Mac acceptance job require a separate **Apple Development** signing identity so the fixture and generated XCTest runner share a team. Configure the dedicated repository secrets `CI_MAC_CERTIFICATE_P12_BASE64` and `CI_MAC_CERTIFICATE_PASSWORD`, plus the public repository variable `CI_MAC_SIGNING_TEAM` (the ten-character team ID). Do not use the release or Developer ID identity. The wrapper imports the credential into an ephemeral keychain, removes the P12 before running tests, then restores the runner search list and deletes its keychain. Missing or invalid signing configuration fails the required gate; it never skips these checks.
