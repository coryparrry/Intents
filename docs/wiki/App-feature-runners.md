# Run feature checks in your own app

[Home](Home.md) · [Runs and results](Runs-and-results.md) · [Intent Lab](Intent-Lab.md)

A developer runner lets an Intents suite call a feature in your iPhone, iPad, or Mac app. Your app keeps control of its model, tools, data, and feature code. Intents sends each case input to the app. Then it saves and scores the declared response evidence.

This workflow runs the registered feature. It does not prove that an App Intent or Siri route works.

## Add support to the app

These steps are for the app developer:

1. Add this repository as a Swift package.
2. Link the `FoundationEvalsDeveloper` product to the app target.
3. Register a stable feature ID and version with `DeveloperFeatureRegistry`.
4. Make the registered closure call the same production service that the app uses.
5. Show `DeveloperRunnerView` in a development build.
6. Give the runner a stable identity and a location for its trust file.

The **Devices & apps → Set up the Swift package** guide contains a short example. The [full integration guide](https://github.com/coryparrry/Intents/blob/main/docs/DEVELOPER_SWIFT_INTEGRATION.md) covers typed input, output, cancellation, trust, and platform settings.

For an iPhone or iPad, add local-network use and `_fnd-evals._tcp` Bonjour service declarations to `Info.plist`. The developer package supports iOS, iPadOS, and macOS 26 or later. The Intents desktop app requires macOS 27 or later.

## Pair the app and select a feature

1. Put the Mac and device on a local network that permits discovery.
2. Open the runner screen in the development app.
3. Select **Start pairing**. Keep the displayed code visible.
4. In Intents Overview, select **Devices & Apps…**. You can also open **Manage Devices & Apps…** from a suite's destination menu.
5. If discovery is off, select **Find devices**.
6. Select **Connect** for the nearby app.
7. Enter the code that the app shows. Select **Pair device**.
8. Return to a suite. Open its destination menu.
9. Select the connected device and its registered **Feature**. Then select **Run**.

Pairing requires an action in both apps. Intents can keep one active runner connection at a time. Keep the runner available during the run.

If the device disconnects, read the error and connect again. If the feature version does not match, update the app. The connected app uses its own production model and tools. The saved run records the runner, device, OS, app, and feature identity.

## Read the evidence

Open the saved run's **Report** and **Workflow trace**. Read each response and the details of the app and device. You can compare this run with another run in **Compare**.

An AI rubric for a remote feature needs an approved independent judge connection. A missing or failed assessment is not a pass. Use [Intent Lab](Intent-Lab.md) for a claim about App Intent invocation or Siri's result.
