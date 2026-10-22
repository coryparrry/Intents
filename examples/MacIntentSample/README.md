# Mac App Intent sample

A native Mac app for repeatable `AppIntentsTesting` checks. It needs no Intents
SDK or custom test adapter. The [Mac App Intent guide](../../docs/wiki/Mac-App-Intent-tests.md)
explains the generated runner, compiled catalog, signing and evidence boundaries.

Use Xcode 27+, macOS 27+, XcodeGen, and an installed Apple development identity.
Set `MAC_INTENT_TEAM` to your team identifier and `MAC_INTENT_IDENTITY` to that
identity’s name or fingerprint. Both the app and runner use this signing team.
The project intentionally contains no personal development-team identifier.

## Build and install

From the repository root:

```sh
cd examples/MacIntentSample
xcodegen generate
xcodebuild -project MacIntentSample.xcodeproj -scheme MacIntentSample \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/intents-mac-sample-build \
  DEVELOPMENT_TEAM="$MAC_INTENT_TEAM" CODE_SIGN_IDENTITY="$MAC_INTENT_IDENTITY" build
cd ../..

MAC_INTENT_APP="$HOME/Applications/MacIntentSample.app"
mkdir -p "$HOME/Applications"
ditto /private/tmp/intents-mac-sample-build/Build/Products/Debug/MacIntentSample.app "$MAC_INTENT_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$MAC_INTENT_APP"
open "$MAC_INTENT_APP"
```

Install and register the exact built copy; a DerivedData-only app can fail metadata
admission. If another copy is registered under the same bundle identifier, select
the installed copy that macOS resolves as active. The runner checks this path.

## Inspect and run

```sh
swift build --jobs 2 --product intents-native-tests
MAC_INTENT_CLI="$(swift build --show-bin-path)/intents-native-tests"
"$MAC_INTENT_CLI" catalog --app "$MAC_INTENT_APP"
"$MAC_INTENT_CLI" run \
  --app "$MAC_INTENT_APP" --cases examples/MacIntentSample/cases.json \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --team "$MAC_INTENT_TEAM" --identity "$MAC_INTENT_IDENTITY" \
  --output /private/tmp/intents-mac-sample-results --timeout 600
```

The manifest contains these seven checks:

| Action | Inputs | Expected result |
|---|---|---|
| `ReadSampleStatus` | None | `"ready"` |
| `FormatSampleInput` | Escaped text, `count: 7`, `enabled: true` | The exact text followed by `:7:true` |
| `ScaleSampleNumber` | `number: 1.75` | `3.5` |
| `ReadSampleMode` | `mode: "short"` | `"short"` |
| `ReadSampleMode` | `mode: "long"` | `"long"` |
| `ReadSampleMode` | Mode omitted | `"short"` from the declared default |
| `ReadSampleStatus` | Expected value omitted | Successful execution only |

`inputs` defaults to an empty object. Omitting `expectedValue` means a smoke
check; it does not assert a returned value. Keep `run.log` and the `.xcresult`
bundle from each run when comparing results. Local qualification has passed
seven native cases covering these features. This is sample/environment evidence,
not universal app compatibility or Siri verification.
