# Intents — open-source Apple Foundation Models workbench

Canonical website: https://intents-workbench.coryparry.chatgpt.site/

Intents is a free, open-source native macOS app for evaluating Apple Foundation Models and testing App Intents. It is made by Cory Parry, written in Swift with a SwiftUI interface, and released under the MIT licence.

## Put intelligence to the test

Use Intents to run repeatable evaluations, read model responses and scoring explanations, and inspect the execution evidence behind a result. Check whether a model follows a prompt, remembers a changed preference, or retains a compatible constraint.

The workbench connects evaluation results with workflow traces. Traces show the steps from input preparation to response generation and scoring, with timing information for individual spans.

## Intent Lab (beta)

Intent Lab helps test what should happen when someone asks an app to perform an action. Describe the expected behaviour, check the result, and retain the evidence. The showcase includes a recorded App Intent test fixture.

## Work with your tools

- **On your Mac:** Run Apple's on-device model with native SwiftUI controls. Suites and evidence live in a local workspace.
- **With your coding agent:** The built-in MCP (Model Context Protocol) server lets agents manage suites and run evaluations. Review the same results in the app. [Connect an agent](https://github.com/coryparrry/Intents#connect-an-agent).
- **Inside your app:** Evaluate real Swift feature closures on a paired iPhone, iPad, or Mac. [Swift integration guide](https://github.com/coryparrry/Intents/blob/main/docs/DEVELOPER_SWIFT_INTEGRATION.md).
- **Other models:** Connect compatible Core AI models or a custom HTTP provider. Remote providers and judges use their configured services; these requests are not necessarily on-device.

## Requirements and download

The showcased app requires macOS 27 or later, an Apple Intelligence-capable Apple silicon Mac, and Apple Intelligence enabled with its on-device model downloaded. Check the release notes for requirements of the specific build you download.

- [Download the latest published release](https://github.com/coryparrry/Intents/releases/latest).
- [Browse the source code](https://github.com/coryparrry/Intents).
- [Build from source](https://github.com/coryparrry/Intents#build-from-source).
- [Read the MIT licence](https://github.com/coryparrry/Intents/blob/main/LICENSE).

## About the website examples

The interactive website contains browser recreations of the native app's interface using HTML and CSS. The Conversation behaviour report and workflow trace use a recorded evaluation from 17 September 2026. The Latest preference wins trace contains 13 measured spans; the showcased workflow took 18.39 seconds in that recording.

Intent Lab uses a test fixture. These demonstrations do not run live models, call Siri, or connect to devices. The example scores and timings are not model benchmarks or performance guarantees.

## Contribute

Intents is free and open source. Read it, run it, modify it, and contribute through the [GitHub repository](https://github.com/coryparrry/Intents). [Report an issue or share feedback](https://github.com/coryparrry/Intents/issues).
