# Courtside Siri Studio fixture

Courtside exposes synthetic team and roster actions. It does not read user
data or require a Spotlight index. Each scenario resets the in-memory fixture
before each repeat. Build it with Xcode 27.3 and XcodeGen:

```sh
xcodegen generate --spec examples/SiriStudioSample/project.yml
xcodebuild -project examples/SiriStudioSample/Courtside.xcodeproj \
  -scheme Courtside -destination platform=macOS DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY="$IDENTITY" -derivedDataPath "$BUILD_DIR" build
```

On a Siri-capable macOS 27.3 Mac, install and open the built `Courtside.app`
once, then quit it. Choose it in [Siri Studio](../../docs/wiki/Siri-Studio.md)
and open `scenarios.json`. The fixture covers ordered action selection,
asking for a missing jersey number, forbidden actions, and a deliberate
argument mismatch (21 expected, 12 requested).

Qualify with the app and CLI using the same document and signing team.
Also add the exported Swift to a macOS 27.3 Swift Testing UI test target,
run with `xcodebuild test -parallel-testing-enabled NO`, and import its
`.xcresult`. Check the passing and deliberate mismatch cases, blocked setup
reporting, the missing-number follow-up, and revision matching on import.
Do not interpret a build or typecheck as a live Siri result.

For the explicitly opted-in local test, export:

```sh
export INTENTS_RUN_LIVE_SIRI=1
export INTENTS_SIRI_FIXTURE_APP="$APP"
export INTENTS_SIRI_TEAM="$TEAM"
export INTENTS_SIRI_IDENTITY="$IDENTITY"
export INTENTS_SIRI_EVIDENCE="$RUN_DIRECTORY"
export DEVELOPER_DIR=/Applications/Xcode-27.3.0-Beta.app/Contents/Developer
swift test --filter SiriStudioLiveTests/signedCourtsideSiri
```

Use a new, empty run directory and leave the Mac unlocked while Siri runs.
Keep transcripts local unless you explicitly choose to share them.
