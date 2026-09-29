# Test and retest an app feature with Intent Lab (Beta)

[Home](Home.md) · [App feature runners](App-feature-runners.md) · [Data and troubleshooting](Data-and-troubleshooting.md)

Intent Lab connects to a signed Xcode UI-test target and app-owned test support. A project-local test control is the default App Feature path; a separately connected developer runner remains an explicit alternative. A saved developer check freezes the request, typed inputs, fixture, expected action and outcome. Each coordinated run labels App Feature, direct App Intent and Siri separately. After changing your app, run **Check this fix** on selected routes, then **Verify complete requirement** for all required routes and attempts. A changed expectation, input, fixture, backend or measurement implementation needs a new requirement; it cannot establish that the original bug was fixed.

## Current developer workflow

1. In **Connect app**, connect your Xcode project, scheme, application, UI-test target and destination. **Build and check support** builds the selected products, runs the harmless connection/readiness methods, and reports each route separately. If support is missing, review **Add or update test support**. The generated adapter deliberately throws until you implement real preparation and observations in your app. A blank official package revision requires a verified published pin; enter an explicit 40-character commit when connecting an unpublished development checkout.
2. In **Create test**, select the declared production action and, for App Feature, its project-local test control and typed inputs. The app-owned implementation prepares synthetic data, invokes the real service, and reads state back independently. Record the expected action identity and resolved parameters alongside state assertions. A connected runner is available only when you explicitly select that backend and its checked app/feature identity matches. For AI text, choose **App Feature · captured response** and specify an exact reference or a rubric for later independent assessment.
3. Save the check. Select routes under **Check this fix**, then run a partial diagnostic to inspect a change even if another route is blocked. This result cannot qualify the full requirement. Choose **Verify complete requirement** to run every required route and attempt; optional unavailable routes stay visible as blocked. In **Results**, inspect action receipts, state read-back, cleanup, assertions and artifacts. A successful Xcode capture alone does not pass a required check. For a semantic check, assess the saved response independently; selecting an earlier retained judgment or retrying its save does not rerun the app.
4. Retain the initial full run as a baseline, fix the app, and run the same frozen requirement against the corrected build. Review the comparison and qualification. A partial run, incomplete route, or unpinned semantic policy cannot qualify as a verified fix. To share the result with automation, choose **Export evidence bundle…** and check it with the [offline evidence command](Intent-Evidence.md) using trusted requirements, source, app build and policy supplied separately.
5. In **Collections**, create a persistent set from saved checks. **Collection membership and versions** adds or removes checks in a new version and shows the added, removed and changed cases. **Run full collection** captures the whole planned population. **Run selected cases** and **Rerun failed or missing cases** create explicitly partial batches; their green rows do not borrow older results for omitted cases. **Add a reviewed request variation** saves new wording as a separate case only after you approve its expected outcome. **Export selected batch…** retains its scope and denominator.

An available iPhone simulator can run local Feature and direct App Intent development checks with an ad hoc signed app and UI-test bundle when no Apple development team is configured. Intent Lab labels those results as simulator evidence. Siri routing and physical-device behavior still require a paired, signed iPhone; simulator readiness does not qualify either one.

The older advanced editor and saved v1/v2 evidence remain readable. The details below describe their lower-level setup and fields; the guided flow above is the ordinary path for new checks.

The **App action** part runs an App Intent directly. The optional **Siri** part uses recognized text on a physical iPhone. It observes the app's result. **App evaluation** can link evidence from a separate saved feature run. Each part gives different evidence.

## Prepare the app and device

You need Xcode 27 or later. Your app project needs a shared scheme and a signed UI-test target.

1. Add `IntentLabCoreTesting` to a Siri-only UI-test target. Add `IntentLabTesting` only to targets that use the direct App Intent or project-local Feature transport.
2. Add `IntentLabScenarioTests/testIntentLabScenario`, `testIntentLabConnection`, and the harmless `testIntentLabReadiness` to the relevant target.
3. Add app-owned test support that prepares known data, captures the actual production action at entry, reads persisted state independently, cleans up, and exposes a bounded typed action receipt. A project-local Feature control must call the app's production service; the test-only intent and support hooks belong only in development builds.
4. Use the [integration README](https://github.com/coryparrry/Intents/blob/main/Integration/AppIntentsTesting/README.md) and [fixture app](https://github.com/coryparrry/Intents/tree/main/examples/IntentLabFixture) as developer examples.

For Siri evidence, use a paired physical iPhone with a signed build. Enable Siri and set the scenario language on the device. Make the app's shortcut available to Siri. A simulator can check Core test readiness, but it cannot prove that the production Siri request routed to the intended action. An unsigned generic-device build checks compilation only. Intent Lab uses recognized text, not microphone audio.

Start with a **read-only** action. If an action changes data, your app must prepare isolated synthetic data and enforce permitted operations. It must also observe the new state and clean up. A fixture ID or allowed-action name in Intents does not implement these safeguards.

## Connect the Xcode project

1. Select **Intent Lab** in the sidebar. Open **Connect app**.
2. Select the owning `.xcodeproj` or `.xcworkspace`.
3. Approve **Connect app** for this app session. Xcode can resolve packages and run build scripts during discovery.
4. Select the matching **Scheme**, **Application**, **UI-test target**, and **Destination**.
5. Read the setup and preflight messages. A physical iPhone is necessary for Siri.
6. If the app already has test support, select **Build and check support** under **Check installed support**.

**Build and check support** builds the app, runs harmless connection/readiness methods, and reads their receipts. It does not run the business action or prove that Siri routed a request correctly. Direct and local Feature readiness require the selected app, UI-test runner, and test bundle to be signed by the same development team. The destination list can also include a Mac for supported direct checks. A Core Siri-only target may remain usable when AppIntentsTesting cannot load in another target.

### Add missing test support

If the app has no test support, expand **Add or update test support**:

1. Select the app target, UI-test target, and scheme.
2. Enter the app bundle ID and the actual App Intent identifier.
3. If the action cannot change data, declare **Read-only**.
4. Select a package source. The official Intents Git URL uses the app's tested, pinned revision when the revision field is blank. Check that exact revision in the preview. Enter a different 40-character commit only when you need a specific published build.
5. Select **Preview support changes**. Read each proposed file and manual step.
6. If the changes match the project, select **Apply reviewed changes**.
7. Select **Build and check support** after the changes.

A local package checkout is for development. The integration can stop working if that checkout moves. For a generator-managed project, export the manual setup files and apply them in the owning generator source; do not edit its generated Xcode project. The installer cannot correct signing.

The generated entry point handles basic, read-only, direct checks through the reusable v2 path. It does not claim v3 fixture provenance or qualify a stable multi-route comparison. Setup also generates `IntentLabAppAdapter.swift` as a starting point for behavior and Siri checks. Its preparation and observation methods throw until you implement app-owned operations, and it declares no capabilities; it cannot manufacture a passing business observation. Replace `IntentLabBasicIntegration()` in the entry point only after the adapter reads real app state, exposes a `summarySourceContentDigest` or `intentlab.fixtureDigest` observer, and checks attempt completion. Selecting an installed declaration with that observer opens the stable v3 path. A data-changing action also needs isolated data and app-side enforcement. If an installed declaration advertises state or Siri support while the entry point still uses Basic, setup supplies manual steps instead of claiming the connection works.

For a v2 mutating check, declare a compiled `cleanupOperations` allowlist and implement cleanup to restore the isolated fixture and verify its postcondition after each returned attempt. A cleanup error invalidates the attempt's evidence. The runner skips cleanup after an unresolved timeout, so the device remains quarantined until host recovery.

## Create a test

1. Open **Create test** and select **New test**.
2. Enter a **Test name**.
3. Enter the exact **Request** words for Siri and a description under **Expected result**.
4. Enter the App Intent code identifier under **App action**.
5. Under **App and language details**, select the project. Make sure that the app bundle ID and language tag are correct.
6. Expand **Inputs**. Enter the typed parameters that the App Intent declares.
7. Select **Purpose** and **Check mode** under **What should this test check?**.
8. Set the evidence parts. Mark at least one part **Required**.
9. If you need a value or state check, add it as described below.
10. Select **Save test** to keep a fixed version.

An exploratory **Basic** test can run without an observation or result check. It records execution only. A **Release requirement** needs an observable assertion. **Basic** does not prove a change in saved app data.

### Add a returned-value check

1. Under **Where to read results → Observations**, select **Add observation**.
2. Set **Source** to **Intent result**. Give the observation a stable **Observation ID**.
3. Under **Test data and advanced settings → Returned values**, select **Add returned value**.
4. Give this value the same **Observation ID**. Set its type and property path.
5. Turn on **Require returned value check**.
6. Under **Result checks**, add a required **Returned field** check.
7. Enter the same ID as its **Observation key**. Set the expected value.

The app's test support must capture the declared value. An Intent result observation needs a matching returned-value projection. A result check needs a matching observation plan entry.

For **Behaviour**, add an independent state observer under **Where to read results**. Select its actual source, such as **Entity query** or **UI element**. Add a required state check with the same observation ID. The app's test support must implement that observer.

**Optional** records a result without deciding the overall report result. **Not applicable** skips a part. New reusable tests require the direct **App action** part. Later edits to a saved test create a new version.

### Add Siri evidence

1. Set the real App Shortcut route and the exact request text.
2. Add a required check on the independently observed final state.
3. Make sure that Siri and the shortcut are ready on the physical iPhone.

Sending a request to Siri cannot, by itself, pass this part. The request language in Intents does not change the iPhone's Siri language.

### Link an app feature run

A Required **App evaluation** part needs a complete feature run from the same project and app bundle:

1. Run a suite against the connected app feature.
2. Open its saved run. Select **Export Run as JSON**.
3. In Intent Lab, expand **Test data and advanced settings**.
4. Put the saved run UUID in **Linked feature run**.
5. Put its feature ID in **Feature ID**.
6. Put its `subjectEvidence.digest` in **Feature evidence digest**.

This digest is different from the fixture digest. Intent Lab requires evidence from the same app and feature. The subject run must have complete, scored samples. An arbitrary or incomplete run cannot pass this part.

### Set test data and attempts

In **Test data and advanced settings**, enter the fixture identity and deadline. Enter the intended action name in **Allowed actions, comma separated**. The current validator requires at least one action for every test, including a read-only test. Your app must enforce this list for data-changing actions.

If you intend a comparison difference, enter it in this section. **Regression** and **Holdout** are labels. They do not change the test. Siri can run one to three attempts, which appear separately in the report. A data-changing test uses one attempt.

## Run and read the report

1. Read the connection messages and **Before you run** list.
2. Resolve each error until the header says **Ready to run**.
3. Select **Check this fix** for the chosen diagnostic routes, or **Verify complete requirement** for all required routes and attempts. Keep the device available and respond to its prompts.
4. Open **Results** and select the saved run.
5. Read the overall result and each part's attempts, assertions, observations, diagnostics, artifacts, environment, and release requirement.

**Cancel** requests interruption. If cancellation or desktop termination leaves the device state uncertain, make sure that its test stopped. Make sure that its fixture is ready before you clear device quarantine.

| Result | Meaning |
|---|---|
| **Passed** | The required checks matched. |
| **Failed** | A required check failed. |
| **Needs review** | The saved evidence needs a person to assess it. |
| **Not observed** | The run did not capture enough evidence. |
| **Not applicable** | The app skipped this part. |

A green `xcodebuild test` result alone does not establish that the release requirement passed. The checked-in Siri-only fixture now fails its XCTest method for failed or unobserved final route evidence, but a captured semantic response still needs separate assessment. The requirement fails if required evidence is absent, the run is incomplete, or the frozen definition changed. It also fails if a comparison difference is unstated. A direct App Intent pass cannot replace Siri evidence.

Intents keeps saved runs and artifacts locally. Read screenshots and responses before you share them.
