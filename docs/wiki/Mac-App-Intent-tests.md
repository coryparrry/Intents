# Test Mac App Intents

Use **App Intent Testing** in Intents, or the `intents-native-tests` command, to
inspect a built Mac app and run explicit input/result checks. Execution uses
Apple’s `AppIntentsTesting` framework in a generated macOS UI-test target.
Your subject app does not need an Intents SDK or custom test adapter.

## Prepare the app and signing

Use macOS 27+, Xcode 27+ with its macOS AppIntentsTesting framework, and XcodeGen
(`brew install xcodegen`). Have an installed Apple development signing identity
and its team identifier. The subject app and generated UI-test runner must be
signed by the same development team; Intents never re-signs your subject app.
`security find-identity -v -p codesigning` lists installed signing identities.

Install the built `.app` normally, for example in `~/Applications`, register it
with macOS, and open it normally. Select that installed copy. A bundle left only
in an Xcode build directory can fail metadata admission, and another registered
copy with the same bundle identifier can take precedence. The runner checks that
the active registered app resolves to the selected path.

Intents reads compiled App Intents metadata to produce a best-effort catalog.
Missing metadata or an unsupported declaration may leave an action unavailable.
Well-formed hidden actions are included too; an unsupported parameter type stays
visible and prevents execution instead of receiving a guessed value. Discovery
does not execute the intent or establish runtime availability. Native
Mac apps are supported; an iOS-only app cannot be used through this workflow.

## Run from the command line

From the repository root, build the command and inspect the installed app:

```sh
swift build --jobs 2 --product intents-native-tests
MAC_INTENT_CLI="$(swift build --show-bin-path)/intents-native-tests"
MAC_INTENT_APP="$HOME/Applications/MyApp.app"
"$MAC_INTENT_CLI" catalog --app "$MAC_INTENT_APP"
```

Read action and parameter identifiers from that JSON catalog. Save a JSON array
of cases, with explicit input values and expected scalar results:

```json
[
  {
    "actionIdentifier": "EchoIntent",
    "inputs": {"message": "Hello"},
    "expectedValue": "Hello"
  }
]
```

`inputs` defaults to `{}`. Omit `expectedValue` for an execution-only smoke check;
a successful smoke check does not compare the returned value. When present,
`expectedValue` must be a supported JSON scalar. Match the action’s declared
parameter types. Enum inputs use case identifiers from the catalog; omit a
parameter with a declared default to use that default. Unsupported types are
reported rather than inferred.

Run the manifest with the same signing team as the installed app:

```sh
"$MAC_INTENT_CLI" run \
  --app "$MAC_INTENT_APP" \
  --cases /absolute/path/cases.json \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --team "$MAC_INTENT_TEAM" \
  --identity "$MAC_INTENT_IDENTITY" \
  --output /private/tmp/my-mac-intent-results \
  --timeout 600
```

Set `MAC_INTENT_TEAM` and `MAC_INTENT_IDENTITY` to your development team identifier
and installed signing identity before running. Use an interactive Mac login
session and complete any macOS development automation authorization. Inspect the
saved `run.log`, generated tests, and `.xcresult` bundle. An infrastructure failure
or missing evidence is not a passed action check. Success also requires the
result bundle to confirm the exact authored test count, with no skipped tests or
expected failures.

The [Mac sample](../../examples/MacIntentSample/README.md) includes a build recipe
and seven-case manifest for String, Bool, Int, Double, enum cases/defaults, and
execution-only smoke coverage.

## Use the native app

Choose the installed `.app` in **App Intent Testing**, select an action from the
catalog, and enter a JSON object keyed by parameter identifier. Provide the
expected JSON value, or disable the comparison for a smoke check. Enter the Xcode
developer directory, signing team and identity, then run and read the diagnostics.
Review the intended effect before testing a data-changing action in your own app.

## Evidence and limits

A local generated-runner qualification passed seven native Mac cases covering
readiness, escaped String plus Bool/Int inputs, Double input/output, enum cases
and defaults, and an execution-only smoke check. That result qualifies the tested
sample and environment; it does not establish support for every app or type.
Catalog inspection and unit tests remain separate evidence from runtime execution.

This workflow does not verify Siri recognition, routing, or responses. Ordinary
Foundation Model evaluations, connected developer feature runners, production
batches, the evaluation CLI, and the standalone plugin remain separate workflows.
