# Run App Intent checks with Intent Lab (Beta)

[Home](Home.md) · [App feature runners](App-feature-runners.md) · [Data and troubleshooting](Data-and-troubleshooting.md)

Intent Lab uses a signed Xcode UI-test target that belongs to your app. It runs one fixed test method and imports observations from your test support.

The **App action** part runs an App Intent directly. The optional **Siri** part uses recognized text on a physical iPhone. It observes the app's result. **App evaluation** can link evidence from a separate saved feature run. Each part gives different evidence.

## Prepare the app and device

You need Xcode 27 or later. Your app project needs a shared scheme and a signed UI-test target.

1. Add the `IntentLabTesting` package product to the UI-test target.
2. Add the method `IntentLabScenarioTests/testIntentLabScenario` to that target.
3. Add test support that prepares known data, runs the action, observes its result, and connects observations to the run.
4. Use the [integration README](https://github.com/coryparrry/Intents/blob/main/Integration/AppIntentsTesting/README.md) and [fixture app](https://github.com/coryparrry/Intents/tree/main/examples/IntentLabFixture) as developer examples.

For Siri evidence, use a paired physical iPhone with a signed build. Enable Siri and set the scenario language on the device. Make the app's shortcut available to Siri. A simulator or unsigned generic-device build only checks compilation. Intent Lab uses recognized text, not microphone audio.

Start with a **read-only** action. If an action changes data, your app must prepare isolated synthetic data and enforce permitted operations. It must also observe the new state and clean up. A fixture ID or allowed-action name in Intents does not implement these safeguards.

## Connect the Xcode project

1. Select **Intent Lab** in the sidebar. Open **Connect app**.
2. Select the owning `.xcodeproj` or `.xcworkspace`.
3. Approve **Connect app** for this app session. Xcode can resolve packages and run build scripts during discovery.
4. Select the matching **Scheme**, **Application**, **UI-test target**, and **Destination**.
5. Read the setup and preflight messages. A physical iPhone is necessary for Siri.
6. If the app already has test support, select **Build and check support** under **Check installed support**.

**Build and check support** builds the app and reads the integration receipt. It does not run the app action. The destination list can also include a Mac for supported direct checks.

### Add missing test support

If the app has no test support, expand **Add or update test support**:

1. Select the app target, UI-test target, and scheme.
2. Enter the app bundle ID and the actual App Intent identifier.
3. If the action cannot change data, declare **Read-only**.
4. Select a package source. For a reusable dependency, enter an exact published commit.
5. Select **Preview support changes**. Read each proposed file and manual step.
6. If the changes match the project, select **Apply reviewed changes**.
7. Select **Build and check support** after the changes.

A local package checkout is for development. The integration can stop working if that checkout moves. For a generator-managed project, export the manual setup files. Then add them through that project's generator. The installer cannot correct signing.

The generated support handles basic, read-only, direct checks. Behavior or Siri checks require an observation and completion adapter in your app. A data-changing action also needs isolated data and app-side enforcement.

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
3. Select **Run test**. Keep the device available and respond to its prompts.
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

A green `xcodebuild test` result means that the capture method finished. It does not mean that the release requirement passed. The requirement fails if required evidence is absent, the run is incomplete, or the frozen definition changed. It also fails if a comparison difference is unstated. A direct App Intent pass cannot replace Siri evidence.

Intents keeps saved runs and artifacts locally. Read screenshots and responses before you share them.
