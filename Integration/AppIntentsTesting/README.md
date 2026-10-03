# Intent Lab UI-test support

Add the Swift files and `SiriActivationBridge.m` to a signed iOS UI-test target that builds with Xcode 27 or newer. Import `SiriActivationBridge.h` through that target’s Objective-C bridging header (`SWIFT_OBJC_BRIDGING_HEADER`); if the target already has a bridging header, add an import there. Keep the bridge in the test target only. Keep the fixed XCTest identity `IntentLabScenarioTests/testIntentLabScenario`. Bundled `IntentLabScenario.json` and `IntentLabInvocation.json` resources remain a compatibility fallback, but Quick Connect supplies both payloads atomically through the invocation-specific `.xctestrun` environment.

Declare the integration contract as user-defined build settings on that UI-test target:

```text
INTENT_LAB_HARNESS_VERSION = intent-lab-v1
INTENT_LAB_HARNESS_CAPABILITIES = environment-payload fixture-reset invocation-correlation accessible-result direct-intent-output
```

The host builds once in isolated Derived Data, resolves the exact products named by Xcode's generated `.xctestrun`, binds their host-computed fingerprints into a fresh invocation, and runs exactly that test method with an invocation-specific sibling `.xctestrun`. Extend `IntentProbe` only with deliberate, typed output extraction needed by the app under test. Never reflect or serialize an entire `ResolvedIntentResult`.

`SiriProbe` needs a paired physical iPhone with Siri enabled for the test language and the app's shortcuts discoverable. A simulator build proves compilation only; it does not prove Siri behavior.

A completed assertion mismatch is a failed scenario, not a failed evidence-capture process. The harness attaches the final failed result and allows XCTest to finish successfully; the host still rejects that scenario for release. Incomplete or unobserved execution continues to fail XCTest and requires recovery.

The harness resets and relaunches the synthetic fixture between the direct-intent and Siri lanes. Siri completion requires the declared visible state or a state transition, and a failure stores a checksummed screenshot alongside the JSON envelope. Required App Feature coverage is intentionally rejected by desktop preflight because this UI-test bundle only owns Intent Integration and Siri evidence.

Siri permission and confirmation alerts remain operator-controlled. After Siri activation returns, the harness waits for any app or SpringBoard alert to clear before accepting a correlated completion. After any unresolved Siri attempt, the remaining attempts retain that failure without resetting or relaunching the app. This prevents a delayed action from inheriting a later attempt’s context. Approve the prompt on the iPhone and rerun. If XCTest terminates inside Siri activation, the pre-Siri checkpoint preserves direct-intent observations, but the device stays quarantined until recovery is confirmed; checkpoint evidence never proves Siri passed.

For the English “Which one?” chooser, the harness selects a single visible option whose whole-word name occurs in the request. It records `siriDisambiguationSelection` separately from the app's correlated result. On the iOS 27 automation sheet, accessibility queries block during activation, so the handler locates the visible row using on-device Vision text recognition and taps that observed screen position. Only text between the chooser heading and the app attribution is considered, so background app labels cannot create false ambiguity. Missing or ambiguous matches are left unselected. A prior Siri sheet is dismissed before starting the next request, and XCTest teardown stops the handler even if activation aborts the test.

On the observed iOS 27 runtime, Siri can complete the action while `XCUISiriService.activate` still times out and raises an Objective-C test interruption. The test-only bridge catches that interruption before it unwinds through Swift. Recovery requires the exact observed exception name and reason, the exact expected XCTest activation-timeout issue, and a fresh invocation context with a nonempty selected note and action event. Other exceptions are rethrown. The normal result assertions still run after recovery, the evidence records `siriActivationDiagnostic`, and a teardown sentinel fails any invocation that aborts before returning its observations. The scenario uses a synchronous XCTest entry point because the observed async test task is abandoned on this driver failure; its direct AppIntentsTesting call is awaited through a bounded XCTest expectation. A direct-intent timeout stops the scenario before any Siri reset. An expected-failure report alone is not completion evidence. Test launches keep the fixture awake without changing the device's Auto-Lock setting.
