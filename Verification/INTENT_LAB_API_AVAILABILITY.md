# Intent Lab API availability verification

Verified locally on 2026-09-20 with Xcode 27.0 (`27A266a`) and the iOS 27.0 SDK.

| Surface | Local verification | Evidence boundary |
|---|---|---|
| `IntentDefinitions(bundleIdentifier:)`, intent/entity/enum definitions, `makeIntent`, dynamic parameter setters, `AnyAppIntent.run()` and `ResolvedIntentResult` | The fixture UI-test bundle compiles while importing the developer AppIntentsTesting framework. | SDK and compile proof; not a device execution. |
| Primitive, enum, entity and homogeneous-array conversions | The generic test support compiles for arm64 and x86_64 iOS Simulator slices. Portable validation tests reject null/type/allowlist/non-finite mismatches before build. | Native runtime conversion still requires a signed UI-test execution. |
| `XCUIDevice.shared.siriService.activate(voiceRecognitionText:)` | The recognised-text call compiles in the fixture UI-test target. | No Siri outcome is claimed without a paired physical-iPhone run and captured final state. |
| `XCTAttachment` JSON/screenshots and `.xcresult` export | Attachment writer and host export/import paths compile. | Result-bundle import is accepted only with matching invocation/build identities and exactly one test. |
| Foundation Models request suggestions | The macOS app compiles with `@Generable` candidates and explicit availability handling. | Suggestions require human approval and do not predict Siri behavior. |

Commands completed:

```text
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination platform=macOS -derivedDataPath /tmp/intent-lab-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project examples/IntentLabFixture/IntentLabFixture.xcodeproj -scheme IntentLabFixture -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/intent-lab-fixture-build CODE_SIGNING_ALLOWED=NO build-for-testing
```

Physical-device Siri proof and the independent existing-app integration gate remain separate release evidence. This note must not be treated as either.
